import Foundation

@main
struct OnboardingChecks {
    @MainActor static func main() async throws {
        try await checkUsageIdentity()
        let suite = "naptable.privacy.tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let consent = PrivacyConsent(defaults: preferences)
        precondition(!consent.basicAccepted && !consent.liveAccepted && !consent.onboardingCompleted)
        consent.setLiveConsent(true)
        precondition(!consent.liveAccepted, "Optional consent cannot bypass basic consent")
        consent.completeOnboarding(hasImportedCourses: true)
        precondition(!consent.onboardingCompleted, "Import alone cannot bypass privacy")
        var reports: [URLRequest] = []
        var offline = false
        var identity: UsageIdentity?
        let identityStorage = UsageIdentity.Storage(read: { identity }, insert: { identity = $0 })
        let reporter = UsageReportingService(defaults: preferences, identityStorage: identityStorage) { request in
            reports.append(request)
            if offline { throw URLError(.notConnectedToInternet) }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let base = URL(string: "https://example.invalid")!
        await reporter.report(schoolID: "nju", baseURL: base)
        precondition(reports.isEmpty && identity == nil && preferences.string(forKey: "naptable.usage.installation") == nil,
                     "No usage report or installation ID before mandatory consent")
        consent.acceptBasic(liveActivities: false)
        precondition(consent.basicAccepted && !consent.liveAccepted)
        consent.completeOnboarding(hasImportedCourses: false)
        precondition(!consent.onboardingCompleted, "Empty or cancelled import cannot enter the app")
        await reporter.report(schoolID: "nju", baseURL: base)
        await reporter.report(schoolID: "nju", baseURL: base)
        precondition(reports.count == 1, "Repeated foreground reports are throttled")
        let installationURL = reports[0].url
        let credential = reports[0].value(forHTTPHeaderField: "X-Device-Secret")
        let payload = try JSONSerialization.jsonObject(with: reports[0].httpBody!) as! [String: Any]
        precondition(Set(payload.keys) == Set(["schoolID", "systemName", "systemVersion", "deviceModel", "appVersion", "consentVersion"]))
        precondition(payload["schoolID"] as? String == "nju")
        precondition(!consent.liveAccepted, "Usage statistics work without notification consent")
        let midnight = Date(timeIntervalSince1970: 1_790_870_400) // 2026-10-02 00:00 UTC+8
        precondition(UsageReportingService.usageDay(midnight) == UsageReportingService.usageDay(midnight.addingTimeInterval(86_399)))
        precondition(UsageReportingService.usageDay(midnight.addingTimeInterval(-1)) + 1 == UsageReportingService.usageDay(midnight),
                     "Usage days roll over at 00:00 UTC+8, not UTC")
        offline = true
        await reporter.report(schoolID: nil, baseURL: base)
        offline = false
        await reporter.report(schoolID: nil, baseURL: base)
        precondition(reports.count == 3, "Failed uploads retry without marking success")
        precondition(reports.allSatisfy { $0.url == installationURL && $0.value(forHTTPHeaderField: "X-Device-Secret") == credential })
        await reporter.report(schoolID: "nju", baseURL: URL(string: "http://example.invalid"))
        precondition(reports.count == 3, "Device statistics require HTTPS")
        consent.completeOnboarding(hasImportedCourses: true)
        consent.setLiveConsent(true)
        let restored = PrivacyConsent(defaults: preferences)
        precondition(restored.basicAccepted && restored.liveAccepted && restored.onboardingCompleted)
        restored.setLiveConsent(false)
        precondition(!PrivacyPolicy.liveAllowed(preferences) && PrivacyPolicy.basicAllowed(preferences))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AppStore(fileURL: url)
        precondition(store.tables.isEmpty && store.courses.isEmpty)
        store.saveNow()
        precondition(AppStore(fileURL: url).tables.isEmpty)
        let table = store.addTable(name: " 我的学期 ", semesterStartMonday: "2026-09-14")
        precondition(store.selectedTable?.name == "我的学期")
        store.deleteTable(table.id)
        precondition(store.tables.isEmpty && store.selectedTable == nil)
        store.restore(store.exportDocument())
        precondition(store.tables.isEmpty)
        let source = AppStore(fileURL: nil)
        source.addTable(name: "恢复的课表")
        store.restore(source.exportDocument())
        precondition(store.selectedTable?.name == "恢复的课表")
        precondition(store.selectedTableId == store.tables.first?.id)
        store.eraseEverything()
        store.saveNow()
        precondition(AppStore(fileURL: url).tables.isEmpty)

        // 示例导入也能完成引导，且重启后仍保留独立学期和自由时间课程。
        preferences.removeObject(forKey: PrivacyPolicy.onboardingKey)
        let demoConsent = PrivacyConsent(defaults: preferences)
        precondition(!demoConsent.onboardingCompleted)
        let demoAdapter = NativeScheduleStore()
        demoAdapter.connect(store)
        let referenceDate = Date()
        let demoTable = store.installDemoSchedule(referenceDate: referenceDate)
        // 批量导入的更新合并后，界面仍应自动拿到最终课表和自由时间课程。
        for _ in 0..<50 {
            if demoAdapter.selectedSemester == String(demoTable.id), !demoAdapter.freeCourses.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(demoAdapter.selectedSemester == String(demoTable.id) && demoAdapter.selectedWeek == "1")
        precondition(!demoAdapter.freeCourses.isEmpty)
        precondition(store.selectedTableId == demoTable.id && store.displayWeek == 1)
        precondition(demoTable.semesterStartMonday == WeekCalculator.format(WeekCalculator.monday(of: referenceDate))
                     && store.maxWeeks == DemoSchedule.weekCount)
        precondition(demoTable.schoolID == nil && demoTable.termID == nil)
        precondition(demoTable.unifiedHolidaysEnabled == false, "Holidays must not hide the demo")
        let demoCourses = store.currentCourses
        let odd = demoCourses.first { WeekSeries.detectKind($0.weeks) == .single }!
        let even = demoCourses.first { WeekSeries.detectKind($0.weeks) == .double }!
        precondition(odd.weekTime == even.weekTime && odd.startTime == even.startTime)
        for week in 1...DemoSchedule.weekCount {
            let logic = ScheduleLogic(courses: demoCourses, nowWeek: week)
            let visible = Set(logic.visibleCourses.map(\.id))
            precondition(visible.contains(odd.id) == (week % 2 == 1))
            precondition(visible.contains(even.id) == (week % 2 == 0))
            precondition(!logic.freeCourses.isEmpty && logic.freeCourses.allSatisfy { !visible.contains($0.id) })
        }
        let custom = demoCourses.first { !$0.isFreeTime && WeekSeries.detectKind($0.weeks) == .custom }!
        precondition(ScheduleLogic(courses: demoCourses, nowWeek: custom.weeks[0]).visibleCourses.contains { $0.id == custom.id })
        let offWeek = (1...DemoSchedule.weekCount).first { !custom.weeks.contains($0) }!
        precondition(!ScheduleLogic(courses: demoCourses, nowWeek: offWeek).visibleCourses.contains { $0.id == custom.id })
        store.saveNow()
        demoConsent.completeOnboarding(hasImportedCourses: !store.currentCourses.isEmpty)
        let persistedDemo = AppStore(fileURL: url)
        precondition(PrivacyConsent(defaults: preferences).onboardingCompleted)
        precondition(persistedDemo.selectedTable == demoTable && persistedDemo.currentCourses == demoCourses)
        let secondDemo = store.installDemoSchedule(referenceDate: referenceDate)
        precondition(secondDemo.id != demoTable.id && secondDemo.name != demoTable.name)
        precondition(store.courses.filter { $0.tableId == demoTable.id } == demoCourses,
                     "Importing another demo must preserve existing courses")

        // 读不到（这里用同名目录模拟）：不动原文件、不写盘。
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let unreadable = folder.appendingPathComponent("state.json")
        try! FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: false)
        let blocked = AppStore(fileURL: unreadable)
        precondition(blocked.loadErrorMessage != nil)
        blocked.addTable(name: "不该写进去")
        blocked.saveNow()
        var isDirectory: ObjCBool = false
        precondition(FileManager.default.fileExists(atPath: unreadable.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        precondition(try! FileManager.default.contentsOfDirectory(atPath: folder.path) == ["state.json"])
        try! FileManager.default.removeItem(at: unreadable)

        // 解不开：挪成带时间戳的备份，第二次损坏不会覆盖第一份备份。
        try! Data("not json".utf8).write(to: unreadable)
        _ = AppStore(fileURL: unreadable)
        try! Data("still not json".utf8).write(to: unreadable)
        let reset = AppStore(fileURL: unreadable)
        precondition(reset.loadErrorMessage?.contains("corrupt-") == true)
        let backups = try! FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.contains(".corrupt-") }
        precondition(backups.count == 2, "\(backups)")
        print("PASS: privacy consent, upload gating, payload minimization, dedup/retry, onboarding import gate, fresh launch, empty persistence, explicit creation, last-table deletion, empty backup, restore selection, erase, demo import/persistence/odd-even/custom/free courses, unreadable state kept, timestamped corrupt backups")
    }
}
