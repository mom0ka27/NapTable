import Foundation

/// Week-number arithmetic ported from the Flutter app's `WeekUtil`.
///
/// The Flutter version persisted "the Monday of the week the app last ran plus
/// the week index that belonged to it" and advanced the index whenever the
/// stored Monday was older. The same result is reached here from a semester
/// anchor: the Monday of week 1. Without an anchor the app falls back to a
/// manually chosen week so the schedule is still usable.
nonisolated enum WeekCalculator {
    struct Snapshot: Equatable {
        /// The week that contains `date`. `0` means the semester has not started.
        let currentWeek: Int
        let monday: Date
        let days: [Date]
        let isBeforeSemester: Bool
        let isAfterSemester: Bool
    }

    /// `WeekUtil._getMonday()` normalised to a calendar-stable value.
    static func monday(of date: Date, calendar source: Calendar = WeekCalculator.calendar) -> Date {
        var value = source.startOfDay(for: date)
        while source.component(.weekday, from: value) != 2 { // 2 = Monday
            value = source.date(byAdding: .day, value: -1, to: value) ?? value
        }
        return value
    }

    static func snapshot(
        for date: Date,
        semesterStartMonday: String,
        maxWeeks: Int = SchoolDefaults.maxWeeks,
        calendar source: Calendar = WeekCalculator.calendar
    ) -> Snapshot? {
        guard let start = parseDay(semesterStartMonday) else { return nil }
        let anchor = monday(of: start, calendar: source)
        let current = monday(of: date, calendar: source)
        let delta = source.dateComponents([.day], from: anchor, to: current).day ?? 0
        let week = Int(floor(Double(delta) / 7.0)) + 1
        let days = (0..<7).compactMap { source.date(byAdding: .day, value: $0, to: current) }
        return Snapshot(
            currentWeek: week < 1 ? 0 : min(week, maxWeeks),
            monday: current,
            days: days,
            isBeforeSemester: week < 1,
            isAfterSemester: week > maxWeeks
        )
    }

    static func parseDay(_ value: String) -> Date? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }

    static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func monthDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MM/dd"
        return formatter.string(from: date)
    }

    static func monthDayShort(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "M.d"
        return formatter.string(from: date)
    }

    static func month(_ date: Date) -> Int {
        calendar.component(.month, from: date)
    }

    static func weekday(_ date: Date) -> Int {
        let value = calendar.component(.weekday, from: date)
        return value == 1 ? 7 : value - 1
    }

    /// `<year>-<month>-<day>` in the school's time zone.
    static func todayText() -> String { format(Date()) }

    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        value.locale = Locale(identifier: "zh_CN")
        return value
    }

    /// The seven day labels used by the grid header.
    static let weekdayNames = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    static let weekdayShortNames = ["一", "二", "三", "四", "五", "六", "日"]

    static func weekdayName(_ day: Int) -> String {
        weekdayNames.indices.contains(day - 1) ? weekdayNames[day - 1] : "周\(day)"
    }
}
