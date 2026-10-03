import Foundation

/// The App Group the widget extension and the app share.
///
/// Ported from `../CPU-Web/ios_next` (CpuTime) `WatchShared/AppGroupIdentifier.swift`.
/// The identifier is read from `CPUAppGroupIdentifier` so a developer with a
/// different team prefix only edits build settings.
nonisolated enum AppGroupIdentifier {
    static let fallback = "group.com.niyiwei.naptable"

    static func resolved(bundle: Bundle = .main) -> String {
        let configured = bundle.object(forInfoDictionaryKey: "CPUAppGroupIdentifier") as? String
        let value = configured?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? fallback : value
    }
}

/// A course as the widget extension sees it.
///
/// Ported from `../CPU-Web/ios_next` (CpuTime) `CPUWebWidgets/WidgetModels.swift`
/// with one structural change: CpuTime's widget fetched the timetable from a Web
/// endpoint, while NapTable is local-only, so the app writes this same shape into
/// the App Group (see `ScheduleWidgetStore`).
struct WidgetCourse: Codable, Identifiable, Equatable {
    let name: String?
    let teacher: String?
    let location: String?
    let note: String?
    let slotNote: String?
    let startTime: String?
    let endTime: String?
    let startSlot: Int?
    let endSlot: Int?
    var occurrenceID: String? = nil
    var displayPriority: Int? = nil

    var id: String {
        if let occurrenceID { return occurrenceID }
        return [name, startTime, endTime, location].compactMap { $0 }.joined(separator: "|")
    }

    var displayName: String { normalized(name) ?? "课程" }
    var startLabel: String { normalized(startTime) ?? "--:--" }

    var normalizedLocation: String? { normalized(location) }
    var normalizedTeacher: String? { normalized(teacher) }

    var metadata: String {
        let values = [normalizedLocation, normalizedTeacher, normalized(note) ?? normalized(slotNote)]
            .compactMap { $0 }
        return values.isEmpty ? "地点待确认" : values.joined(separator: " · ")
    }

    var timeRange: String {
        guard let start = normalized(startTime) else { return "时间待确认" }
        guard let end = normalized(endTime) else { return start }
        return "\(start) - \(end)"
    }

    var endMinutes: Int {
        if let value = Self.minutes(endTime) { return value }
        if let value = Self.minutes(startTime) { return value + 45 }
        return 0
    }

    var startMinutes: Int? { Self.minutes(startTime) }
    var hasUsableStartTime: Bool { startMinutes != nil }

    func isInProgress(at minutes: Int) -> Bool {
        guard let start = startMinutes else { return false }
        return start <= minutes && !hasEnded(at: minutes)
    }

    func hasEnded(at minutes: Int) -> Bool {
        endMinutes > 0 && endMinutes < minutes
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func minutes(_ value: String?) -> Int? {
        guard let value, value.count >= 5 else { return nil }
        let pieces = value.prefix(5).split(separator: ":")
        guard pieces.count == 2, let hour = Int(pieces[0]), let minute = Int(pieces[1]) else { return nil }
        return hour * 60 + minute
    }
}

struct WidgetDay: Codable, Identifiable, Equatable {
    let day: Int?
    let label: String?
    let date: String?
    let week: Int?
    let isToday: Bool?
    let courses: [WidgetCourse]?
    /// 调休提示，例如「上 10.9 周四的课」「国庆节放假」。旧 payload 没有这个字段。
    let note: String?

    init(
        day: Int?,
        label: String?,
        date: String?,
        week: Int?,
        isToday: Bool?,
        courses: [WidgetCourse]?,
        note: String? = nil
    ) {
        self.day = day
        self.label = label
        self.date = date
        self.week = week
        self.isToday = isToday
        self.courses = courses
        self.note = note
    }

