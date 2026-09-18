import Foundation

@main
struct SchoolTemplateResolverChecks {
    @MainActor static func main() throws {
        func term(_ id: String, _ start: String, _ time: String = "08:00") -> ServiceTermConfiguration {
            ServiceTermConfiguration(id: id, version: 3, semesterStartMonday: start, weekCount: 18,
                periods: [ServiceClassPeriod(id: 1, name: "第1节", start: time, end: "09:00")],
                timezone: "Asia/Shanghai", note: "")
        }
        let fall = term("2026-fall", "2026-09-14")
        let spring = term("2027-spring", "2027-02-22", "08:15")
        let schools = [ServiceSchoolConfiguration(id: "nju", name: "南京大学", timezone: "Asia/Shanghai",
            terms: [fall, spring, term("2026-fall-template", "2026-09-14")], note: "")]
        func resolve(_ name: String, _ id: String = "nju", at date: String = "2026-09-16") throws -> ImportedSchedule {
            try SchoolTemplateResolver.applying(to: ImportedSchedule(name: name, courses: []),
                schoolID: id, schools: schools, now: WeekCalculator.parseDay(date)!)
        }
        let result = try resolve("2026-2027学年 第1学期")
        precondition(result.termID == "2026-fall" && result.termVersion == 3)
        precondition(result.semesterStartMonday == "2026-09-14" && result.termWeekCount == 18)
        precondition(result.classTimeList?.first?.start == "08:00")
        let next = try resolve("2026-2027学年 第2学期")
        precondition(next.termID == "2027-spring" && next.classTimeList?.first?.start == "08:15")
        let coded = try resolve("2026-2027-2")
        precondition(coded.termID == "2027-spring")
        let active = try resolve("我的课表")
        precondition(active.termID == "2026-fall")
        let upcoming = try resolve("我的课表", at: "2026-08-01")
        precondition(upcoming.termID == "2026-fall")
        do { _ = try resolve("2025-2026学年 第1学期"); fatalError("Historical term must not use current template") }
        catch is ScheduleServiceError {}
        do { _ = try resolve("我的课表", "other"); fatalError("Must not substitute NJU for another school") }
        catch is ScheduleServiceError {}
        var duplicate = schools
        duplicate[0].terms.append(term("2026-fall-other", "2026-09-14"))
        do {
            _ = try SchoolTemplateResolver.applying(to: ImportedSchedule(name: "2026年秋季", courses: []),
                schoolID: "nju", schools: duplicate)
            fatalError("Ambiguous school term must not be chosen arbitrarily")
        } catch is ScheduleServiceError {}
        print("PASS: academic-year matching, active/upcoming selection, template priority, authoritative fields, missing school/term and ambiguity")
    }
}
