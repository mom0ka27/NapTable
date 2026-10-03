import Foundation

private final class SchoolConfigurationStubProtocol: URLProtocol {
    static var responseBody = Data()
    static var offline = false
    static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path == "/v1/schools"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestCount += 1
        if Self.offline {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct SchoolTemplateResolverChecks {
    @MainActor static func main() async throws {
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
        var currentSchools = schools
        currentSchools[0].currentTermID = "2027-spring"
        let serverCurrent = try SchoolTemplateResolver.applying(
            to: ImportedSchedule(name: "我的课表", courses: []),
            schoolID: "nju", schools: currentSchools, now: WeekCalculator.parseDay("2026-09-16")!
        )
        precondition(serverCurrent.termID == "2027-spring" && serverCurrent.termMismatch == nil,
                     "A page without a term name uses the current term silently")
        // 页面上写明了学年学期、并且能对上某个学期时，它比服务端的当前学期优先。
        let pageWins = try SchoolTemplateResolver.applying(
            to: ImportedSchedule(name: "2026-2027学年 第1学期", courses: []),
            schoolID: "nju", schools: currentSchools, now: WeekCalculator.parseDay("2026-09-16")!
        )
        precondition(pageWins.termID == "2026-fall" && pageWins.termMismatch == nil)
        // 对不上任何学期时退回服务端的当前学期，但要标出来让用户确认。
        let fallback = try SchoolTemplateResolver.applying(
            to: ImportedSchedule(name: "2025-2026学年 第1学期", courses: []),
            schoolID: "nju", schools: currentSchools, now: WeekCalculator.parseDay("2026-09-16")!
        )
        precondition(fallback.termID == "2027-spring")
        precondition(fallback.termMismatch == "页面显示的是「2025-2026学年 第1学期」，和当前学期（2027 春）不一致",
                     fallback.termMismatch ?? "nil")
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
        let now = WeekCalculator.parseDay("2026-09-16")!
        precondition(SchoolTemplateResolver.semesterName(startMonday: "2026-09-14", hint: "", now: now) == "2026 秋")
        precondition(SchoolTemplateResolver.semesterName(startMonday: "2027-02-22", hint: "2026-2027学年 第1学期", now: now) == "2027 春")
        precondition(SchoolTemplateResolver.semesterName(startMonday: nil, hint: "2025-2026学年第二学期", now: now) == "2026 春")
        precondition(SchoolTemplateResolver.semesterName(startMonday: nil, hint: "我的课表", now: now) == "2026 秋")
        try await checkServerSchoolConfiguration(term: term("2026-fall", "2026-09-14", "08:10"))
        print("PASS: semester table names, server current term, page term over current term, academic-year matching, active/upcoming selection, template priority, authoritative fields, missing school/term and ambiguity")
    }

    @MainActor private static func checkServerSchoolConfiguration(term: ServiceTermConfiguration) async throws {
        precondition(URLProtocol.registerClass(SchoolConfigurationStubProtocol.self))
        let service = ScheduleSharingService.shared
        let defaults = UserDefaults.standard
        let cacheKey = "naptable.schoolsCache." + service.serverURLString
        let previousCache = defaults.data(forKey: cacheKey)
        defaults.removeObject(forKey: cacheKey)
        defer {
            defaults.set(previousCache, forKey: cacheKey)
            URLProtocol.unregisterClass(SchoolConfigurationStubProtocol.self)
        }
        let importableIDs = Set(SchoolCatalog.all.map(\.serviceSchoolID))
        precondition(importableIDs.contains("njtech"))
        precondition(importableIDs.contains("xjtu"))
        precondition(importableIDs.contains("ruc"))
        precondition(SchoolCatalog.all.filter { $0.serviceSchoolID == "ruc" }.count == 2)
        let rucUndergraduate = SchoolCatalog.all.first { $0.pinyin == "zhongguorenmindaxuebenkejiaowu" }!
        precondition(rucUndergraduate.serviceSchoolID == "ruc")
        precondition(rucUndergraduate.initialURL == RucLoginFlow.loginURL)
        precondition(rucUndergraduate.targetURL == RucLoginFlow.timetableURL)
        precondition(rucUndergraduate.postLoginURL == RucLoginFlow.timetableURL)
        precondition(rucUndergraduate.extractJS == SchoolCatalog.rucExtractJS)
        let xjtu = SchoolCatalog.all.first { $0.serviceSchoolID == "xjtu" }!
        precondition(xjtu.hasExtractor && xjtu.extractJS == SchoolCatalog.xjtuExtractJS)
        precondition(xjtu.initialURL == "https://ehall.xjtu.edu.cn/portal/html/select_role.html?appId=4770397878132218")
        let configured = (importableIDs.sorted() + ["cpu"]).map {
            ServiceSchoolConfiguration(id: $0, name: $0 == "njtech" ? "南京工业大学" : $0,
                timezone: "Asia/Shanghai", terms: [term], note: "")
        }
        SchoolConfigurationStubProtocol.responseBody = try JSONEncoder().encode(["schools": configured])
        let loaded = try await service.loadSchools()
        precondition(SchoolConfigurationStubProtocol.requestCount == 1)
        precondition(!service.usingCachedSchools)
        precondition(Set(loaded.map(\.id)) == importableIDs,
                     "Server configuration must retain every importable school, including njtech")
        let schedule = ImportedSchedule(name: "2026-2027学年第1学期", courses: [])
        let resolved = try SchoolTemplateResolver.applying(to: schedule, schoolID: "njtech", schools: loaded)
        precondition(resolved.schoolID == "njtech" && resolved.termID == term.id)
        precondition(resolved.classTimeList?.first?.start == "08:10")
        let xjtuSchedule = ImportedSchedule(name: "2026-2027-1", courses: [])
        let xjtuResolved = try SchoolTemplateResolver.applying(to: xjtuSchedule, schoolID: "xjtu", schools: loaded)
        precondition(xjtuResolved.schoolID == "xjtu" && xjtuResolved.termID == term.id)
        precondition(xjtuResolved.classTimeList?.first?.start == "08:10")

        SchoolConfigurationStubProtocol.offline = true
        let cached = try await service.loadSchools()
        precondition(SchoolConfigurationStubProtocol.requestCount == 2)
        precondition(service.usingCachedSchools && cached == loaded)
        let cachedSchedule = try SchoolTemplateResolver.applying(to: schedule, schoolID: "njtech", schools: cached)
        precondition(cachedSchedule.schoolID == "njtech" && cachedSchedule.termID == term.id)
        let cachedXjtu = try SchoolTemplateResolver.applying(to: xjtuSchedule, schoolID: "xjtu", schools: cached)
        precondition(cachedXjtu.schoolID == "xjtu" && cachedXjtu.termID == term.id)
        precondition(cachedXjtu.classTimeList == xjtuResolved.classTimeList)
        print("PASS: all importable schools survive server and offline-cache filtering; NJTECH and XJTU use their configured terms and class times")
    }
}
