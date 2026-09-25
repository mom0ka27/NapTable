#if os(iOS) || LIVE_SERVICE_CHECKS
import ActivityKit
import Combine
import CryptoKit
import Foundation
import Security

/// Keeps the server's copy of the timetable current and hands the phone's side
/// of each reminder over: iOS 26 reserves the nearest few the server hands out,
/// and token-mode activities report their push tokens. Serialized, so a late
/// registration response never loses the credentials a revocation needs.
@available(iOS 17.2, *)
@MainActor
final class LiveActivityPushService: ObservableObject {
    enum Status: Equatable {
        case off, waitingForToken
        case ready(pending: Int, nextFireAt: Date?)
        case failed(String)
        var title: String {
            switch self {
            case .off: return "已关闭"
            case .waitingForToken: return "等待推送令牌"
            case .ready(let pending, _): return "已连接，\(pending) 节课等待服务端提醒"
            case .failed: return "同步失败"
            }
        }
        var detail: String? { if case .failed(let text) = self { return text }; return nil }
    }
    static let shared = LiveActivityPushService()
    private static let deviceKey = "naptable.liveActivity.deviceID"
    private static let legacySecretKey = "naptable.liveActivity.deviceSecret"
    private static let revokeKey = "naptable.liveActivity.pendingRevocation"
    private static let registrationKey = "naptable.liveActivity.v2.registered"
    /// The timetable's revision and the digest of the body it names.
    private static let revisionKey = "naptable.liveActivity.v2.timetableRevision"
    private static let digestKey = "naptable.liveActivity.v2.timetableDigest"
    /// Keys the client-built plan used; cleared once.
    private static let retiredKeys = ["naptable.liveActivity.v2.handoff", "naptable.liveActivity.v2.handoff.history", "naptable.liveActivity.v2.plan",
                                      "naptable.liveActivity.v2.cancelPlan", "naptable.liveActivity.v2.mapping.sandbox", "naptable.liveActivity.v2.mapping.production"]
    /// occurrenceId → token last accepted by the server.
    private static let activityLedgerKey = "naptable.liveActivity.v2.activityTokens"
    private static let keychainService = "naptable.liveActivity.device"
    @Published private(set) var status: Status = .off
    struct CredentialStore {
        var read: (String) -> String?
        var write: (String, String) throws -> Void
        var remove: (String) -> Void
    }
    private let defaults: UserDefaults
    private let owner: NativeLiveActivityController
    private let credentials: CredentialStore?
    private let baseURL: URL?
    private let transport: ((URLRequest) async throws -> (Data, HTTPURLResponse))?
    init(controller: NativeLiveActivityController? = nil, defaults: UserDefaults = .standard,
         credentials: CredentialStore? = nil, baseURL: URL? = nil,
         transport: ((URLRequest) async throws -> (Data, HTTPURLResponse))? = nil) {
        self.owner = controller ?? .shared
        self.defaults = defaults
        self.credentials = credentials
        self.baseURL = baseURL
        self.transport = transport
    }
    private var worker: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var tokenTask: Task<Void, Never>?
    private var activityTask: Task<Void, Never>?
    private var dirty = false
    private var generation = 0
    private var token: String?
    private var uploadedToken: String?
    /// The timetable digest the server accepted in this process: uploaded once per launch at least.
    private var uploadedDigest: String?
    private var controller: NativeLiveActivityController { owner }
    private var group: UserDefaults { UserDefaults(suiteName: NextWidgetConfiguration.appGroup) ?? defaults }
    var deviceID: String? { defaults.string(forKey: Self.deviceKey) }
    var isEnabled: Bool { controller.isEnabled }
    static let environment: String = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .isoLatin1),
              let range = text.range(of: "<key>aps-environment</key>") else {
            #if DEBUG
            return "sandbox"
            #else
            return "production"
            #endif
        }
        return text[range.upperBound...].prefix(200).contains("development") ? "sandbox" : "production"
    }()

    private func secret(_ id: String) -> String? {
        if let credentials { return credentials.read(id) ?? defaults.string(forKey: Self.legacySecretKey) }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: id, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data { return String(data: data, encoding: .utf8) }
        return defaults.string(forKey: Self.legacySecretKey)
    }
    private func saveSecret(_ secret: String, id: String) throws {
        if let credentials { try credentials.write(id, secret); defaults.removeObject(forKey: Self.legacySecretKey); return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.keychainService, kSecAttrAccount as String: id]
        let attributes: [String: Any] = [kSecValueData as String: Data(secret.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        let result = update == errSecItemNotFound ? SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) : update
        guard result == errSecSuccess else { throw ScheduleServiceError.server("设备凭据无法保存到钥匙串") }
        defaults.removeObject(forKey: Self.legacySecretKey)
    }
    func activate() {
        controller.planDidChange = { [weak self] in self?.enqueue() }
        controller.activityTokensDidChange = { [weak self] in self?.enqueue() }
        for key in Self.retiredKeys { defaults.removeObject(forKey: key) }
        guard isEnabled else { enqueue(); return }
        if #available(iOS 18.0, *) {
            observeToken()
            observeActivities()
            enqueue()
        } else {
            // Explicitly retire iOS 17.2's former remote capability.
            if deviceID != nil { revoke() }
            controller.setServiceFailure("自动提醒需要 iOS 18 或更新版本；iOS 17 仍可预览效果。")
        }
    }
    private func observeToken() {
        guard tokenTask == nil else { return }
        tokenTask = Task { [weak self] in
            for await data in Activity<ScheduleLiveActivityAttributes>.pushToStartTokenUpdates {
                guard let self else { return }
                token = data.map { String(format: "%02x", $0) }.joined()
                enqueue()
            }
        }
    }
    /// A remote start (or a reservation starting) wakes the app briefly; a
    /// token-mode activity needs its token uploaded before the app is suspended again.
    private func observeActivities() {
        guard activityTask == nil else { return }
        activityTask = Task { [weak self] in
            for await activity in Activity<ScheduleLiveActivityAttributes>.activityUpdates {
                guard let self else { return }
                controller.observeTokens(of: activity)
            }
        }
    }
    func enabledDidChange(_ enabled: Bool) {
        if enabled { activate() } else { revoke() }
    }
    func revoke() {
        defaults.set(true, forKey: Self.revokeKey)
        generation += 1
        dirty = true
        enqueue()
    }
    func refreshStatus() async { enqueue(); await worker?.value }
    private func enqueue() {
        dirty = true
        generation += 1
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while dirty {
                dirty = false
                let captured = generation
                do { try await synchronize(generation: captured) }
                catch {
                    guard captured == generation else { continue }
                    let message = Self.userMessage(for: error)
                    status = .failed(message)
                    controller.setServiceFailure(message)
                    scheduleRetry()
                }
            }
            worker = nil
        }
    }
    /// What the settings page shows for a failed sync. The server's own
    /// Chinese messages are meant for the reader; raw protocol errors
    /// (「not found」, 「HTTP 500」) are not.
    static func userMessage(for error: Error) -> String {
        if error is URLError { return "网络连接不可用，恢复后会自动重试。" }
        if case ScheduleServiceError.server(let reason) = error,
           reason.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) { return reason }
        return "提醒服务暂时不可用，稍后会自动重试。"
    }
    private func scheduleRetry() {
        guard retryTask == nil, isEnabled || defaults.bool(forKey: Self.revokeKey) else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !Task.isCancelled else { return }
            retryTask = nil
            enqueue()
        }
    }
    private func current(_ captured: Int, scope: String) -> Bool {
        captured == generation && isEnabled && !defaults.bool(forKey: Self.revokeKey) && controller.currentScheduleMetadata?.scheduleScope == scope
    }
    private func synchronize(generation captured: Int) async throws {
        if defaults.bool(forKey: Self.revokeKey) || !isEnabled {
            try await forget()
            if !isEnabled { status = .off; return }
        }
        guard #available(iOS 18.0, *), let snapshot = controller.currentScheduleMetadata, let scope = snapshot.scheduleScope else { return }
        guard let timetable = controller.timetable() else {
            status = .failed("课表缺少学期信息，无法安排提醒。")
            controller.setServiceFailure("课表缺少学期信息，无法安排提醒。")
            return
        }
        if deviceID == nil { defaults.set(UUID().uuidString, forKey: Self.deviceKey) }
        guard let device = deviceID else { return }
        if let existingSecret = secret(device) { try saveSecret(existingSecret, id: device) }
        else {
            // A lost first registration response must remain recoverable.
            try saveSecret(UUID().uuidString + UUID().uuidString, id: device)
        }
        if !defaults.bool(forKey: Self.registrationKey) || token != uploadedToken {
            let registrationToken = token
            var body: [String: Any] = ["deviceID": device, "installationId": device, "environment": Self.environment, "bundleID": Bundle.main.bundleIdentifier ?? ""]
            if let registrationToken { body["startToken"] = registrationToken }
            let response = try await request("/devices", method: "POST", body: body)
            // Always retain late registration credentials, even after disable/scope change.
            if let secret = response["secret"] as? String { try saveSecret(secret, id: device) }
            defaults.set(true, forKey: Self.registrationKey)
            uploadedToken = registrationToken
            guard current(captured, scope: scope) else { dirty = true; return }
        }
        let pending = try await upload(timetable, device: device)
        guard current(captured, scope: scope) else { dirty = true; return }
        if #available(iOS 26.0, *) {
            try await claim(device: device)
            guard current(captured, scope: scope) else { dirty = true; return }
        }
        await synchronizeActivities(device: device)
        guard current(captured, scope: scope) else { dirty = true; return }
        status = token == nil ? .waitingForToken : .ready(pending: pending ?? 0, nextFireAt: nil)
    }
    /// PUTs the timetable when it changed, or once per launch. A new body gets
    /// the next revision, saved before the request, so a retry after a lost
    /// response repeats exactly the same revision and body. Returns the
    /// server's pending count, or nil when nothing was sent.
    private func upload(_ timetable: [String: Any], device: String) async throws -> Int? {
        let digest = SHA256.hash(data: try JSONSerialization.data(withJSONObject: timetable, options: [.sortedKeys])).map { String(format: "%02x", $0) }.joined()
        guard digest != uploadedDigest else { return nil }
        if defaults.string(forKey: Self.digestKey) != digest {
            defaults.set(defaults.integer(forKey: Self.revisionKey) + 1, forKey: Self.revisionKey)
            defaults.set(digest, forKey: Self.digestKey)
        }
        var (code, response) = try await send("/devices/\(device)/timetable", method: "PUT", body: timetable.merging(["revision": defaults.integer(forKey: Self.revisionKey)]) { _, new in new })
        if code == 409 {
            // The server holds a newer revision (settings restored from a backup): continue after it.
            let status = try await request("/devices/\(device)", method: "GET")
            defaults.set((status["timetableRevision"] as? Int ?? 0) + 1, forKey: Self.revisionKey)
            (code, response) = try await send("/devices/\(device)/timetable", method: "PUT", body: timetable.merging(["revision": defaults.integer(forKey: Self.revisionKey)]) { _, new in new })
        }
        if code == 404, timetable["follow"] != nil { throw ScheduleServiceError.server("关注的共享课表已失效，请重新关注。") }
        guard (200..<300).contains(code) else { throw ScheduleServiceError.server(response["error"] as? String ?? "HTTP \(code)") }
        uploadedDigest = digest
        return response["pendingCount"] as? Int
    }
    /// iOS 26: claims as many of the nearest reminders as there are free
    /// reservation slots, reserves them, and gives back what could not be reserved.
    @available(iOS 26.0, *)
    private func claim(device: String) async throws {
        let slots = max(0, NativeLiveActivityController.reservationSlots - controller.reservationCount)
        let response = try await request("/devices/\(device)/claims", method: "POST", body: ["slots": slots])
        let claims = try JSONDecoder().decode([LiveActivityClaim].self, from: JSONSerialization.data(withJSONObject: response["claims"] as? [Any] ?? []))
        for id in await controller.reserve(claims) {
            // Best effort: one not given back is still reserved nowhere, so retry it next pass.
            let (code, _) = try await send("/devices/\(device)/claims/\(id)", method: "DELETE")
            guard (200..<300).contains(code) else { throw ScheduleServiceError.server("HTTP \(code)") }
        }
    }
    /// Token mode: PUT each activity's token once the server has not seen it,
    /// DELETE the ones that are gone. A failure retries with the rest of the service.
    private func synchronizeActivities(device: String) async {
        var uploaded = group.dictionary(forKey: Self.activityLedgerKey) as? [String: String] ?? [:]
        let (registrations, live) = controller.tokenRegistrations()
        guard !registrations.isEmpty || !uploaded.isEmpty else { return }
        do {
            for registration in registrations where uploaded[registration.occurrenceId] != registration.token {
                let (code, response) = try await send("/devices/\(device)/activities/\(registration.occurrenceId)", method: "PUT", body: ["token": registration.token])
                // 404: the server no longer schedules it (finished, or moved away); nothing to refresh.
                guard (200..<300).contains(code) || code == 404 else { throw ScheduleServiceError.server(response["error"] as? String ?? "HTTP \(code)") }
                uploaded[registration.occurrenceId] = registration.token
                group.set(uploaded, forKey: Self.activityLedgerKey)
            }
            for id in uploaded.keys.sorted() where !live.contains(id) {
                // Best effort: the server stops at the activity's end anyway.
                _ = try? await send("/devices/\(device)/activities/\(id)", method: "DELETE")
                uploaded[id] = nil
                group.set(uploaded, forKey: Self.activityLedgerKey)
            }
        } catch { scheduleRetry() }
    }
    private func forget() async throws {
        guard let device = deviceID else { defaults.removeObject(forKey: Self.revokeKey); return }
        if secret(device) != nil {
            _ = try await request("/devices/\(device)", method: "DELETE", legacy: !defaults.bool(forKey: Self.registrationKey))
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.keychainService, kSecAttrAccount as String: device]
            if let credentials { credentials.remove(device) } else { SecItemDelete(query as CFDictionary) }
        }
        for key in [Self.deviceKey, Self.legacySecretKey, Self.registrationKey, Self.revokeKey, Self.revisionKey, Self.digestKey] { defaults.removeObject(forKey: key) }
        group.removeObject(forKey: Self.activityLedgerKey)
        uploadedToken = nil
        uploadedDigest = nil
    }
    private func request(_ path: String, method: String, body: [String: Any]? = nil, legacy: Bool = false) async throws -> [String: Any] {
        let (code, value) = try await send(path, method: method, body: body, legacy: legacy)
        // Never discard credentials after a transient/auth error: pending revoke needs them.
        guard (200..<300).contains(code) else { throw ScheduleServiceError.server(value["error"] as? String ?? "HTTP \(code)") }
        return value
    }
    private func send(_ path: String, method: String, body: [String: Any]? = nil, legacy: Bool = false) async throws -> (Int, [String: Any]) {
        guard let base = baseURL ?? ScheduleSharingService.shared.validatedBaseURL,
              let url = URL(string: (legacy ? "/v1" : "/v2") + "/live-activity" + path, relativeTo: base) else { throw ScheduleServiceError.missingBaseURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let device = deviceID, let secret = secret(device) { request.setValue(secret, forHTTPHeaderField: "X-Device-Secret") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) }
        let data: Data
        let response: URLResponse
        if let transport { (data, response) = try await transport(request) }
        else { (data, response) = try await URLSession.shared.data(for: request) }
        guard let http = response as? HTTPURLResponse else { throw ScheduleServiceError.invalidResponse }
        let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (http.statusCode, value)
    }
}
#endif
