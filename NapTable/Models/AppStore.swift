import Combine
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum ScheduleViewMode: String, CaseIterable, Identifiable {
    case week
    case day

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: return "周"
        case .day: return "日"
        }
    }
}

/// Local replacement for the Flutter app's sqflite `CourseProvider` /
/// `CourseTableProvider` plus `MainStateModel` and `ConfigState`.
///
/// Everything lives in one JSON document under Application Support. The store is
/// the single writer for course rows, so importers hand it `Course` values and
/// never touch the file themselves.
@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var settings: AppSettings
    @Published private(set) var tables: [CourseTable]
    @Published private(set) var courses: [Course]
    @Published private(set) var selectedTableId: Int
    /// The week the user is looking at. Swiping changes this.
    @Published var displayWeek: Int
    /// Populated when loading the state file failed; surfaced in settings.
    @Published private(set) var loadErrorMessage: String?
    /// 服务端下发的统一假期安排，不分学校、不管课表有没有绑定学期都用它。
    @Published private(set) var unifiedCalendarAdjustments: [CalendarAdjustment]

    private var nextCourseId: Int
    private var nextTableId: Int
    private var nextCourseKey: Int
    private var didSeedSample: Bool
    private let fileURL: URL?
    private var saveTask: Task<Void, Never>?
    private var didLoad = false
    /// 读取失败（不是解码失败）时禁止写盘：这时磁盘上的文件是好的，只是这一轮
    /// 读不到（比如后台启动时数据保护还没解锁），用空状态覆盖它会把课表清掉。
    /// 下一次成功读到内容就恢复保存。
    private var saveBlocked = false
    private(set) var cloudSync: CloudSyncJournal

    // MARK: Init

    init(fileURL: URL? = AppStore.defaultFileURL()) {
        self.fileURL = fileURL
        let state = AppStore.readState(from: fileURL)
        self.cloudSync = state.state.cloudSync ?? CloudSyncJournal()
        self.settings = state.state.settings
        self.tables = state.state.tables
        self.courses = state.state.courses
        self.selectedTableId = state.state.selectedTableId
        self.nextCourseId = state.state.nextCourseId
        self.nextTableId = state.state.nextTableId
        self.nextCourseKey = state.state.nextCourseKey
        self.didSeedSample = state.state.didSeedSample
        self.unifiedCalendarAdjustments = state.state.unifiedCalendarAdjustments ?? []
        self.loadErrorMessage = state.error
        self.displayWeek = 1
        saveBlocked = state.saveBlocked
        didLoad = true
        normalize()
        displayWeek = liveWeek > 0 ? liveWeek : 1
        #if canImport(UIKit)
        if saveBlocked {
            // 解锁之后或回到前台时再读一次，读到了就换上真正的存档。
            for name in [UIApplication.protectedDataDidBecomeAvailableNotification,
                         UIApplication.didBecomeActiveNotification] {
                retryObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.retryLoadIfBlocked() }
                })
            }
        }
        #endif
    }

    private var retryObservers: [NSObjectProtocol] = []

    /// 上次读取失败时再读一遍存档。读取仍然失败就继续空状态运行、不写盘；
    /// 读到了（或文件解不开、已经挪成备份）就换上结果并恢复保存。这期间在内存里
    /// 做的改动会被丢弃——它们是在看不到真实课表的情况下做的。
    func retryLoadIfBlocked() {
        guard saveBlocked else { return }
        let state = AppStore.readState(from: fileURL)
        guard !state.saveBlocked else { return }
        cloudSync = state.state.cloudSync ?? CloudSyncJournal()
        saveTask?.cancel()
        settings = state.state.settings
        tables = state.state.tables
        courses = state.state.courses
        selectedTableId = state.state.selectedTableId
        nextCourseId = state.state.nextCourseId
        nextTableId = state.state.nextTableId
        nextCourseKey = state.state.nextCourseKey
        didSeedSample = state.state.didSeedSample
        unifiedCalendarAdjustments = state.state.unifiedCalendarAdjustments ?? []
        loadErrorMessage = state.error
        saveBlocked = false
        retryObservers.forEach(NotificationCenter.default.removeObserver)
        retryObservers = []
        normalize()
        displayWeek = liveWeek > 0 ? liveWeek : 1
    }

    nonisolated static func defaultFileURL() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        let directory = base.appendingPathComponent("NapTable", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("naptable-state.json", isDirectory: false)
    }

    private static func readState(from url: URL?) -> (state: AppStateFile, error: String?, saveBlocked: Bool) {
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            return (AppStateFile(), nil, false)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // 读不到文件（数据保护没解锁、磁盘暂时不可用…）不代表文件坏了。这时候
            // 不动它、以空状态运行，等下一次成功读取；期间禁止写盘。
            return (AppStateFile(), "本地数据暂时无法读取：\(error.localizedDescription)", true)
        }
        do {
            return (try JSONDecoder().decode(AppStateFile.self, from: data), nil, false)
        } catch {
            // A broken file must not wipe the app; start clean but keep the
            // original around so a user can still recover it by hand. 备份名带时间
            // 戳：解不开的文件往往不止一次，覆盖掉上一份就等于把恢复的退路丢了。
            let stamp = Self.backupStamp()
            var backup = url.appendingPathExtension("corrupt-\(stamp)")
            var suffix = 2
            while FileManager.default.fileExists(atPath: backup.path) {
                backup = url.appendingPathExtension("corrupt-\(stamp)-\(suffix)")
                suffix += 1
            }
            do {
                try FileManager.default.moveItem(at: url, to: backup)
            } catch {
                // 挪不走就别覆盖它：以空状态运行但不写盘，原文件留给用户手动恢复。
                return (AppStateFile(), "本地数据无法读取，且无法备份原文件：\(error.localizedDescription)", true)
            }
            return (AppStateFile(), "本地数据无法读取，已重置（原文件备份为 \(backup.lastPathComponent)）", false)
        }
    }

    private static func backupStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    // MARK: Derived data

    var selectedTable: CourseTable? {
        tables.first { $0.id == selectedTableId } ?? tables.first
    }

    /// 当前课表里参与显示的课。隐藏的行留在 `courses` 里，但不进网格、
    /// 不进小组件和实时活动，也不会被分享出去。
    var currentCourses: [Course] {
        courses.filter { $0.tableId == selectedTableId && !$0.isHidden }
    }

    /// 导入时让位、被收起来的课。「隐藏的课程」页面用它来恢复。
    var currentHiddenCourses: [Course] {
        hiddenCourses(inTable: selectedTableId)
    }

    func hiddenCourses(inTable id: Int) -> [Course] {
        courses.filter { $0.tableId == id && $0.isHidden }
    }

    var classTimeList: [ClassTime] {
        selectedTable?.effectiveClassTimeList ?? SchoolDefaults.classTimeList
    }

    var maxClasses: Int {
        max(SchoolDefaults.maxClasses, classTimeList.count)
    }

    var maxWeeks: Int {
        selectedTable.map(weekCount(of:)) ?? max(1, settings.weekCount)
    }

    /// 这张课表的学期总周数。学校配置下发的、或者用户在这张课表里改过的，都存在
    /// `termWeekCount`；老存档没有这个值，退回到以前全局的那个设置。
    func weekCount(of table: CourseTable) -> Int {
        max(1, table.termWeekCount ?? settings.weekCount)
    }

    /// Classifies this table's courses for one week and resolves the grid
    /// coordinates, i.e. the Flutter app's
    /// `CourseTablePresenter.refreshClasses` + `getClassesWidgetList`.
    func layout(forWeek week: Int, days: [Int]) -> ScheduleLayout {
        let logic = ScheduleLogic(courses: currentCourses, nowWeek: week)
        return ScheduleLayout(logic: logic, days: days)
    }

    /// The week that contains today, or `0` before the semester starts.
    var liveWeek: Int {
        guard let snapshot = weekSnapshot else {
            // Without a semester anchor the app cannot know the real week, so
            // the user-chosen week is treated as "now".
            return min(max(displayWeek, 1), maxWeeks)
        }
        return snapshot.currentWeek
    }

    var weekSnapshot: WeekCalculator.Snapshot? {
        WeekCalculator.snapshot(
            for: Date(),
            semesterStartMonday: effectiveSemesterStartMonday,
            maxWeeks: maxWeeks
        )
    }

    /// Dates for the displayed week, empty when no semester anchor is set.
    var displayDays: [Date] {
        guard let snapshot = weekSnapshot else { return [] }
        let delta = displayWeek - snapshot.currentWeek
        guard delta != 0 else { return snapshot.days }
        let calendar = WeekCalculator.calendar
        let monday = calendar.date(byAdding: .day, value: delta * 7, to: snapshot.monday) ?? snapshot.monday
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
    }

    var displayMonth: Int? {
        displayDays.first.map { WeekCalculator.month($0) }
    }

    var isViewingLiveWeek: Bool {
        displayWeek == liveWeek && liveWeek > 0
    }

    var semesterStartMonday: String {
        selectedTable?.semesterStartMonday ?? ""
    }

    /// The anchor actually used for week arithmetic: the table's own value when
    /// it has one, otherwise the global calendar the upstream project ships in
    /// `complete.json`.
    ///
    /// The Flutter app applies its downloaded `complete.json` to the week index
    /// rather than to the stored table, so this stays a read-only fallback: a
    /// table the user never filled in is not silently rewritten, but the app can
    /// still work out which week today is in.
    var effectiveSemesterStartMonday: String {
        effectiveSemesterStartMonday(for: semesterStartMonday)
    }

    func effectiveSemesterStartMonday(of table: CourseTable) -> String {
        effectiveSemesterStartMonday(for: table.semesterStartMonday)
    }

    private func effectiveSemesterStartMonday(for own: String) -> String {
        let own = own.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty { return own }
        return BundledConfig.fallbackSemesterStartMonday ?? ""
    }

    var semesterStartMondayDisplay: String {
        Self.semesterStartDisplay(effectiveSemesterStartMonday)
    }

    func semesterStartMondayDisplay(of table: CourseTable) -> String {
        Self.semesterStartDisplay(effectiveSemesterStartMonday(of: table))
    }

    private static func semesterStartDisplay(_ value: String) -> String {
        guard let date = WeekCalculator.parseDay(value) else { return "未设置" }
        let formatter = DateFormatter()
        formatter.calendar = WeekCalculator.calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy 年 M 月 d 日"
        return formatter.string(from: date)
    }

    /// 今天落在这张课表的第几周；没有开学日期、或者不在学期里时是 `0`。
    /// 和 `liveWeek` 不同，不拿当前显示的周次兜底——那只对正在看的课表有意义。
    func liveWeek(of table: CourseTable) -> Int {
        WeekCalculator.snapshot(
            for: Date(),
            semesterStartMonday: effectiveSemesterStartMonday(of: table),
            maxWeeks: weekCount(of: table)
        )?.currentWeek ?? 0
    }

    var hasAnyData: Bool {
        !courses.isEmpty
    }

    /// `CourseTable.effectiveClassTimeList` entries used by the axis.
    func classTime(at index: Int) -> ClassTime? {
        let list = classTimeList
        guard list.indices.contains(index) else { return nil }
        return list[index]
    }

    // MARK: Week navigation

    func selectWeek(_ week: Int) {
        displayWeek = min(max(week, 1), maxWeeks)
    }

    func stepWeek(_ offset: Int) {
        selectWeek(displayWeek + offset)
    }

    func goToLiveWeek() {
        guard liveWeek > 0 else {
            selectWeek(1)
            return
        }
        selectWeek(liveWeek)
    }

    func refreshForToday() {
        if liveWeek > 0, displayWeek == 0 { displayWeek = liveWeek }
        checkWeekRollover()
    }

    /// Lands on the week that contains today, falling back to week 1 when the
    /// table carries no semester anchor.
    ///
    /// `refreshForToday` alone only moves a *zero* week, so installing a
    /// schedule, switching tables or setting the semester start all left the app
    /// sitting on week 1 even though the current week was known.
    private func resetWeekToLive() {
        displayWeek = 1
        goToLiveWeek()
        refreshForToday()
    }

    /// Mirrors `WeekUtil.checkWeek()`: when the stored day and today straddle a
    /// Monday, the displayed week follows the calendar instead of drifting.
    private var lastKnownWeek = 0
    private func checkWeekRollover() {
        let current = liveWeek
        guard current > 0 else { return }
        defer { lastKnownWeek = current }
        guard lastKnownWeek != 0, lastKnownWeek != current else { return }
        displayWeek = current
    }

    // MARK: Table management

    /// 课表名不能重复（去掉首尾空白后比较）。`except` 是正在改名或被覆盖的那张，不算撞名。
    func isTableNameTaken(_ name: String, except id: Int? = nil) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return tables.contains { $0.id != id && $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed }
    }

    /// 撞名时在后面补序号：「2026 秋」已有就用「2026 秋（2）」，依次往上加。
    func uniqueTableName(_ name: String, except id: Int? = nil) -> String {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isTableNameTaken(base, except: id) else { return base }
        var index = 2
        while isTableNameTaken("\(base)（\(index)）", except: id) { index += 1 }
        return "\(base)（\(index)）"
    }

    @discardableResult
    func addTable(name: String, semesterStartMonday: String = "", classTimeList: [ClassTime] = []) -> CourseTable {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var table = CourseTable(
            id: nextTableId,
            name: uniqueTableName(trimmed.isEmpty ? "课表 \(nextTableId)" : trimmed),
            classTimeList: classTimeList,
            semesterStartMonday: semesterStartMonday
        )
        table.syncID = UUID().uuidString
        nextTableId += 1
        tables.append(table)
        selectedTableId = table.id
        resetWeekToLive()
        scheduleSave()
        return table
    }

    func renameTable(_ id: Int, to name: String) {
        guard let index = tables.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isTableNameTaken(trimmed, except: id) else { return }
        tables[index].name = trimmed
        scheduleSave()
    }

    /// 学期和节次跟着课表走：不同学校、不同学期各是各的。`tableId` 省略时改当前课表。
    func updateSemesterStart(_ value: String, tableId: Int? = nil) {
        let target = tableId ?? selectedTableId
        guard let index = tables.firstIndex(where: { $0.id == target }) else { return }
        tables[index].semesterStartMonday = value
        scheduleSave()
        if target == selectedTableId { resetWeekToLive() }
    }

    func updateWeekCount(_ value: Int, tableId: Int? = nil) {
        let target = tableId ?? selectedTableId
        guard let index = tables.firstIndex(where: { $0.id == target }) else { return }
        tables[index].termWeekCount = min(max(value, 1), 40)
        scheduleSave()
        if target == selectedTableId { displayWeek = min(max(displayWeek, 1), maxWeeks) }
    }

    // MARK: 统一假期安排

    /// 这张课表实际生效的调休：关掉统一假期安排就一条都不要；否则以服务端的统一
    /// 安排为准，课表自己带的（导入文件、分享快照里的）只补统一安排没写到的日期。
    func calendarAdjustments(of table: CourseTable) -> [CalendarAdjustment] {
        guard table.unifiedHolidaysEnabled != false else { return [] }
        return Self.merge(unified: unifiedCalendarAdjustments, own: table.calendarAdjustments ?? [])
    }

    /// 节假日提示（「中秋快乐」「距国庆节还有 3 天」）用的放假安排。它只是报日子，
    /// 不管课表的开关：关掉统一假期安排只是照常排课，国庆还是国庆。
    var holidayCalendarAdjustments: [CalendarAdjustment] {
        Self.merge(unified: unifiedCalendarAdjustments, own: selectedTable?.calendarAdjustments ?? [])
    }

    private static func merge(unified: [CalendarAdjustment], own: [CalendarAdjustment]) -> [CalendarAdjustment] {
        guard !unified.isEmpty else { return own }
        let covered = Set(unified.map(\.date))
        return (own.filter { !covered.contains($0.date) } + unified).sorted { $0.date < $1.date }
    }

    func updateUnifiedCalendar(_ adjustments: [CalendarAdjustment]) {
        guard adjustments != unifiedCalendarAdjustments else { return }
        unifiedCalendarAdjustments = adjustments
        scheduleSave()
    }

    func setUnifiedHolidaysEnabled(_ enabled: Bool, tableId: Int) {
        guard let index = tables.firstIndex(where: { $0.id == tableId }) else { return }
        tables[index].unifiedHolidaysEnabled = enabled
        scheduleSave()
    }

    func updateClassTimeList(_ list: [ClassTime], tableId: Int? = nil) {
        let target = tableId ?? selectedTableId
        guard let index = tables.firstIndex(where: { $0.id == target }) else { return }
        tables[index].classTimeList = list
        scheduleSave()
    }

    func applyTerm(_ term: ServiceTermConfiguration, schoolID: String) {
        guard let index = tables.firstIndex(where: { $0.id == selectedTableId }) else { return }
        tables[index].schoolID = schoolID
        tables[index].termID = term.id
        tables[index].termVersion = term.version
        tables[index].termWeekCount = term.weekCount
        tables[index].termTimezone = term.timezone
        tables[index].semesterStartMonday = term.semesterStartMonday
        tables[index].classTimeList = term.classTimes
        tables[index].calendarAdjustments = term.calendarAdjustments
        scheduleSave(); resetWeekToLive()
    }

    func refreshServiceConfiguration(_ schools: [ServiceSchoolConfiguration]) {
        var selectedChanged = false
        var changed = false
        for index in tables.indices {
            guard let schoolID = tables[index].schoolID,
                  tables[index].serviceConfigurationUpdatesEnabled != false,
                  let school = schools.first(where: { $0.id == schoolID }),
                  let term = school.currentTerm else { continue }
            let classTimes = term.classTimes
            let adjustments = term.calendarAdjustments
            guard tables[index].termID != term.id
                    || tables[index].termVersion != term.version
                    || tables[index].semesterStartMonday != term.semesterStartMonday
                    || tables[index].termWeekCount != term.weekCount
                    || tables[index].classTimeList != classTimes
                    || tables[index].calendarAdjustments != adjustments else { continue }
            tables[index].termID = term.id
            tables[index].termVersion = term.version
            tables[index].termWeekCount = term.weekCount
            tables[index].termTimezone = term.timezone
            tables[index].semesterStartMonday = term.semesterStartMonday
            tables[index].classTimeList = classTimes
            tables[index].calendarAdjustments = adjustments
            selectedChanged = selectedChanged || tables[index].id == selectedTableId
            changed = true
        }
        guard changed else { return }
        scheduleSave()
        if selectedChanged { resetWeekToLive() }
    }

    func deleteTable(_ id: Int) {
        guard tables.contains(where: { $0.id == id }) else { return }
        tables.removeAll { $0.id == id }
        courses.removeAll { $0.tableId == id }
        if selectedTableId == id {
            selectedTableId = tables.first?.id ?? 0
        }
        displayWeek = 1
        scheduleSave()
        refreshForToday()
    }

    func selectTable(_ id: Int) {
        guard tables.contains(where: { $0.id == id }) else { return }
        selectedTableId = id
        resetWeekToLive()
        scheduleSave()
    }

    // MARK: Course editing

    @discardableResult
    func addCourse(_ course: Course) -> Course {
        var value = course
        value.id = nextCourseId
        nextCourseId += 1
        value.tableId = selectedTableId
        if value.courseKey == nil {
            value.courseKey = nextCourseKey
            nextCourseKey += 1
        }
        courses.append(value)
        scheduleSave()
        return value
    }

    func updateCourse(_ course: Course) {
        guard let index = courses.firstIndex(where: { $0.id == course.id }) else { return }
        courses[index] = course
        scheduleSave()
    }

    /// 收起或恢复一门课。恢复之后它会重新回到原来的时段，
    /// 和当初让位的那节并排显示。
    func setCourse(id: Int, hidden: Bool) {
        guard let index = courses.firstIndex(where: { $0.id == id }) else { return }
        courses[index].hidden = hidden ? true : nil
        scheduleSave()
    }

    func deleteCourse(id: Int) {
        courses.removeAll { $0.id == id }
        scheduleSave()
    }

    /// Deletes every row that belongs to the same course as `course`.
    func deleteCourseFamily(_ course: Course) {
        if let key = course.courseKey {
            courses.removeAll { $0.courseKey == key }
        } else {
            deleteCourse(id: course.id)
        }
        scheduleSave()
    }

    func deleteAllCourses(inTable id: Int? = nil) {
        let target = id ?? selectedTableId
        courses.removeAll { $0.tableId == target }
        scheduleSave()
    }

    func eraseEverything() {
        courses.removeAll()
        tables = []
        selectedTableId = 0
        // Saved share credentials can still refer to old table IDs. Never reuse
        // those IDs for unrelated tables created after a cloud-synced deletion.
        didSeedSample = true
        scheduleSave()
    }

    // MARK: Import

    /// Installs a freshly parsed schedule. `mode` decides whether the courses
    /// join the current table or arrive as a new one, mirroring the Flutter
    /// importers that always created a table per import.
    @discardableResult
    func install(
        payload: ImportedSchedule,
        mode: ImportMode
    ) -> CourseTable {
        let table: CourseTable
        switch mode {
        case .newTable:
            table = addTable(
                name: payload.name,
                semesterStartMonday: payload.semesterStartMonday ?? "",
                classTimeList: payload.classTimeList ?? []
            )
        case .replaceCurrent:
            table = selectedTable ?? addTable(name: payload.name)
            if let index = tables.firstIndex(where: { $0.id == table.id }) {
                if let start = payload.semesterStartMonday, !start.isEmpty {
                    tables[index].semesterStartMonday = start
                }
                if let list = payload.classTimeList, !list.isEmpty {
                    tables[index].classTimeList = list
                }
            }
            courses.removeAll { $0.tableId == table.id }
        case .appendToCurrent:
            table = selectedTable ?? addTable(name: payload.name)
            if let start = payload.semesterStartMonday, !start.isEmpty, table.semesterStartMonday.isEmpty {
                updateSemesterStart(start)
            }
        }

        if let schoolID = payload.schoolID, let termID = payload.termID,
           let index = tables.firstIndex(where: { $0.id == table.id }) {
            tables[index].schoolID = schoolID
            tables[index].termID = termID
            tables[index].termVersion = payload.termVersion
            tables[index].termWeekCount = payload.termWeekCount
            tables[index].termTimezone = payload.termTimezone
            tables[index].serviceConfigurationUpdatesEnabled = !payload.configurationFrozen
            if let start = payload.semesterStartMonday { tables[index].semesterStartMonday = start }
            if let times = payload.classTimeList, !times.isEmpty { tables[index].classTimeList = times }
            // 学期换了就整张替换，包括「这学期没有调休」这种空表。
            tables[index].calendarAdjustments = payload.calendarAdjustments
        }

        for item in payload.courses {
            var course = item
            course.id = nextCourseId
            nextCourseId += 1
            course.tableId = table.id
            course.courseKey = nextCourseKey
            nextCourseKey += 1
            courses.append(course)
        }
        scheduleSave()
        resetWeekToLive()
        return table
    }

    /// 手动创建向导的最后一步：新建课表，写入学期、节次和课程。
    /// 同一门课的几个上课时间共用一个 `courseKey`，颜色和编辑都按一门课算。
    @discardableResult
    func installManualSchedule(_ draft: ManualScheduleDraft) -> CourseTable {
        let table = addTable(
            name: draft.trimmedName,
            semesterStartMonday: draft.semesterStartMonday,
            classTimeList: draft.classTimes
        )
        if let index = tables.firstIndex(where: { $0.id == table.id }) {
            tables[index].termWeekCount = min(max(draft.weekCount, 1), 40)
        }
        for group in draft.courseRows(tableId: table.id) {
            let key = nextCourseKey
            nextCourseKey += 1
            for row in group {
                var course = row
                course.id = nextCourseId
                nextCourseId += 1
                course.courseKey = key
                courses.append(course)
            }
        }
        scheduleSave()
        resetWeekToLive()
        return tables.first { $0.id == table.id } ?? table
    }

    enum ImportMode: String, CaseIterable, Identifiable {
        case replaceCurrent
        case newTable
        case appendToCurrent

        var id: String { rawValue }

        var title: String {
            switch self {
            case .replaceCurrent: return "覆盖当前课表"
            case .newTable: return "新建课表"
            case .appendToCurrent: return "追加到当前课表"
            }
        }
    }

    // MARK: Settings

    func updateSettings(_ update: (inout AppSettings) -> Void) {
        var value = settings
        update(&value)
        settings = value
        scheduleSave()
    }

    // MARK: Export / import

    struct ExportDocument: Codable {
        var version = 1
        var exportedAt = Date()
        var settings: AppSettings
        var tables: [CourseTable]
        var courses: [Course]
        /// Absent in backups written before display preferences travelled along.
        var display: NativeSchedulePreferences.DisplaySnapshot?
    }

    func exportDocument() -> ExportDocument {
        ExportDocument(
            settings: settings,
            tables: tables,
            courses: courses,
            display: NativeSchedulePreferences.shared.makeSnapshot()
        )
    }

    /// Restores an exported document, keeping the current ids unique.
    func restore(_ document: ExportDocument) {
        // Tables arrive with ids from another install, so every one of them is
        // remapped and every course follows its table.
        var tableRemap: [Int: Int] = [:]
        var newTables: [CourseTable] = []
        for var table in document.tables {
            // Restoring a backup creates independent copies, not cloud aliases.
            table.syncID = UUID().uuidString
            let newId = nextTableId
            nextTableId += 1
            tableRemap[table.id] = newId
            table.id = newId
            newTables.append(table)
        }
        if newTables.isEmpty && !document.courses.isEmpty {
            let table = CourseTable(id: nextTableId, name: SchoolDefaults.defaultTableName)
            nextTableId += 1
            newTables = [table]
        }
        var newCourses: [Course] = []
        for var course in document.courses {
            course.id = nextCourseId
            nextCourseId += 1
            // An unknown table (a hand-edited backup) lands in the first one
            // instead of disappearing from the grid.
            course.tableId = tableRemap[course.tableId] ?? newTables[0].id
            course.courseKey = nextCourseKey
            nextCourseKey += 1
            newCourses.append(course)
        }
        tables.append(contentsOf: newTables)
        courses.append(contentsOf: newCourses)
        normalize()
        resetWeekToLive()
        // Tables and courses merge; display preferences are single values, so
        // the backup's copy wins. Older backups carry none and change nothing.
        if let display = document.display {
            NativeSchedulePreferences.shared.apply(display)
        }
        scheduleSave()
    }

    /// JSON backup written by the settings screen.
    func makeExportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(exportDocument())
    }

    func importData(_ data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(ExportDocument.self, from: data)
        restore(document)
    }

    // MARK: Persistence

    private func normalize() {
        // 老版本和恢复备份都可能带进同名课表，按先后给后来的补序号。
        var seen = Set<String>()
        var syncIDs = Set<String>()
        for index in tables.indices {
            let id = tables[index].syncID ?? ""
            if UUID(uuidString: id) == nil || !syncIDs.insert(id).inserted {
                tables[index].syncID = UUID().uuidString
                syncIDs.insert(tables[index].syncID!)
            }
            let base = tables[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
            var name = base
            var suffix = 2
            while seen.contains(name) || (name != base && isTableNameTaken(name)) {
                name = "\(base)（\(suffix)）"
                suffix += 1
            }
            tables[index].name = name
            seen.insert(name)
        }
        if !tables.contains(where: { $0.id == selectedTableId }) {
            selectedTableId = tables.first?.id ?? 0
        }
        if nextCourseId <= (courses.map(\.id).max() ?? 0) {
            nextCourseId = (courses.map(\.id).max() ?? 0) + 1
        }
        if nextTableId <= (tables.map(\.id).max() ?? 0) {
            nextTableId = (tables.map(\.id).max() ?? 0) + 1
        }
        if nextCourseKey <= (courses.compactMap(\.courseKey).max() ?? 0) {
            nextCourseKey = (courses.compactMap(\.courseKey).max() ?? 0) + 1
        }
        settings.weekCount = min(max(settings.weekCount, 1), 40)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    @discardableResult
    func saveNow() -> Bool {
        guard didLoad, let fileURL, !saveBlocked else { return false }
        normalizeCloudIDs()
        let previousDocument = cloudSync.document
        cloudSync.capture(cloudSnapshot())
        var state = AppStateFile()
        state.settings = settings
        state.tables = tables
        state.courses = courses
        state.selectedTableId = selectedTableId
        state.nextCourseId = nextCourseId
        state.nextTableId = nextTableId
        state.nextCourseKey = nextCourseKey
        state.didSeedSample = didSeedSample
        state.unifiedCalendarAdjustments = unifiedCalendarAdjustments
        state.cloudSync = cloudSync
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: fileURL, options: .atomic)
            loadErrorMessage = nil
            if previousDocument != cloudSync.document {
                NotificationCenter.default.post(name: .naptableCloudContentChanged, object: self)
            }
            return true
        } catch {
            loadErrorMessage = "本地数据保存失败：\(error.localizedDescription)"
            return false
        }
    }

    private func normalizeCloudIDs() {
        for index in tables.indices where tables[index].syncID == nil {
            tables[index].syncID = UUID().uuidString
        }
    }

    func cloudSnapshot() -> [String: CloudSyncPayload] {
        var values: [String: CloudSyncPayload] = [:]
        for table in tables {
            let payload = CloudSyncPayload.table(CloudTable(
                table: table, courses: courses.filter { $0.tableId == table.id }, weekCount: weekCount(of: table)
            ))
            values[payload.key] = payload
        }
        let sharing = ScheduleSharingService.shared
        for var shared in sharing.sharedSchedules {
            // Fetch time is a device cache detail, not a user edit.
            shared.fetchedAt = Date(timeIntervalSince1970: 0)
            let payload = CloudSyncPayload.shared(shared)
            values[payload.key] = payload
        }
        for var credential in sharing.myShares {
            let tableSyncID = tables.first { $0.id == credential.tableID }?.syncID
            credential.tableID = nil
            let payload = CloudSyncPayload.credential(CloudCredential(credential: credential, tableSyncID: tableSyncID))
            values[payload.key] = payload
        }
        return values
    }

    func bindCloudAccount(_ accountID: String) throws {
        if let previous = cloudSync.accountID, previous != accountID { throw CloudSyncFailure.accountChanged }
        cloudSync.accountID = accountID
        guard saveNow() else { throw CloudSyncFailure.localStorage }
    }

    /// Apply all entities before publishing the saved journal. Local selection,
    /// appearance and notification permissions never come from the cloud.
    func applyCloudDocument(_ incoming: CloudSyncDocument) throws {
        let incoming = try incoming.validated()
        guard saveNow() else { throw CloudSyncFailure.localStorage }
        let merged = cloudSync.document.merged(with: incoming)
        let before = cloudSnapshot()
        // Keep a recovery copy before replacing any local content, including
        // concurrent edits to the same timetable. No backup is uploaded.
        if merged.entries.contains(where: { key, entry in
            before[key] != nil && before[key] != entry.payload
        }), let fileURL {
            let backup = fileURL.deletingLastPathComponent().appendingPathComponent("before-icloud-\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: fileURL, to: backup)
            for old in cloudRecoveryCopies.dropFirst(5) { try? FileManager.default.removeItem(at: old.url) }
        }

        for (key, entry) in merged.entries.sorted(by: { $0.key < $1.key }) where key.hasPrefix("table:") {
            let syncID = String(key.dropFirst("table:".count))
            let existing = tables.first { $0.syncID == syncID }
            guard entry.payload != before[key] else { continue }
            if let existing { courses.removeAll { $0.tableId == existing.id } }
            guard case .table(let value) = entry.payload else {
                tables.removeAll { $0.syncID == syncID }
                continue
            }
            var table = value.table
            table.id = existing?.id ?? nextTableId
            if existing == nil { nextTableId += 1 }
            if let index = tables.firstIndex(where: { $0.syncID == syncID }) { tables[index] = table }
            else { tables.append(table) }
            var keys: [Int: Int] = [:]
            for var course in value.courses {
                course.id = nextCourseId
                nextCourseId += 1
                course.tableId = table.id
                if let key = course.courseKey {
                    if keys[key] == nil { keys[key] = nextCourseKey; nextCourseKey += 1 }
                    course.courseKey = keys[key]
                }
                courses.append(course)
            }
        }
        let shared = merged.entries.values.compactMap { entry -> FollowedSchedule? in
            if case .shared(let value) = entry.payload { return value }
            return nil
        }.sorted { $0.meta.code < $1.meta.code }
        let credentials = merged.entries.values.compactMap { entry -> ShareCredential? in
            guard case .credential(let value) = entry.payload else { return nil }
            var credential = value.credential
            credential.tableID = tables.first { $0.syncID == value.tableSyncID }?.id
            return credential
        }.sorted { $0.code < $1.code }
        ScheduleSharingService.shared.applyCloudLibrary(shared: shared, credentials: credentials)
        cloudSync.document = merged
        cloudSync.baseline = cloudSnapshot()
        // Resolve independently created equal names in the same order everywhere.
        tables.sort { ($0.syncID ?? "") < ($1.syncID ?? "") }
        normalize()
        displayWeek = min(max(displayWeek, 1), maxWeeks)
        guard saveNow() else { throw CloudSyncFailure.localStorage }
    }

    struct CloudRecoveryCopy: Identifiable {
        let url: URL
        let date: Date
        var id: URL { url }
    }

    var cloudRecoveryCopies: [CloudRecoveryCopy] {
        guard let directory = fileURL?.deletingLastPathComponent(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.creationDateKey]
              ) else { return [] }
        return files.filter { $0.lastPathComponent.hasPrefix("before-icloud-") && $0.pathExtension == "json" }
            .map { CloudRecoveryCopy(url: $0, date: (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
            .sorted { $0.date > $1.date }
    }

    func restoreCloudRecovery(_ copy: CloudRecoveryCopy) throws {
        guard cloudRecoveryCopies.contains(where: { $0.url == copy.url }) else { throw CloudSyncFailure.invalidData }
        let state = try JSONDecoder().decode(AppStateFile.self, from: Data(contentsOf: copy.url))
        restore(ExportDocument(settings: state.settings, tables: state.tables, courses: state.courses, display: nil))
        guard saveNow() else { throw CloudSyncFailure.localStorage }
    }
}
