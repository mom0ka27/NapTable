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
        var mismatch: String?
        var candidates = school.terms.filter {
            WeekCalculator.parseDay($0.semesterStartMonday) != nil && !$0.periods.isEmpty
        }
        // 页面上的学年学期（`schedule.name` 由提取脚本从课表页读出）优先：
        // 学生现在能看到的那张课表属于哪个学期，只有页面说得准，用当前学期会把
        // 暑假里提前导入的课表落到上一个学期上。
        if let explicit = schedule.termID, !explicit.isEmpty {
            candidates = candidates.filter { $0.id == explicit }
        } else if let academic = academicTerm(in: schedule.name),
                  case let matched = terms(candidates, in: academic), !matched.isEmpty {
            // 对得上的有多个时，下面照常优先校准过的学期、仍有歧义就报错。
            candidates = matched
        } else if let currentTermID = school.currentTermID {
            candidates = candidates.filter { $0.id == currentTermID }
            // 页面写了学年学期却对不上任何已配置的学期：多半是教务系统还停在上学期。
            // 照样套用当前学期，但让用户在导入前确认。
            if academicTerm(in: schedule.name) != nil { mismatch = schedule.name }
        } else if academicTerm(in: schedule.name) != nil {
            // 页面写了学年学期却一个都对不上、服务端也没标当前学期：不拿今天去猜。
            candidates = []
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
        result.unifiedHolidaysEnabled = school.unifiedHolidaysEnabled ?? true
        result.unifiedMakeupEnabled = school.unifiedMakeupEnabled ?? true
        result.semesterStartMonday = term.semesterStartMonday
        result.classTimeList = term.classTimes
        result.seasonalPeriods = term.seasonalPeriods ?? school.seasonalPeriods ?? SeasonalClassTimes.defaults(for: school.id)
        result.calendarAdjustments = term.calendarAdjustments
        result.termMismatch = mismatch.map {
            "页面显示的是「\($0.trimmingCharacters(in: .whitespacesAndNewlines))」，和当前学期（\(semesterName(startMonday: term.semesterStartMonday, hint: ""))）不一致"
        }
        return result
    }

    private static func terms(
        _ candidates: [ServiceTermConfiguration], in academic: (year: Int, fall: Bool)
    ) -> [ServiceTermConfiguration] {
        candidates.filter { term in
            guard let date = WeekCalculator.parseDay(term.semesterStartMonday) else { return false }
            let year = WeekCalculator.calendar.component(.year, from: date)
            let month = WeekCalculator.calendar.component(.month, from: date)
            return year == academic.year && (academic.fall ? month >= 7 : month < 7)
        }
    }

    /// 导入课表的默认名，如「2026 秋」。优先按学期第一周的年月算（7 月起算秋季，
    /// 和上面按学年挑学期的口径一致），没有就看页面上的学年学期，再没有就按今天。
    static func semesterName(startMonday: String?, hint: String, now: Date = Date()) -> String {
        let year: Int, fall: Bool
        if let start = startMonday.flatMap(WeekCalculator.parseDay) {
            year = WeekCalculator.calendar.component(.year, from: start)
            fall = WeekCalculator.calendar.component(.month, from: start) >= 7
        } else if let academic = academicTerm(in: hint) {
            (year, fall) = academic
        } else {
            year = WeekCalculator.calendar.component(.year, from: now)
            fall = WeekCalculator.calendar.component(.month, from: now) >= 7
        }
        return "\(year) \(fall ? "秋" : "春")"
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
