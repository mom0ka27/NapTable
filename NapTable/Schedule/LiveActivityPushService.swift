#if os(iOS) || LIVE_SERVICE_CHECKS
import ActivityKit
import Combine
import CryptoKit
import Foundation
import Security

/// Serialized reconciliation preserves late registration credentials for revocation.
/// Server mode is authoritative; a token update can never switch local back to remote.
/// Only iOS 26 following a share asks for remote again, after retiring its reservations.
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
            case .ready(let pending, _): return "已连接，\(pending) 门课程等待远程启动"
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
    private static let handoffKey = "naptable.liveActivity.v2.handoff"
    private static let planKey = "naptable.liveActivity.v2.plan"
    /// occurrenceId → digest of the token-mode registration last accepted by the server.
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
    private var cachedMapping: LiveActivityMapping?
    private var cachedSchool: String?
    private var mappingFetchedAt = Date.distantPast
    private var serverHistory: Set<String> = []
    /// The server refused `alertAt`: refresh without reminders for this session.
    private var alertsUnsupported = false
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
        guard isEnabled else { enqueue(); return }
        if #available(iOS 18.0, *) {
            // iOS 26 needs the push-to-start token too: a followed share starts remotely.
            observeToken()
            observeActivities()
            enqueue()
        } else {
            // Explicitly retire iOS 17.2's former remote capability.
            if deviceID != nil { revoke() }
            controller.setServiceFailure("iOS 17 仅支持前台本地提醒；自动启动需要 iOS 18 或更新版本。")
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
    /// A remote start wakes the app briefly; a token-mode activity needs its own
    /// update token uploaded before the app is suspended again.
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
    func invalidatePlan() {
        defaults.set(true, forKey: "naptable.liveActivity.v2.cancelPlan")
        enqueue()
    }
    private func cancelPreviousPlanIfNeeded() async throws {
        guard var previous = defaults.data(forKey: Self.planKey).flatMap({ try? JSONDecoder().decode(LiveActivityPlan.self, from: $0) }),
              let device = deviceID, defaults.bool(forKey: Self.registrationKey), !defaults.bool(forKey: Self.handoffKey) else {
            defaults.removeObject(forKey: "naptable.liveActivity.v2.cancelPlan")
            return
        }
        let changedScope = previous.scheduleScope != controller.currentScheduleMetadata?.scheduleScope
        guard changedScope || defaults.bool(forKey: "naptable.liveActivity.v2.cancelPlan") else { return }
        if !previous.items.isEmpty || !previous.busyIntervals.isEmpty || previous.coverageStart < Date().timeIntervalSince1970 - 86400 || previous.coverageEndExclusive <= Date().timeIntervalSince1970 {
            previous.planRevision += 1
            previous.items = []
            previous.busyIntervals = []
            previous.coverageStart = floor(Date().timeIntervalSince1970 / 86400) * 86400
            previous.coverageEndExclusive = previous.coverageStart + 86400
            defaults.set(try JSONEncoder().encode(previous), forKey: Self.planKey)
        }
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(previous)) as! [String: Any]
        do { _ = try await request("/devices/\(device)/plan", method: "PUT", body: body) }
        catch {
            let original = error
            let status = try await request("/devices/\(device)", method: "GET")
            guard status["launchMode"] as? String == "local" else { throw original }
        }
        defaults.removeObject(forKey: "naptable.liveActivity.v2.cancelPlan")
    }
    func revoke() {
        defaults.set(true, forKey: Self.revokeKey)
        generation += 1
        dirty = true
        enqueue()
    }
    func refreshStatus() async { mappingFetchedAt = .distantPast; enqueue(); await worker?.value }
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
                    status = .failed(error.localizedDescription)
                    controller.setServiceFailure(error.localizedDescription)
                    scheduleRetry()
                }
            }
            worker = nil
        }
    }
    private func scheduleRetry() {
        guard retryTask == nil, isEnabled || defaults.bool(forKey: Self.revokeKey) else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !Task.isCancelled else { return }
            retryTask = nil
            mappingFetchedAt = .distantPast
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
        try await cancelPreviousPlanIfNeeded()
        guard #available(iOS 18.0, *), let snapshot = controller.currentScheduleMetadata,
              let scope = snapshot.scheduleScope, let school = snapshot.schoolID else {
            status = .failed("课表未关联服务端学校，自动实时活动不可用。")
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
        var local = false
        if #available(iOS 26.0, *), controller.pushMode == "token" {
            if defaults.bool(forKey: Self.handoffKey) {
                await controller.retireLocalReservations()
                guard current(captured, scope: scope) else { dirty = true; return }
                let (code, response) = try await send("/devices/\(device)/remote-resume", method: "POST", body: [:])
                // An older server cannot go back to remote: its reservations use the channel.
                if code == 404 { controller.disableTokenMode(); dirty = true; return }
                guard (200..<300).contains(code) else { throw ScheduleServiceError.server(response["error"] as? String ?? "HTTP \(code)") }
                guard response["launchMode"] as? String == "remote" else { throw ScheduleServiceError.invalidResponse }
                defaults.removeObject(forKey: Self.handoffKey)
                defaults.removeObject(forKey: Self.handoffKey + ".history")
                serverHistory = []
            }
        } else if #available(iOS 26.0, *) {
            if !defaults.bool(forKey: Self.handoffKey) {
                let response = try await request("/devices/\(device)/local-handoff", method: "POST", body: [:])
                guard response["launchMode"] as? String == "local" else { throw ScheduleServiceError.invalidResponse }
                if let error = response["error"] as? String, !error.isEmpty { throw ScheduleServiceError.server("旧实时活动仍在排空，请稍后重新打开 App。") }
                serverHistory = Self.submittedHistory(response)
                defaults.set(Array(serverHistory), forKey: Self.handoffKey + ".history")
                defaults.set(true, forKey: Self.handoffKey)
            } else {
                serverHistory = Set(defaults.stringArray(forKey: Self.handoffKey + ".history") ?? [])
            }
            local = true
        }
        if !controller.tokenModeUnsupported { await synchronizeActivities(device: device) }
        guard current(captured, scope: scope) else { dirty = true; return }
        if cachedSchool != school || cachedMapping?.periods != snapshot.periods.map({ LiveActivityMapping.Period(number: $0.number, start: $0.startTime, end: $0.endTime) }) || cachedMapping?.timeZone != snapshot.timeZone || Date().timeIntervalSince(mappingFetchedAt) > 3600 {
            var components = URLComponents()
            components.queryItems = [URLQueryItem(name: "schoolID", value: school), URLQueryItem(name: "scheduleId", value: "default"), URLQueryItem(name: "bundleID", value: Bundle.main.bundleIdentifier ?? ""), URLQueryItem(name: "environment", value: Self.environment), URLQueryItem(name: "deviceID", value: device)]
            do {
                let response = try await request("/broadcast-config?" + (components.percentEncodedQuery ?? ""), method: "GET")
                cachedMapping = try JSONDecoder().decode(LiveActivityMapping.self, from: JSONSerialization.data(withJSONObject: response))
                cachedSchool = school
                mappingFetchedAt = Date()
                defaults.set(try JSONEncoder().encode(cachedMapping), forKey: "naptable.liveActivity.v2.mapping." + Self.environment)
            } catch {
                // Cached expiry is immutable: offline use never renews its promise.
                cachedMapping = defaults.data(forKey: "naptable.liveActivity.v2.mapping." + Self.environment).flatMap { try? JSONDecoder().decode(LiveActivityMapping.self, from: $0) }
                guard local, let mapping = cachedMapping, mapping.schoolID == school, mapping.createBefore > Date().timeIntervalSince1970 else { throw error }
                cachedSchool = school
                mappingFetchedAt = Date()
            }
        }
        guard current(captured, scope: scope), let mapping = cachedMapping else { return }
        controller.applyMapping(mapping, localHandoff: local, submitted: serverHistory)
        if mapping.status != "ready" { scheduleRetry() }
        // applyMapping may rebuild once; the serialized next pass submits that snapshot.
        guard current(captured, scope: scope), let display = controller.display,
              display.scope == scope, display.scheduleVersion == mapping.scheduleVersion else { return }
        if local { status = .ready(pending: 0, nextFireAt: nil); return }
        let coverageStart = floor(Date().timeIntervalSince1970 / 86400) * 86400
        let old = defaults.data(forKey: Self.planKey).flatMap { try? JSONDecoder().decode(LiveActivityPlan.self, from: $0) }
        var plan = LiveActivityPlan(planRevision: old?.planRevision ?? 1, scheduleScope: scope, schoolID: school,
            scheduleVersion: mapping.scheduleVersion, coverageStart: coverageStart, coverageEndExclusive: coverageStart + 181 * 86400,
            leadMinutes: controller.leadMinutes, items: display.occurrences.map(\.item), busyIntervals: [],
            pushMode: controller.pushMode == "token" ? "token" : nil)
        if let old, plan != old { plan.planRevision = old.planRevision + 1 }
        // Persist before upload: retry after a lost response reuses exactly the same revision/body.
        defaults.set(try JSONEncoder().encode(plan), forKey: Self.planKey)
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as! [String: Any]
        let (code, response) = try await send("/devices/\(device)/plan", method: "PUT", body: body)
        if plan.pushMode != nil, Self.refusesTokenMode(status: code, error: response["error"] as? String) || Self.refusesTimedItems(status: code, error: response["error"] as? String) {
            controller.disableTokenMode(); return
        }
        guard (200..<300).contains(code) else { throw ScheduleServiceError.server(response["error"] as? String ?? "HTTP \(code)") }
        guard current(captured, scope: scope) else { return }
        status = token == nil ? .waitingForToken : .ready(pending: response["pendingCount"] as? Int ?? 0, nextFireAt: nil)
    }
    /// An older server answers token mode with its strict-plan 400 or an unknown-route 404.
    static func refusesTokenMode(status: Int, error: String?) -> Bool {
        status == 404 || (status == 400 && error?.hasPrefix("expected complete v2 plan") == true)
    }
    /// A server that knows token mode but not items placed by instant (the
    /// reader's own courses) refuses them as a malformed occurrence.
    static func refusesTimedItems(status: Int, error: String?) -> Bool {
        status == 400 && error?.hasPrefix("invalid occurrence") == true
    }
    /// A server predating `alertAt` refuses any key beyond the four it knows.
    static func refusesAlerts(status: Int, error: String?) -> Bool {
        status == 400 && error?.hasPrefix("expected token, dateKey, refreshAt and end only") == true
    }
    /// Token mode: PUT each activity whose token or refresh times changed since
    /// the last accepted upload, DELETE the ones that are gone. A failure retries
    /// with the rest of the service and never holds up the plan.
    private func synchronizeActivities(device: String) async {
        var uploaded = group.dictionary(forKey: Self.activityLedgerKey) as? [String: String] ?? [:]
        let (registrations, live) = controller.tokenRegistrations()
        guard !registrations.isEmpty || !uploaded.isEmpty else { return }
        do {
            for registration in registrations {
                let digest = SHA256.hash(data: Data(registration.signature.utf8)).map { String(format: "%02x", $0) }.joined()
                guard uploaded[registration.occurrenceId] != digest else { continue }
                var body: [String: Any] = ["token": registration.token, "dateKey": registration.dateKey, "refreshAt": registration.refreshAt, "end": registration.end]
                if !alertsUnsupported, !registration.alertAt.isEmpty { body["alertAt"] = registration.alertAt }
                var (code, response) = try await send("/devices/\(device)/activities/\(registration.occurrenceId)", method: "PUT", body: body)
                if body["alertAt"] != nil, Self.refusesAlerts(status: code, error: response["error"] as? String) {
                    // Still worth refreshing: only the extra reminder is lost.
                    alertsUnsupported = true
                    body["alertAt"] = nil
                    (code, response) = try await send("/devices/\(device)/activities/\(registration.occurrenceId)", method: "PUT", body: body)
                }
                if Self.refusesTokenMode(status: code, error: response["error"] as? String) { controller.disableTokenMode(); return }
                guard (200..<300).contains(code) else { throw ScheduleServiceError.server(response["error"] as? String ?? "HTTP \(code)") }
                uploaded[registration.occurrenceId] = digest
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
    private static func submittedHistory(_ response: [String: Any]) -> Set<String> {
        Set((response["history"] as? [[String: Any]] ?? []).compactMap {
            guard let state = $0["state"] as? String, ["submitting", "submitted", "submissionUnknown"].contains(state) else { return nil }
            return $0["occurrenceId"] as? String
        })
    }
    private func forget() async throws {
        guard let device = deviceID else { defaults.removeObject(forKey: Self.revokeKey); return }
        if secret(device) != nil {
            _ = try await request("/devices/\(device)", method: "DELETE", legacy: !defaults.bool(forKey: Self.registrationKey))
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.keychainService, kSecAttrAccount as String: device]
            if let credentials { credentials.remove(device) } else { SecItemDelete(query as CFDictionary) }
        }
        for key in [Self.deviceKey, Self.legacySecretKey, Self.registrationKey, Self.revokeKey, Self.handoffKey, Self.handoffKey + ".history", Self.planKey] { defaults.removeObject(forKey: key) }
        group.removeObject(forKey: Self.activityLedgerKey)
        uploadedToken = nil
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