    var normalizedNote: String? {
        guard let value = note?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    var id: String { date ?? "day-\(day ?? 0)" }
    var courseList: [WidgetCourse] { courses ?? [] }
    var displayLabel: String {
        (label ?? "")
            .replacingOccurrences(of: "今天", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var shortLabel: String { displayLabel.isEmpty ? compactDate : displayLabel }

    var compactDate: String {
        guard let date, date.count >= 10 else { return "课表" }
        let month = Int(date.dropFirst(5).prefix(2)) ?? 0
        let day = Int(date.dropFirst(8).prefix(2)) ?? 0
        return month > 0 && day > 0 ? "\(month).\(day)" : String(date.dropFirst(5)).replacingOccurrences(of: "-", with: ".")
    }

    func courseWindow(limit: Int, nowMinutes: Int?) -> WidgetCourseWindow {
        let safeLimit = max(0, limit)
        let overflow = max(0, courseList.count - safeLimit)
        let completedPrefix = nowMinutes.map { minutes in
            courseList.prefix { $0.hasEnded(at: minutes) }.count
        } ?? 0
        let skippedCompletedCount = min(overflow, completedPrefix)
        let visible = Array(courseList.dropFirst(skippedCompletedCount).prefix(safeLimit))
        let remainingCount = max(0, courseList.count - skippedCompletedCount - visible.count)
        return WidgetCourseWindow(
            courses: visible,
            remainingCount: remainingCount,
            skippedCompletedCount: skippedCompletedCount
        )
    }

    /// 日期写坏了、认不出是星期几时的退路：真实的今天往后数几天。数据正常时用不到。
    static func brokenDateFallback(offset: Int) -> Date { Calendar.current.date(byAdding: .day, value: offset, to: WidgetClock.now) ?? WidgetClock.now }

    static func empty(date: String, offset: Int) -> WidgetDay {
        // 星期几按日期本身算；日期写坏了才退回「现在往后数几天」。
        let target = ChineseCalendarInfo.date(fromDate: date) ?? brokenDateFallback(offset: offset)
        let weekday = ChineseCalendarInfo.gregorian.component(.weekday, from: target)
        let day = weekday == 1 ? 7 : weekday - 1
        let labels = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        return WidgetDay(
            day: day,
            label: labels[day - 1],
            date: date,
            week: nil,
            isToday: offset == 0,
            courses: []
        )
    }
}

/// 今天不能照常列课的原因，见 `WidgetSchedulePayload.notice(now:)`。
enum WidgetScheduleNotice: Equatable {
    case vacation(WidgetVacation)
    /// 学期内，但数据里没有今天：「打开 App 更新课表」。
    case stale
}

/// 学期之外的日子。
struct WidgetVacation: Equatable {
    enum Kind: Equatable {
        case winter
        case summer
        /// 学期和月份都判断不出是寒假还是暑假。
        case other
    }

    let kind: Kind
    /// 离开学还有几天。只有学期还没开始时知道；学期已经结束时下学期什么时候开学不知道，为 `nil`。
    let daysUntilTerm: Int?

    var title: String {
        switch kind {
        case .winter: return "寒假ing"
        case .summer: return "暑假ing"
        case .other: return "放假ing"
        }
    }

    /// 「距开学还有 12 天」，不知道开学日期时为 `nil`。
    var countdown: String? {
        guard let days = daysUntilTerm, days > 0 else { return nil }
        return "距开学还有 \(days) 天"
    }

    /// 离学期超过这么多天，就不拿学期推寒暑假了（多半是好几个月没打开 App），改看月份。
    static let termReach = 100

    /// 寒假还是暑假。先看学期：已经结束的是秋季学期（8–10 月开学）、或者快开学的是春季学期
    ///（2–3 月开学）就是寒假，反过来是暑假。学期看不出来（开学月份不典型、离学期太远）时
    /// 看月份：12–3 月寒假、6–9 月暑假，其余只说放假。
    static func kind(termEnded: Bool, termStartMonth: Int?, distance: Int?, month: Int) -> Kind {
        if let startMonth = termStartMonth, (distance ?? 0) <= termReach {
            let autumn = (8...10).contains(startMonth)
            let spring = (2...3).contains(startMonth)
            if (termEnded && autumn) || (!termEnded && spring) { return .winter }
            if (termEnded && spring) || (!termEnded && autumn) { return .summer }
        }
        switch month {
        case 12, 1, 2, 3: return .winter
        case 6...9: return .summer
        default: return .other
        }
    }
}

/// 见 `WidgetSchedulePayload.timelinePlan(from:)`。
struct WidgetTimelinePlan: Equatable {
    /// 每条时间线条目的时刻，从小到大，第一条是现在。
    let dates: [Date]
    /// 什么时候再来要一条新的时间线：次日零点。
    let reload: Date
}

struct WidgetCourseWindow {
    let courses: [WidgetCourse]
    let remainingCount: Int
    let skippedCompletedCount: Int
}

/// The payload the app writes into the App Group container. `weekDays` carries
/// the whole selected week so the two-day widget can show tomorrow.
struct WidgetSchedulePayload: Codable, Equatable {
    /// 「最近有课的一天」往后找几天。一周跨不过中秋接国庆这样的长假，三周连寒暑假前后的空档也够用。
    static let lookaheadDays = 21

    let title: String?
    let sourceLabel: String?
    let generatedAt: String?
    let semester: String?
    let currentWeek: Int?
    let today: WidgetDay?
    let days: [WidgetDay]?
    let weekDays: [WidgetDay]?
    /// `weekDays` 之外、今天所在这一周到学期结束的日子。周日晚上的「明天」、
    /// 「最近有课的一天」（最多往后三周）都在这里找。名字沿用最早只带下一周时的叫法；
    /// 旧版本 App 只写了这一周和之后三周。
    /// 旧版本写的 payload 没有这个字段，解码成 `nil` 即可。
    let nextWeekDays: [WidgetDay]?
    /// 服务端下发的法定放假日（国务院放假安排，含连休里的周末），节假日提示按它算。
    /// 没同步到或旧版本 payload 时为 `nil`，退回离线推算的法定假日。
    var holidays: [PublishedHoliday]? = nil
    /// 学期第 1 周的周一（`yyyy-MM-dd`）和一共几周，小组件靠它认出寒暑假。
    /// 旧版本 payload 没有这两个字段，解码成 `nil`，那就不判断放假。
    var termStart: String? = nil
    var termWeeks: Int? = nil

    func fullDay(for date: String, fallbackOffset: Int) -> WidgetDay {
        if let exact = knownDay(for: date) { return exact }
        // 带日期的数据里没有这一天：课表过期了，或者已经放假。不能拿别的周同一个星期几的课顶上，
        // 那样日期栏是今天、课却是几周前的。只有最早不带日期的 payload 才按星期几找。
        guard !hasDatedDays else { return .empty(date: date, offset: fallbackOffset) }
        return day(for: date, fallbackOffset: fallbackOffset)
    }

    /// 写的时候带了日期（现在的 App 都带）。最早的版本只有星期几。
    var hasDatedDays: Bool {
        ([today].compactMap { $0 } + (weekDays ?? []) + (nextWeekDays ?? []) + (days ?? []))
            .contains { !($0.date ?? "").isEmpty }
    }

    /// 学期的第一天和最后一天（第 1 周周一、最后一周周日）。没带学期信息时为 `nil`。
    var termRange: (start: String, end: String)? {
        guard let termStart, let weeks = termWeeks, weeks > 0,
              let start = ChineseCalendarInfo.date(fromDate: termStart),
              let end = ChineseCalendarInfo.gregorian.date(byAdding: .day, value: weeks * 7 - 1, to: start) else {
            return nil
        }
        return (ChineseCalendarInfo.dateString(start), ChineseCalendarInfo.dateString(end))
    }

    /// 今天在学期之外：寒假、暑假。学期内、或者 payload 没带学期信息时为 `nil`。
    func vacation(on date: String) -> WidgetVacation? {
        guard let range = termRange, let month = Int(date.dropFirst(5).prefix(2)) else { return nil }
        let startMonth = Int(range.start.dropFirst(5).prefix(2))
        if date < range.start {
            let days = ChineseCalendarInfo.dayGap(from: date, to: range.start)
            return WidgetVacation(
                kind: WidgetVacation.kind(termEnded: false, termStartMonth: startMonth, distance: days, month: month),
                daysUntilTerm: days
            )
        }
        if date > range.end {
            let days = ChineseCalendarInfo.dayGap(from: range.end, to: date)
            return WidgetVacation(
                kind: WidgetVacation.kind(termEnded: true, termStartMonth: startMonth, distance: days, month: month),
                daysUntilTerm: nil
            )
        }
        return nil
    }

    /// 今天不能照常列课的原因：放假了，或者课表过期（学期内、带日期的数据里却没有今天，
    /// 现在的 App 带满整个学期，一般是学期中途换了课表、App 又一直没打开；旧版本只带四周，
    /// 四周多没打开 App 也会这样）。两种情况都不显示任何一天的课。
    func notice(now: Date) -> WidgetScheduleNotice? {
        let date = Self.dateString(now)
        if let vacation = vacation(on: date) { return .vacation(vacation) }
        if hasDatedDays, knownDay(for: date) == nil { return .stale }
        return nil
    }

    /// 只在确实有这一天的数据时返回，`nil` 表示这一天不在已同步的周次里。
    func knownDay(for date: String) -> WidgetDay? {
        if let exact = (weekDays ?? []).first(where: { $0.date == date }) { return exact }
        if let exact = (nextWeekDays ?? []).first(where: { $0.date == date }) { return exact }
        if let exact = (days ?? []).first(where: { $0.date == date }) { return exact }
        if today?.date == date { return today }
        return nil
    }

    func day(for date: String, fallbackOffset: Int) -> WidgetDay {
        if fallbackOffset == 0, today?.date == date, let today { return today }
        if let exact = (days ?? []).first(where: { $0.date == date }) { return exact }
        // 星期几按要找的日期本身算：时间线里零点那一条画的是明天，不能拿真实的「现在」推。
        let target = ChineseCalendarInfo.date(fromDate: date) ?? WidgetDay.brokenDateFallback(offset: fallbackOffset)
        let targetDay = ChineseCalendarInfo.gregorian.component(.weekday, from: target)
        let mondayBasedDay = targetDay == 1 ? 7 : targetDay - 1
        return (days ?? []).first(where: { $0.day == mondayBasedDay })
            ?? (fallbackOffset == 0 ? today : nil)
            ?? WidgetDay.empty(date: date, offset: fallbackOffset)
    }

    /// Widgets stay on the current date. A finished school day shows an empty
    /// state rather than rolling forward to a later day's classes.
    func currentDay(now: Date) -> WidgetDay {
        let date = Self.dateString(now)
        // 放假、过期时今天是空的：哪怕数据里恰好有这一天（放假前写的最后一周），也不再列课。
        if notice(now: now) != nil { return .empty(date: date, offset: 0) }
        return fullDay(for: date, fallbackOffset: 0)
    }

    /// Today's classes that have not finished yet, at most two. With
    /// `.nextCourseDay` a finished day rolls forward to the nearest day that
    /// has classes, and shows that day's first two. Nothing left is today
    /// with an empty list, which the widget shows as the rest state.
    func upcoming(
        now: Date,
        afterClass: ScheduleWidgetAfterClassStyle = .nextCourseDay
    ) -> (WidgetDay, [WidgetCourse]) {
        let day = currentDay(now: now)
        let courses = remainingCourses(in: day, now: now)
        if courses.isEmpty, afterClass == .nextCourseDay, let next = nextCourseDay(after: now) {
            return (next.day, Array(next.day.courseList.prefix(2)))
        }
        return (day, Array(courses.prefix(2)))
    }

    /// 今天还没上完的课（包括没有具体时间、没法判断的）。
    func remainingCourses(in day: WidgetDay, now: Date) -> [WidgetCourse] {
        let minutes = Self.minutesSinceMidnight(now)
        return day.courseList.filter {
            $0.endMinutes >= minutes || (!$0.hasUsableStartTime && $0.endMinutes <= 0)
        }
    }

    /// 今天之后三周之内第一个有课的日期；已同步的周次里找不到就是 `nil`。
    func nextCourseDay(after now: Date) -> (day: WidgetDay, offset: Int)? {
        // 放假、过期时显示假期或「打开 App 更新课表」，不往后找课。
        guard notice(now: now) == nil else { return nil }
        for offset in 1...Self.lookaheadDays {
            guard let date = ChineseCalendarInfo.gregorian.date(byAdding: .day, value: offset, to: now),
                  let day = knownDay(for: Self.dateString(date)),
                  !day.courseList.isEmpty else { continue }
            return (day, offset)
        }
        return nil
    }

    /// 小组件的一整条时间线：从 `now` 起画面会变的每个时刻各一条，`reload` 是次日零点。
    ///
    /// 画面只在这几种时刻变：一节课开始（那一分钟起算上课中）、一节课下课后一分钟
    ///（下课那一分钟里课还算没结束，见 `remainingCourses` 的 `>=`）、零点换日（日期栏、假期、
    /// 过期提示、节日祝福都跟着日期走）。所以一次把今天剩下的边界和零点都排好，
    /// 系统按条目自己换，不用每个边界回来要一次，一天只花一次刷新预算。
    ///
    /// 明天的课程边界也带上：零点那次刷新被系统推迟时，明早上下课照样换得过来。
    /// 放假、课表过期时这一天是空的，只有现在和零点两条。
    func timelinePlan(from now: Date) -> WidgetTimelinePlan {
        let calendar = ChineseCalendarInfo.gregorian
        let startOfToday = calendar.startOfDay(for: now)
        let midnight = Self.startOfNextDay(after: now)
        let startOfDayAfter = Self.startOfNextDay(after: midnight)
        let today = displayChanges(on: startOfToday, until: midnight, after: now)
        let tomorrow = displayChanges(on: midnight, until: startOfDayAfter, after: midnight)
        let dates = Set([now, midnight] + today + tomorrow).sorted()
        return WidgetTimelinePlan(dates: dates, reload: midnight)
    }

    /// 某一天里课程开始、下课后一分钟这些时刻，只留 `after` 之后、这一天之内的
    ///（23:59 下课的那一下就是零点，交给零点那一条）。
    private func displayChanges(on startOfDay: Date, until endOfDay: Date, after moment: Date) -> [Date] {
        let day = currentDay(now: startOfDay)
        let minutes = day.courseList.flatMap { course -> [Int] in
            let start = course.startMinutes.map { [$0] } ?? []
            let end = course.endMinutes > 0 ? [course.endMinutes + 1] : []
            return start + end
        }
        return minutes
            .map { startOfDay.addingTimeInterval(TimeInterval($0 * 60)) }
            .filter { $0 > moment && $0 < endOfDay }
    }

    /// `date` 之后的那个零点（按课表的时区）。
    static func startOfNextDay(after date: Date) -> Date {
        let calendar = ChineseCalendarInfo.gregorian
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(24 * 60 * 60)
    }

    static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func minutesSinceMidnight(_ date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    }
}

/// Reads and writes the shared payload.
enum ScheduleWidgetStore {
    static func load(bundle: Bundle = .main) -> WidgetSchedulePayload? {
        guard let defaults = UserDefaults(suiteName: AppGroupIdentifier.resolved(bundle: bundle)),
              let data = defaults.data(forKey: NextWidgetConfiguration.payloadKey) else { return nil }
        return try? JSONDecoder().decode(WidgetSchedulePayload.self, from: data)
    }

    static func save(_ payload: WidgetSchedulePayload, bundle: Bundle = .main) throws {
        guard let defaults = UserDefaults(suiteName: AppGroupIdentifier.resolved(bundle: bundle)) else {
            throw WidgetStoreError.appGroupUnavailable
        }
        defaults.set(try JSONEncoder().encode(payload), forKey: NextWidgetConfiguration.payloadKey)
        defaults.synchronize()
    }

    static func clear(bundle: Bundle = .main) {
        UserDefaults(suiteName: AppGroupIdentifier.resolved(bundle: bundle))?
            .removeObject(forKey: NextWidgetConfiguration.payloadKey)
    }

    enum WidgetStoreError: LocalizedError {
        case appGroupUnavailable

        var errorDescription: String? {
            switch self {
            case .appGroupUnavailable:
                return "App Group 不可用。请确认 App 与小组件使用同一个 App Group。"
            }
        }
    }
}
