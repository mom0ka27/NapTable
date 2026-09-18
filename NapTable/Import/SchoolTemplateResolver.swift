import Foundation

/// Resolves an imported university timetable without asking the user to sync a
/// template. Explicit academic-year information wins over today's date.
@MainActor
enum SchoolTemplateResolver {
    static func applying(
        to schedule: ImportedSchedule, schoolID: String,
        schools: [ServiceSchoolConfiguration], now: Date = Date()
    ) throws -> ImportedSchedule {
        guard let school = schools.first(where: { $0.id == schoolID }) else {
            throw ScheduleServiceError.server("服务端尚未配置学校 \(schoolID)")
        }
        var candidates = school.terms.filter {
            WeekCalculator.parseDay($0.semesterStartMonday) != nil && !$0.periods.isEmpty
        }
        if let explicit = schedule.termID, !explicit.isEmpty {
            candidates = candidates.filter { $0.id == explicit }
        } else if let academic = academicTerm(in: schedule.name) {
            candidates = candidates.filter { term in
                guard let date = WeekCalculator.parseDay(term.semesterStartMonday) else { return false }
                let year = WeekCalculator.calendar.component(.year, from: date)
                let month = WeekCalculator.calendar.component(.month, from: date)
                return year == academic.year && (academic.fall ? month >= 7 : month < 7)
            }
        } else {
            let active = candidates.filter { term in
                guard let start = WeekCalculator.parseDay(term.semesterStartMonday),
                      let end = WeekCalculator.calendar.date(byAdding: .day, value: term.weekCount * 7, to: start) else { return false }
                return start <= now && now < end
            }
            if !active.isEmpty { candidates = active }
            else {
                // Before a semester starts, choose only the nearest upcoming
                // date, never an arbitrary old term from the catalogue.
                let future = candidates.filter { $0.semesterStartMonday > WeekCalculator.format(now) }
                if let first = future.map(\.semesterStartMonday).min() {
                    candidates = future.filter { $0.semesterStartMonday == first }
                } else { candidates = [] }
            }
        }
        let calibrated = candidates.filter { !$0.id.hasSuffix("-template") }
        if !calibrated.isEmpty { candidates = calibrated }
        guard candidates.count == 1, let term = candidates.first else {
            throw ScheduleServiceError.server(candidates.isEmpty
                ? "\(school.name)尚无与该课表对应的学期，请管理员补充配置"
                : "\(school.name)有多个匹配学期，请管理员检查学期配置")
        }
        var result = schedule
        result.schoolID = school.id
        result.termID = term.id
        result.termVersion = term.version
        result.termWeekCount = term.weekCount
        result.termTimezone = term.timezone
        result.semesterStartMonday = term.semesterStartMonday
        result.classTimeList = term.classTimes
        result.calendarAdjustments = term.calendarAdjustments
        return result
    }

    private static func academicTerm(in name: String) -> (year: Int, fall: Bool)? {
        let normalized = name.replacingOccurrences(of: "—", with: "-").replacingOccurrences(of: "–", with: "-")
        guard let yearRange = normalized.range(of: #"20\d{2}"#, options: .regularExpression),
              let firstYear = Int(normalized[yearRange]) else { return nil }
        let fall = normalized.contains("秋") || normalized.range(of: #"第\s*[1一]\s*学期|20\d{2}\s*-\s*20\d{2}\s*-\s*1(?:\D|$)"#, options: .regularExpression) != nil
        let spring = normalized.contains("春") || normalized.range(of: #"第\s*[2二]\s*学期|20\d{2}\s*-\s*20\d{2}\s*-\s*2(?:\D|$)"#, options: .regularExpression) != nil
        guard fall || spring else { return nil }
        let spansYears = normalized.range(of: #"20\d{2}\s*-\s*20\d{2}"#, options: .regularExpression) != nil
        return (firstYear + (spring && spansYears ? 1 : 0), fall)
    }
}
