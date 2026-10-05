import Foundation

@MainActor func checkUsageIdentity() async throws {
    let suite = "naptable.usage.tests." + UUID().uuidString
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    var saved: UsageIdentity?
    var readFails = false, writeFails = false
    var writes = 0
    let storage = UsageIdentity.Storage(read: {
        if readFails { throw URLError(.cannotOpenFile) }
        return saved
    }, insert: {
        writes += 1
        if writeFails { throw URLError(.cannotWriteToFile) }
        saved = $0
    })
    var reports: [URLRequest] = []
    let transport: (URLRequest) async throws -> (Data, URLResponse) = { request in
        reports.append(request)
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let base = URL(string: "https://example.invalid")!
    let legacy = UsageIdentity(installationID: UUID().uuidString.lowercased(), secret: String(repeating: "a", count: 64))
    preferences.set(legacy.installationID, forKey: "naptable.usage.installation")
    preferences.set(legacy.secret, forKey: "naptable.usage.secret")
    PrivacyConsent(defaults: preferences).acceptBasic(liveActivities: false)
    let upgraded = UsageReportingService(defaults: preferences, identityStorage: storage, transport: transport)
    writeFails = true
    await upgraded.report(schoolID: "nju", baseURL: base)
    precondition(reports.isEmpty && saved == nil)
    precondition(preferences.string(forKey: "naptable.usage.secret") == legacy.secret,
                 "Failed migration must preserve both legacy credentials for retry")
    writeFails = false
    await upgraded.report(schoolID: "nju", baseURL: base)
    precondition(saved == legacy && reports.count == 1, "Upgrade must reuse the existing statistics row")
    precondition(preferences.string(forKey: "naptable.usage.installation") == nil
                 && preferences.string(forKey: "naptable.usage.secret") == nil)

    // Reinstall clears the app container, but the local keychain can survive.
    // Each new process must still wait for consent and reuse the same pair.
    for _ in 0..<13 {
        preferences.removePersistentDomain(forName: suite)
        let count = reports.count
        let installed = UsageReportingService(defaults: preferences, identityStorage: storage, transport: transport)
        await installed.report(schoolID: "nju", baseURL: base)
        precondition(reports.count == count, "Keychain persistence must not bypass renewed consent")
        PrivacyConsent(defaults: preferences).acceptBasic(liveActivities: false)
        await installed.report(schoolID: "nju", baseURL: base)
        precondition(reports.count == count + 1)
    }
    precondition(reports.allSatisfy {
        $0.url?.lastPathComponent == legacy.installationID && $0.value(forHTTPHeaderField: "X-Device-Secret") == legacy.secret
    }, "Thirteen reinstalls must still address the original row with its original secret")
    precondition(writes == 2, "Reading an existing identity must not replace it")

    let count = reports.count
    readFails = true
    let locked = UsageReportingService(defaults: preferences, identityStorage: storage, transport: transport)
    await locked.report(schoolID: "nju", baseURL: base)
    precondition(reports.count == count && writes == 2, "Locked keychain must not mint a new identity")
    readFails = false
    await locked.report(schoolID: "nju", baseURL: base)
    precondition(reports.count == count + 1 && saved == legacy, "Retry after unlock must retain identity")

    var other: UsageIdentity?
    let otherStorage = UsageIdentity.Storage(read: { other }, insert: { other = $0 })
    let newPhone = UsageReportingService(defaults: preferences, identityStorage: otherStorage, transport: transport)
    await newPhone.report(schoolID: "nju", baseURL: base)
    precondition(other != nil && other?.installationID != legacy.installationID && other?.secret != legacy.secret,
                 "A different phone without the device-only keychain must get its own identity")
    print("PASS: usage identity migration, failed persistence retry, 13 reinstalls, consent gating, locked keychain, distinct devices")
}
