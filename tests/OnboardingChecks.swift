import Foundation

@main
struct OnboardingChecks {
    @MainActor static func main() async throws {
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
        let reporter = UsageReportingService(defaults: preferences) { request in
            reports.append(request)
            if offline { throw URLError(.notConnectedToInternet) }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let base = URL(string: "https://example.invalid")!
        await reporter.report(schoolID: "nju", baseURL: base)
        precondition(reports.isEmpty && preferences.string(forKey: "naptable.usage.installation") == nil,
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
        print("PASS: privacy consent, upload gating, payload minimization, dedup/retry, onboarding import gate, fresh launch, empty persistence, explicit creation, last-table deletion, empty backup, restore selection, erase, unreadable state kept, timestamped corrupt backups")
    }
}
