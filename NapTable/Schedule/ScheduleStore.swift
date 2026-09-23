import Combine
import Foundation

/// The store surface the ported CpuTime schedule surface (`ScheduleSurfaceView`)
/// talks to.
///
/// The original `NativeScheduleStore` owned WebKit, the schedule bridge, the
/// disk snapshot and the session credentials. NapTable is fully local: its
/// `AppStore` already holds the tables, the courses and the semester anchor, so
/// this type only reshapes that data into the `NativeScheduleResult` /
/// `NativeScheduleCalendar` the view expects, and routes the view's edits back
/// into `AppStore`.
///
/// Vocabulary mapping:
/// - CpuTime "semester" ⇄ NapTable course table (`CourseTable`)
/// - CpuTime "week"     ⇄ `AppStore.displayWeek`
/// - CpuTime "bigSlot"  ⇄ a pair of NapTable teaching slots (`startTime`/`endTime`
///   are translated to real periods, which is what the grid actually renders)
@MainActor
final class NativeScheduleStore: ObservableObject {
    @Published private(set) var state: NativeScheduleState = .idle
    @Published private(set) var result: NativeScheduleResult?
    @Published private(set) var calendar: NativeScheduleCalendar?
    @Published private(set) var periods: [NativeSchedulePeriod] = []
    @Published var selectedSemester: String = ""
    @Published var selectedWeek: String = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdatedAt: Date?
    @Published private(set) var source: NativeScheduleSource?
    @Published private(set) var sourceLabel: String?
    @Published private(set) var scheduleChangeNotice: NativeScheduleChangeNotice?
    /// Courses with no fixed weekday ("自由时间"). CpuTime has no such concept,
    /// so they stay out of the grid and are surfaced separately by the view.
    @Published private(set) var freeCourses: [NativeScheduleCourse] = []

    private var viewedShareCode: String?
    private var sharedWeek: Int?
    var localSelectedWeek: Int? { app?.displayWeek }
    var isReadOnly: Bool { viewedShareCode != nil }

    private weak var app: AppStore?
    private var bag = Set<AnyCancellable>()

