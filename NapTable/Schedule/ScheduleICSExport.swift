import SwiftUI

/// Builds a one-week `.ics` document for the Apple Calendar share action.
/// Ported from CpuTime 4.0; the export is produced locally because NapTable has
/// no server round-trip for a calendar file.
enum NativeScheduleICSExporter {
    static func make(
        result: NativeScheduleResult,
        week: NativeCalendarWeek,
        periods: [NativeSchedulePeriod],
        adjustments: [String: ResolvedCalendarAdjustment] = [:]
    ) -> String {
        var lines = [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//NapTable//Schedule//CN",
            "CALSCALE:GREGORIAN", "METHOD:PUBLISH",
        ]
        // 导出的是「这一周实际要上的课」：调休放假的那天不导出，补班那天导出它
        // 实际要上的那一天的课。
        for column in 1...7 {
            guard week.days.indices.contains(column - 1) else { continue }
            let dateText = week.days[column - 1]
            guard let day = parseDate(dateText) else { continue }
            let adjustment = adjustments[dateText]
            if adjustment?.suppressesCourses == true { continue }
            let sourceDay = adjustment?.sourceDay ?? column
            let sourceWeek = adjustment?.sourceWeek ?? week.week
            for cell in result.cells where cell.day == sourceDay {
                for course in cell.courses {
                    guard course.weekList.isEmpty || course.weekList.contains(sourceWeek) else { continue }
                    let range = NativeSchedulePeriod.normalizedRange(
                        bigSlot: cell.bigSlot,
                        startSlot: course.startSlot,
                        endSlot: course.endSlot,
                        periods: periods
                    )
                    guard let startPeriod = periods.first(where: { $0.number == range.start }),
                          let endPeriod = periods.first(where: { $0.number == range.end }),
                          let start = date(day: day, time: startPeriod.startTime),
                          let end = date(day: day, time: endPeriod.endTime), end > start else { continue }
                    let identity = course.nativeId ?? course.sourceKey ?? course.name
                    let uid = "\(week.week)-\(column)-\(range.start)-\(range.end)-\(identity)"
                        .unicodeScalars.map { $0.value < 128 ? String($0) : String(format: "%02X", $0.value) }.joined()
                    lines.append("BEGIN:VEVENT")
                    lines.append("UID:\(escape(uid))@naptable")
                    lines.append("DTSTAMP:\(format(Date.now))")
                    lines.append("DTSTART;TZID=Asia/Shanghai:\(format(start))")
                    lines.append("DTEND;TZID=Asia/Shanghai:\(format(end))")
                    lines.append("SUMMARY:\(escape(course.name.trimmedNonEmpty ?? "课程"))")
                    if let location = course.location?.trimmedNonEmpty { lines.append("LOCATION:\(escape(location))") }
                    let details = [course.teacher?.trimmedNonEmpty, course.slotNote?.trimmedNonEmpty]
                        .compactMap { $0 }.joined(separator: " · ")
                    if !details.isEmpty { lines.append("DESCRIPTION:\(escape(details))") }
                    lines.append("END:VEVENT")
                }
            }
        }
        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private static func parseDate(_ value: String) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func date(day: Date, time: String) -> Date? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = parts[0]
        components.minute = parts[1]
        components.second = 0
        return calendar.date(from: components)
    }

    private static func format(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter.string(from: value)
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
