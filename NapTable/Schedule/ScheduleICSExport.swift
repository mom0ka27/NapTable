import SwiftUI

/// Builds a one-week `.ics` document for the Apple Calendar share action.
/// Ported from CpuTime 4.0; the export is produced locally because NapTable has
/// no server round-trip for a calendar file.
enum NativeScheduleICSExporter {
    static func make(
        result: NativeScheduleResult,
        week: NativeCalendarWeek,
        periods: [NativeSchedulePeriod],
        seasonalPeriods: [SeasonalClassTimes]? = nil,
        adjustments: [String: ResolvedCalendarAdjustment] = [:],
        timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    ) -> String {
        // Bell times are the timetable's local clock: written in its own zone.
        let zone = timeZone
        var lines = [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//NapTable//Schedule//CN",
            "CALSCALE:GREGORIAN", "METHOD:PUBLISH",
        ]
        // 导出的是「这一周实际要上的课」：调休放假的那天不导出，补班那天导出它
        // 实际要上的那一天的课。
        for column in 1...7 {
            guard week.days.indices.contains(column - 1) else { continue }
            let dateText = week.days[column - 1]
            let periods = SeasonalClassTimes.resolve(on: dateText,
                base: periods.map { ClassTime(start: $0.startTime, end: $0.endTime) },
                seasons: seasonalPeriods).enumerated().map {
                    NativeSchedulePeriod(number: $0.offset + 1, startTime: $0.element.start, endTime: $0.element.end)
                }
            guard let day = parseDate(dateText, zone: zone) else { continue }
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
                          let start = date(day: day, time: startPeriod.startTime, zone: zone),
                          let end = date(day: day, time: endPeriod.endTime, zone: zone), end > start else { continue }
                    let identity = course.customId ?? course.liveActivitySourceID ?? course.nativeId ?? course.sourceKey ?? course.id
                    let uid = "\(week.week)-\(column)-\(range.start)-\(range.end)-\(identity)"
                        .unicodeScalars.map { $0.value < 128 ? String($0) : String(format: "%02X", $0.value) }.joined()
                    lines.append("BEGIN:VEVENT")
                    lines.append("UID:\(escape(uid))@naptable")
                    lines.append("DTSTAMP:\(format(Date.now, zone: TimeZone(identifier: "UTC")!))Z")
                    lines.append("DTSTART;TZID=\(zone.identifier):\(format(start, zone: zone))")
                    lines.append("DTEND;TZID=\(zone.identifier):\(format(end, zone: zone))")
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

    private static func parseDate(_ value: String, zone: TimeZone) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func date(day: Date, time: String, zone: TimeZone) -> Date? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = parts[0]
        components.minute = parts[1]
        components.second = 0
        return calendar.date(from: components)
    }

    private static func format(_ value: Date, zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
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