    /// Binds the adapter to the app store and keeps it in sync. Safe to call
    /// from `.onAppear` / `.task` on every render.
    func connect(_ app: AppStore) {
        if self.app === app, result != nil { return }
        self.app = app
        bag.removeAll()
        // `objectWillChange` fires *before* the mutation lands, so hop to the
        // next runloop turn to read the settled value.
        app.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &bag)
        rebuild()
    }

    // MARK: Loading

    /// NapTable has no network step, but the surface calls this after a table or
    /// week change and expects the selection to be honoured.
    func load(semester: String?, week: String?, force: Bool) async {
        if let semester { await selectSemester(semester) }
        if let week { commitWeekSelection(week) }
        rebuild()
    }

    func refresh() async {
        rebuild()
    }

    func selectWeek(_ week: String) async {
        commitWeekSelection(week)
    }

    /// Synchronous week commit used by the swipe settle animation.
    func commitWeekSelection(_ week: String) {
        selectedWeek = week
        if let value = Int(week) {
            if isReadOnly { sharedWeek = value } else { app?.selectWeek(value) }
        }
        rebuild()
    }

    func selectSemester(_ value: String) async {
        selectedSemester = value
        if value.hasPrefix("share:") {
            viewedShareCode = String(value.dropFirst(6))
            sharedWeek = nil
        } else if let id = Int(value) {
            viewedShareCode = nil
            sharedWeek = nil
            app?.selectTable(id)
        }
        rebuild()
    }

    func dismissScheduleChangeNotice() {
        scheduleChangeNotice = nil
    }

    /// The whole timetable as one payload for the companion features (widget,
    /// Live Activity). Everything NapTable renders is already in memory, so
    /// there is no load step and no session to check: any table with courses is
    /// "authenticated" as far as a local snapshot is concerned.
    func snapshot(useSharedNotifications: Bool = true) -> NativeScheduleSnapshot? {
        // Following a share means the companion surfaces show *that* person's
        // day. It carries their school's periods and semester anchor, so the
        // projection has to come from the share rather than the local table --
        // otherwise a timetable from another school lands in the wrong rows.
        if useSharedNotifications, ScheduleSharingService.shared.sharedNotificationsEnabled,
           let followed = ScheduleSharingService.shared.followedSchedule {
            let projection = projection(for: followed)
            return NativeScheduleSnapshot(
                scheduleScope: Self.liveActivityScope(for: "share:" + (followed.meta.scheduleScope ?? followed.meta.code)),
                version: 1,
                completeSemester: true,
                cancelled: false,
                source: .cache,
                fetchedAt: followed.fetchedAt,
                periods: projection.classTimes.enumerated().map {
                    NativeSchedulePeriod(number: $0.offset + 1, startTime: $0.element.start, endTime: $0.element.end)
                },
                data: makeResult(projection),
                calendar: makeCalendar(projection),
                auth: NativeScheduleAuth(
                    authenticated: !followed.courses.isEmpty,
                    identity: followed.name,
                    account: followed.meta.code
                ),
                sourceLabel: followed.name,
                schoolID: followed.meta.schoolID,
                termID: followed.meta.termID,
                timeZone: followed.meta.timeZone,
                error: nil
            )
        }
        guard let app else { return nil }
        let local = localProjection(app)
        return NativeScheduleSnapshot(
            scheduleScope: Self.liveActivityScope(for: "local:" + String(app.selectedTableId)),
            version: 1,
            completeSemester: true,
            cancelled: false,
            source: .cache,
            fetchedAt: lastUpdatedAt ?? Date(),
            periods: local.classTimes.enumerated().map {
                NativeSchedulePeriod(number: $0.offset + 1, startTime: $0.element.start, endTime: $0.element.end)
            },
            data: makeResult(local),
            calendar: makeCalendar(local),
            auth: NativeScheduleAuth(
                authenticated: !app.tables.isEmpty,
                identity: app.selectedTable?.name,
                account: String(app.selectedTableId)
            ),
            sourceLabel: nil,
            schoolID: app.selectedTable?.schoolID,
            termID: app.selectedTable?.termID,
            timeZone: app.selectedTable?.termTimezone,
            error: errorMessage
        )
    }

    // MARK: Editing

    /// The CpuTime editor edits a list of "custom" courses plus a list of hidden
    /// source courses. Every NapTable course is local and directly editable, so
    /// all of them round-trip as custom items.
    func loadScheduleEdits() async throws -> NativeScheduleEditState {
        guard !isReadOnly else { throw ScheduleServiceError.server("共享课表只读") }
        guard let app else { return NativeScheduleEditState() }
        let custom = app.currentCourses.map { course in
            NativeScheduleCustomItem(
                id: Self.editID(for: course),
                sourceKey: nil,
                // `0` is the persisted marker for a free-time course. Keep it
                // through the editor round trip so it cannot become Monday.
                day: course.isFreeTime ? 0 : course.weekTime,
                bigSlot: Self.bigSlot(for: course),
                course: Self.makeNativeCourse(course)
            )
        }
        return NativeScheduleEditState(hidden: [], custom: custom)
    }

    func saveScheduleEdits(_ edits: NativeScheduleEditState) async throws {
        guard !isReadOnly else { throw ScheduleServiceError.server("共享课表只读") }
        guard let app else { return }
        let tableID = app.selectedTableId
        let incoming = Dictionary(
            edits.custom.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Anything the editor dropped is a deletion.
        for course in app.currentCourses where incoming[Self.editID(for: course)] == nil {
            app.deleteCourse(id: course.id)
        }

        for item in edits.custom {
            var course = Self.makeCourse(item.course, day: item.day, tableID: tableID)
            if let id = Int(item.id.replacingOccurrences(of: Self.editPrefix, with: "")) {
                course.id = id
                app.updateCourse(course)
            } else {
                app.addCourse(course)
            }
        }
        rebuild()
    }

    // MARK: Derived data

    private static let editPrefix = "course:"

    private static func editID(for course: Course) -> String {
        "\(editPrefix)\(course.id)"
    }

    private static func bigSlot(for course: Course) -> Int {
        guard !course.isFreeTime else { return 0 }
        return bigSlot(start: course.startTime, end: course.endTime)
    }

    private static func bigSlot(start: Int, end: Int) -> Int {
        max(1, (max(start, 1) + 1) / 2)
    }

    private static func liveActivityScope(for key: String) -> String {
        let storageKey = "naptable.liveActivity.scope." + key
        if let saved = UserDefaults.standard.string(forKey: storageKey) { return saved }
        let scope = UUID().uuidString
        UserDefaults.standard.set(scope, forKey: storageKey)
        return scope
    }

    private static func makeNativeCourse(_ course: Course) -> NativeScheduleCourse {
        let start = course.isFreeTime ? nil : max(1, course.startTime)
        return NativeScheduleCourse(
            liveActivitySourceID: course.id > 0 ? String(course.id) : nil,
            nativeId: nil,
            name: course.name,
            teacher: course.teacher,
            weeks: WeekSeries.summary(course.weeks),
            weekList: course.weeks,
            location: course.classroom,
            slotNote: course.info,
            startSlot: start,
            endSlot: start.map { max($0, course.endTime) },
            // A NapTable course is the single source of truth for itself: it is
            // never an override layered on top of an imported course, so it has
            // a custom id but no `sourceKey`. That also keeps the editor's
            // "使用教务安排" (restore original) action hidden — with a source key
            // present, restoring would delete the course.
            sourceKey: nil,
            customId: editID(for: course),
            // Display only: the detail sheet calls a `custom` course "自定义课程
            // / 不属于教务课表". NapTable's own import kind is the accurate
            // signal, so imported courses are still described as 教务课程.
            custom: !course.isImported,
            orphaned: false
        )
    }

    private static func makeCourse(_ native: NativeScheduleCourse, day: Int, tableID: Int) -> Course {
        let normalizedDay = min(max(day, 0), 7)
        let isFreeTime = normalizedDay == 0
        let start = isFreeTime ? 0 : max(1, native.startSlot ?? 1)
        let end = isFreeTime ? 0 : max(start, native.endSlot ?? start)
        return Course(
            tableId: tableID,
            name: native.name,
            weeks: native.weekList,
            weekTime: normalizedDay,
            startTime: start,
            // NapTable stores the *extra* slots, so a 2-slot course keeps 1.
            timeCount: max(0, end - start),
            importType: ImportKind.manual,
            classroom: native.location,
            teacher: native.teacher,
            info: native.slotNote
        )
    }

    private func rebuild() {
        guard let app else { return }

        let shares = ScheduleSharingService.shared.sharedSchedules
        let viewed = shares.first { $0.meta.code == viewedShareCode }
        if viewed == nil { viewedShareCode = nil; sharedWeek = nil }
        let display = viewed.map { projection(for: $0) } ?? localProjection(app)
        let slots = display.classTimes.enumerated().map {
            ScheduleSlot(number: $0.offset + 1, start: $0.element.start, end: $0.element.end)
        }
        ScheduleSlot.all = slots.isEmpty ? ScheduleSlot.fallback : slots
        selectedSemester = viewed.map { "share:" + $0.meta.code } ?? String(app.selectedTableId)
        selectedWeek = String(viewed == nil ? app.displayWeek : min(max(sharedWeek ?? display.currentWeek, 1), display.weekCount))
        periods = display.classTimes.enumerated().map {
            NativeSchedulePeriod(number: $0.offset + 1, startTime: $0.element.start, endTime: $0.element.end)
        }
        let choices = app.tables.map {
            NativeScheduleSemester(value: String($0.id), label: $0.name, current: String($0.id) == selectedSemester)
        } + shares.map {
            NativeScheduleSemester(value: "share:" + $0.meta.code, label: "共享 · " + $0.name,
                                   current: "share:" + $0.meta.code == selectedSemester)
        }
        let visible = ScheduleProjection(
            identifier: selectedSemester, semesters: choices, courses: display.courses,
            classTimes: display.classTimes, semesterStartMonday: display.semesterStartMonday,
            weekCount: display.weekCount, currentWeek: display.currentWeek, adjustments: display.adjustments
        )
        result = makeResult(visible)
        calendar = makeCalendar(visible)
        freeCourses = display.courses.filter(\.isFreeTime).map(Self.makeNativeCourse)
        if app.tables.isEmpty && viewed == nil {
            // `.idle` would fall through to the loading card and spin forever;
            // NapTable always has a table unless the user erased everything.
            state = .failed
            errorMessage = "还没有课表，请先导入课表或在设置里新建一张"
        } else {
            state = .loaded
            errorMessage = app.loadErrorMessage
        }
        source = .cache
        sourceLabel = viewed?.name
        lastUpdatedAt = Date()
    }

    /// Everything the snapshot builders read.
    ///
    /// The local table and a followed share are different sources of the same
    /// shape, and a share brings its own school's first Monday, week count and
    /// bell times. Going through one projection is what keeps a followed
    /// timetable from being drawn against the reader's own periods.
    struct ScheduleProjection {
        let identifier: String
        let semesters: [NativeScheduleSemester]
        let courses: [Course]
        let classTimes: [ClassTime]
        let semesterStartMonday: String
        let weekCount: Int
        let currentWeek: Int
        /// 调休也是按学校、按学期下发的，所以跟着来源走：关注别人的课表时用
        /// 对方学校的调休表，而不是本机这张。
        let adjustments: [CalendarAdjustment]
    }

    private func localProjection(_ app: AppStore) -> ScheduleProjection {
        ScheduleProjection(
            identifier: String(app.selectedTableId),
            semesters: app.tables.map {
                NativeScheduleSemester(value: String($0.id), label: $0.name, current: $0.id == app.selectedTableId)
            },
            courses: app.currentCourses,
            classTimes: app.classTimeList,
            semesterStartMonday: app.effectiveSemesterStartMonday,
            weekCount: max(1, app.maxWeeks),
            currentWeek: max(1, app.liveWeek),
            adjustments: app.selectedTable?.calendarAdjustments ?? []
        )
    }

    /// A followed share, resolved against its own semester anchor rather than
    /// the reader's.
    private func projection(for followed: FollowedSchedule) -> ScheduleProjection {
        let weekCount = max(1, followed.meta.weekCount)
        let week = WeekCalculator.snapshot(
            for: Date(),
            semesterStartMonday: followed.meta.semesterStartMonday,
            maxWeeks: weekCount
        )?.currentWeek ?? 0
        return ScheduleProjection(
            identifier: followed.meta.code,
            semesters: [NativeScheduleSemester(value: followed.meta.code, label: followed.name, current: true)],
            courses: followed.courses,
            classTimes: followed.classTimes,
            semesterStartMonday: followed.meta.semesterStartMonday,
            weekCount: weekCount,
            currentWeek: min(max(week, 1), weekCount),
            adjustments: followed.adjustments
        )
    }

    private func makeResult(_ projection: ScheduleProjection) -> NativeScheduleResult {
        let maxWeek = max(1, projection.weekCount)
        let current = min(max(projection.currentWeek, 1), maxWeek)
        let weeks = (1...maxWeek).map { value in
            NativeScheduleWeek(value: String(value), label: "第 \(value) 周", current: value == current)
        }
        return NativeScheduleResult(
            source: .cache,
            semesters: projection.semesters,
            weeks: weeks,
            currentSemester: projection.identifier,
            currentWeek: String(current),
            cells: makeCells(projection)
        )
    }

    /// Groups the selected table's courses into the cells the grid walks. The
    /// CpuTime surface renders one row per teaching slot and reads `startSlot` /
    /// `endSlot` from each course; `bigSlot` stays the pair-level fallback the
    /// original web bridge used.
    private func makeCells(_ projection: ScheduleProjection) -> [NativeScheduleCell] {
        var buckets: [String: [NativeScheduleCourse]] = [:]
        var order: [(day: Int, bigSlot: Int)] = []

        for course in projection.courses where !course.isFreeTime {
            let day = course.weekTime
            guard (1...7).contains(day) else { continue }
            let start = max(1, course.startTime)
            let end = max(start, course.endTime)
            let bigSlot = Self.bigSlot(start: start, end: end)
            let key = "\(day)-\(bigSlot)"
            if buckets[key] == nil { order.append((day, bigSlot)) }
            buckets[key, default: []].append(Self.makeNativeCourse(course))
        }

        return order
            .sorted { $0.day == $1.day ? $0.bigSlot < $1.bigSlot : $0.day < $1.day }
            .map { NativeScheduleCell(day: $0.day, bigSlot: $0.bigSlot, courses: buckets["\($0.day)-\($0.bigSlot)"] ?? []) }
    }

    private func makeCalendar(_ projection: ScheduleProjection) -> NativeScheduleCalendar {
        let maxWeek = max(1, projection.weekCount)
        // The effective anchor, not the table's raw value: a table that never had
        // a semester start filled in still resolves its weeks from the bundled
        // calendar, which is what makes the header dates and "回到本周" work.
        let anchor = projection.semesterStartMonday
        var weeks: [NativeCalendarWeek] = []

        if let monday = WeekCalculator.parseDay(anchor) {
            // One formatter per projection instead of one per day of the semester.
            let formatter = DateFormatter()
            formatter.calendar = WeekCalculator.calendar
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = WeekCalculator.calendar.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            for value in 1...maxWeek {
                let offset = (value - 1) * 7
                guard let weekMonday = WeekCalculator.calendar.date(byAdding: .day, value: offset, to: monday) else { continue }
                let days = (0..<7).compactMap { day -> String? in
                    guard let date = WeekCalculator.calendar.date(byAdding: .day, value: day, to: weekMonday) else { return nil }
                    return formatter.string(from: date)
                }
                let sunday = WeekCalculator.calendar.date(byAdding: .day, value: 6, to: weekMonday) ?? weekMonday
                weeks.append(NativeCalendarWeek(
                    week: value,
                    days: days,
                    monday: formatter.string(from: weekMonday),
                    sunday: formatter.string(from: sunday)
                ))
            }
        }

        return NativeScheduleCalendar(
            source: .cache,
            semesters: projection.semesters,
            currentSemester: projection.identifier,
            currentWeek: max(1, projection.currentWeek),
            semesterStart: anchor,
            semesterEnd: weeks.last?.sunday ?? "",
            weeks: weeks,
            // 调休按日期覆盖，所以要用和上面那些日期同一个锚点换算。
            adjustments: CalendarAdjustmentResolver.index(projection.adjustments, semesterStartMonday: anchor)
        )
    }
}
