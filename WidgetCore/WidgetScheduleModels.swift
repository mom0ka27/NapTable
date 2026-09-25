import Foundation

/// The App Group the widget extension and the app share.
///
/// Ported from `../CPU-Web/ios_next` (CpuTime) `WatchShared/AppGroupIdentifier.swift`.
/// The identifier is read from `CPUAppGroupIdentifier` so a developer with a
/// different team prefix only edits build settings.
nonisolated enum AppGroupIdentifier {
    static let fallback = "group.me.mom0ka27.naptable"

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

    var id: String {
        [name, startTime, endTime, location].compactMap { $0 }.joined(separator: "|")
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

    var hasUsableStartTime: Bool { Self.minutes(startTime) != nil }

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

    static func empty(date: String, offset: Int) -> WidgetDay {
        let target = Calendar.current.date(byAdding: .day, value: offset, to: .now) ?? .now
        let weekday = Calendar.current.component(.weekday, from: target)
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

struct WidgetCourseWindow {
    let courses: [WidgetCourse]
    let remainingCount: Int
    let skippedCompletedCount: Int
}

/// The payload the app writes into the App Group container. `weekDays` carries
/// the whole selected week so the two-day widget can show tomorrow.
struct WidgetSchedulePayload: Codable, Equatable {
    let title: String?
    let sourceLabel: String?
    let generatedAt: String?
    let semester: String?
    let currentWeek: Int?
    let today: WidgetDay?
    let days: [WidgetDay]?
    let weekDays: [WidgetDay]?
    /// 当前这一周的下一周。周日晚上要显示「明天」时，那一天已经不在 `weekDays` 里了。
    /// 旧版本写的 payload 没有这个字段，解码成 `nil` 即可。
    let nextWeekDays: [WidgetDay]?

    func fullDay(for date: String, fallbackOffset: Int) -> WidgetDay {
        if let exact = knownDay(for: date) { return exact }
        return day(for: date, fallbackOffset: fallbackOffset)
    }

    /// 只在确实有这一天的数据时返回，`nil` 表示这一天不在已同步的周次里。
    func knownDay(for date: String) -> WidgetDay? {
        if let exact = (weekDays ?? []).first(where: { $0.date == date }) { return exact }
        if let exact = (nextWeekDays ?? []).first(where: { $0.date == date }) { return exact }
        if let exact = (days ?? []).first(where: { $0.date == date }) { return exact }
        if today?.date == date { return today }
        return nil
    }

    /// 明天那一天；不在已同步的周次里就返回 `nil`。
    func tomorrow(now: Date = .now) -> WidgetDay? {
        guard let date = ChineseCalendarInfo.gregorian.date(byAdding: .day, value: 1, to: now) else { return nil }
        return knownDay(for: Self.dateString(date))
    }

    func day(for date: String, fallbackOffset: Int) -> WidgetDay {
        if fallbackOffset == 0, today?.date == date, let today { return today }
        if let exact = (days ?? []).first(where: { $0.date == date }) { return exact }
        let targetDay = Calendar.current.component(.weekday, from: Calendar.current.date(byAdding: .day, value: fallbackOffset, to: .now) ?? .now)
        let mondayBasedDay = targetDay == 1 ? 7 : targetDay - 1
        return (days ?? []).first(where: { $0.day == mondayBasedDay })
            ?? (fallbackOffset == 0 ? today : nil)
            ?? WidgetDay.empty(date: date, offset: fallbackOffset)
    }

    /// Widgets stay on the current date. A finished school day shows an empty
    /// state rather than rolling forward to a later day's classes.
    func currentDay(now: Date = .now) -> WidgetDay {
        fullDay(for: Self.dateString(now), fallbackOffset: 0)
    }

    /// Today's classes that have not finished yet, at most two. With
    /// `.nextCourseDay` a finished day rolls forward to the nearest day that
    /// has classes, and shows that day's first two.
    func upcoming(
        now: Date = .now,
        afterClass: ScheduleWidgetAfterClassStyle = .tomorrow
    ) -> (WidgetDay, [WidgetCourse]) {
        let day = currentDay(now: now)
        let courses = remainingCourses(in: day, now: now)
        if courses.isEmpty, afterClass == .nextCourseDay, let next = nextCourseDay(after: now) {
            return (next.day, Array(next.day.courseList.prefix(2)))
        }
        return (day, Array(courses.prefix(2)))
    }

    /// 今天还没上完的课（包括没有具体时间、没法判断的）。
    func remainingCourses(in day: WidgetDay, now: Date = .now) -> [WidgetCourse] {
        let minutes = Self.minutesSinceMidnight(now)
        return day.courseList.filter {
            $0.endMinutes >= minutes || (!$0.hasUsableStartTime && $0.endMinutes <= 0)
        }
    }

    /// 今天之后一周之内第一个有课的日期；已同步的周次里找不到就是 `nil`。
    func nextCourseDay(after now: Date = .now) -> (day: WidgetDay, offset: Int)? {
        for offset in 1...7 {
            guard let date = ChineseCalendarInfo.gregorian.date(byAdding: .day, value: offset, to: now),
                  let day = knownDay(for: Self.dateString(date)),
                  !day.courseList.isEmpty else { continue }
            return (day, offset)
        }
        return nil
    }

    /// 今天还有课就是今天，否则是最近一个有课的日期；两个都没有时退回今天。
    func preferredCourseDay(now: Date = .now) -> (day: WidgetDay, offset: Int) {
        let today = currentDay(now: now)
        if !remainingCourses(in: today, now: now).isEmpty { return (today, 0) }
        return nextCourseDay(after: now) ?? (today, 0)
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
