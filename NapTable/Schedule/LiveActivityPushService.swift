#if os(iOS)
import ActivityKit
import Combine
import CryptoKit
import Foundation

/// Hands the Live Activity over to the NapTable server so a class can reach the
/// Lock Screen while the app is suspended.
///
/// `Activity.request` is refused from the background, which is why the existing
/// controller can only start an activity once the app is opened. iOS 17.2 added
/// a second way in: a push-to-start token the system accepts on the app's
/// behalf. This service collects that token, uploads the plan the controller
/// renders, and registers the push token of every activity that is running so
/// the server can also advance and dismiss it.
///
/// Nothing here decides *what* to show. The plan arrives fully rendered from
/// `NativeLiveActivityController`, so the island looks the same whether a frame
/// came from the refresh loop or from APNs.
@available(iOS 17.2, *)
@MainActor
final class LiveActivityPushService: ObservableObject {
    enum Status: Equatable {
        case off
        case waitingForToken
        case ready(pending: Int, nextFireAt: Date?)
        case failed(String)

        var title: String {
            switch self {
            case .off: return "已关闭"
            case .waitingForToken: return "等待系统下发推送令牌"
            case .ready(let pending, _): return pending > 0 ? "已排定 \(pending) 条推送" : "已连接，暂无待推送的课程"
            case .failed: return "同步失败"
            }
        }

        var detail: String? {
            if case .failed(let message) = self { return message }
            if case .ready(_, let next) = self, let next {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "zh_CN")
                formatter.dateFormat = "M 月 d 日 HH:mm"
                formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
                return "下一条推送：" + formatter.string(from: next)
            }
            return nil
        }
    }

    static let shared = LiveActivityPushService()
    /// The device credential lives beside the share token rather than in the
    /// App Group: only the app itself ever talks to the server.
    private static let deviceIDKey = "naptable.liveActivity.deviceID"
    private static let secretKey = "naptable.liveActivity.deviceSecret"
    private static let channelIDKey = "naptable.liveActivity.channelID"
    private static let digestKey = "naptable.liveActivity.planDigest"
    private static let pendingStartTokenKey = "naptable.liveActivity.pendingStartToken"
    private static let pendingActivityTokensKey = "naptable.liveActivity.pendingActivityTokens"

    private struct PendingActivityRegistration: Codable, Equatable {
        var activityID: String
        var updateToken: String
        var expiresAt: Int
    }

    @Published private(set) var status: Status = .off

    private let defaults = UserDefaults.standard
    private var startTokenTask: Task<Void, Never>?
    private var activityTask: Task<Void, Never>?
    private var tokenTasks: [String: Task<Void, Never>] = [:]
    private var uploadTask: Task<Void, Never>?
    private var pendingStartToken: String?
    private var dayConfigTask: Task<Void, Never>?

    /// Server push is not a separate feature: whoever turned Live Activities on
    /// wants them to appear without opening the app, so this follows the single
    /// switch the controller owns.
    var isEnabled: Bool { NativeLiveActivityController.shared.isEnabled }
    var deviceID: String? { defaults.string(forKey: Self.deviceIDKey) }
    var channelID: String? { defaults.string(forKey: Self.channelIDKey) }
    private var secret: String? { defaults.string(forKey: Self.secretKey) }

    /// `development` for a build signed with a development profile, so the
    /// server reaches the matching APNs host. Reading the embedded profile
    /// avoids guessing from build configuration, which is wrong for TestFlight.
    static let environment: String = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let range = text.range(of: "<key>aps-environment</key>") else {
            #if DEBUG
            return "sandbox"
            #else
            return "production"
            #endif
        }
        return text[range.upperBound...].prefix(200).contains("development") ? "sandbox" : "production"
    }()

    // MARK: - Lifecycle

    /// Called at launch, including the background launch that a push-to-start
    /// triggers: the update token of the activity the system just created is
    /// only delivered to a running app.
    func activate() {
        if #available(iOS 26.0, *) {
            let controller = NativeLiveActivityController.shared
            controller.wantsPushToken = false
            controller.planDidChange = { [weak self] _ in self?.refreshDayChannels() }
            refreshDayChannels()
            return
        }
        NativeLiveActivityController.shared.wantsPushToken = isEnabled
        NativeLiveActivityController.shared.broadcastChannelID = channelID
        NativeLiveActivityController.shared.planDidChange = { [weak self] plan in self?.submit(plan) }
        observeActivities()
        guard isEnabled else {
            status = .off
            return
        }
        status = deviceID == nil ? .waitingForToken : status
        observeStartToken()
        Task {
            if let token = self.defaults.string(forKey: Self.pendingStartTokenKey) {
                await self.registerDevice(startToken: token)
            }
            await self.flushPendingActivityRegistrations()
            await self.refreshStatus()
        }
    }

    /// Called by the controller right after the Live Activity switch changes.
    /// It never writes the setting itself — `isEnabled` reads the same key.
    func enabledDidChange(_ enabled: Bool) {
        if #available(iOS 26.0, *) {
            if enabled { activate() }
            else {
                dayConfigTask?.cancel()
                NativeLiveActivityController.shared.broadcastDayChannels = [:]
                Task { await self.forgetDevice() }
                status = .off
            }
            return
        }
        // A locally started activity is only push-updatable when it was
        // requested with a token, so the controller has to know before it
        // creates the next one.
        NativeLiveActivityController.shared.wantsPushToken = enabled
        if enabled {
            status = .waitingForToken
            observeStartToken()
            // A token that arrived while the feature was off is still valid.
            if let pendingStartToken = pendingStartToken ?? defaults.string(forKey: Self.pendingStartTokenKey) {
                self.pendingStartToken = nil
                Task { await self.registerDevice(startToken: pendingStartToken) }
            }
            NativeLiveActivityController.shared.replanForPush()
        } else {
            startTokenTask?.cancel()
            startTokenTask = nil
            defaults.removeObject(forKey: Self.digestKey)
            status = .off
            Task { await self.forgetDevice() }
        }
    }

    private func observeStartToken() {
        guard startTokenTask == nil else { return }
        startTokenTask = Task { @MainActor [weak self] in
            for await data in Activity<ScheduleLiveActivityAttributes>.pushToStartTokenUpdates {
                guard let self else { continue }
                let token = Self.hex(data)
                self.defaults.set(token, forKey: Self.pendingStartTokenKey)
                await self.registerDevice(startToken: token)
            }
        }
    }

    /// Watches every activity for its push token. This runs even when the
    /// feature is off, because turning it on mid-class should not have to wait
    /// for the next activity to be created.
    private func observeActivities() {
        guard activityTask == nil else { return }
        for activity in Activity<ScheduleLiveActivityAttributes>.activities {
            observe(activity)
        }
        activityTask = Task { @MainActor [weak self] in
            for await activity in Activity<ScheduleLiveActivityAttributes>.activityUpdates {
                self?.observe(activity)
            }
        }
    }

    private func observe(_ activity: Activity<ScheduleLiveActivityAttributes>) {
        guard tokenTasks[activity.id] == nil else { return }
        NativeLiveActivityController.shared.dropDuplicates(keeping: activity)
        tokenTasks[activity.id] = Task { @MainActor [weak self] in
            for await data in activity.pushTokenUpdates {
                await self?.registerActivity(activity, token: Self.hex(data))
            }
            self?.tokenTasks[activity.id] = nil
            await self?.forgetActivity(activity.id)
        }
    }

    // MARK: - Server

    private func registerDevice(startToken: String) async {
        guard isEnabled else {
            if !startToken.isEmpty {
                defaults.set(startToken, forKey: Self.pendingStartTokenKey)
            }
            pendingStartToken = startToken
            return
        }
        if !startToken.isEmpty {
            defaults.set(startToken, forKey: Self.pendingStartTokenKey)
        }
        let baseBody: [String: Any] = [
            "startToken": startToken,
            "environment": Self.environment,
            "bundleID": Bundle.main.bundleIdentifier ?? "",
            "timeZone": "Asia/Shanghai",
        ]
        var lastError: Error?
        for attempt in 0..<4 {
            var body = baseBody
            if #available(iOS 26.0, *) { body["supportsBroadcast"] = true }
            if let snapshot = NativeLiveActivityController.shared.currentScheduleMetadata {
                body["schoolID"] = snapshot.schoolID ?? ""
                body["termID"] = snapshot.termID ?? ""
            }
            if let deviceID { body["deviceID"] = deviceID }
            do {
                let result = try await request(path: "/v1/live-activity/devices", method: "POST", body: body)
                if let id = result["deviceID"] as? String { defaults.set(id, forKey: Self.deviceIDKey) }
                if let secret = result["secret"] as? String { defaults.set(secret, forKey: Self.secretKey) }
                if !startToken.isEmpty {
                    defaults.removeObject(forKey: Self.pendingStartTokenKey)
                }
                if let channelID = result["channelID"] as? String {
                    defaults.set(channelID, forKey: Self.channelIDKey)
                    NativeLiveActivityController.shared.broadcastChannelID = channelID
                } else {
                    defaults.removeObject(forKey: Self.channelIDKey)
                    NativeLiveActivityController.shared.broadcastChannelID = nil
                }
                if result["pushConfigured"] as? Bool == false {
                    status = .failed("服务端还没有配置 APNs 推送密钥。")
                    return
                }
                // A token can arrive before or after the first plan is rendered.
                defaults.removeObject(forKey: Self.digestKey)
                NativeLiveActivityController.shared.replanForPush()
                await flushPendingActivityRegistrations()
                return
            } catch {
                lastError = error
                if attempt < 3 {
                    try? await Task.sleep(for: .seconds(Double(1 << attempt)))
                }
            }
        }
        status = .failed(lastError?.localizedDescription ?? "无法注册推送设备")
    }

    private func registerActivity(_ activity: Activity<ScheduleLiveActivityAttributes>, token: String) async {
        guard isEnabled else { return }
        let expires = max(
            activity.content.state.endDate.addingTimeInterval(48 * 3600),
            Date().addingTimeInterval(48 * 3600)
        )
        let registration = PendingActivityRegistration(
            activityID: activity.id,
            updateToken: token,
            expiresAt: Int(expires.timeIntervalSince1970)
        )
        savePendingActivityRegistration(registration)
        await retryActivityRegistration(registration)
    }

    private func retryActivityRegistration(_ registration: PendingActivityRegistration) async {
        guard isEnabled else { return }
        for attempt in 0..<4 {
            guard deviceID != nil else { return }
            do {
                let id = registration.activityID
                _ = try await request(
                    path: "/v1/live-activity/devices/\(deviceID!)/activities",
                    method: "POST",
                    body: ["activityID": id, "updateToken": registration.updateToken, "expiresAt": registration.expiresAt]
                )
                removePendingActivityRegistration(id)
                return
            } catch {
                if attempt < 3 {
                    try? await Task.sleep(for: .seconds(Double(1 << attempt)))
                }
            }
        }
    }

    private func pendingActivityRegistrations() -> [PendingActivityRegistration] {
        guard let data = defaults.data(forKey: Self.pendingActivityTokensKey),
              let values = try? JSONDecoder().decode([PendingActivityRegistration].self, from: data) else { return [] }
        return values
    }

    private func savePendingActivityRegistration(_ registration: PendingActivityRegistration) {
        var values = pendingActivityRegistrations().filter { $0.activityID != registration.activityID }
        values.append(registration)
        if let data = try? JSONEncoder().encode(values) {
            defaults.set(data, forKey: Self.pendingActivityTokensKey)
        }
    }

    private func removePendingActivityRegistration(_ activityID: String) {
        let values = pendingActivityRegistrations().filter { $0.activityID != activityID }
        if values.isEmpty {
            defaults.removeObject(forKey: Self.pendingActivityTokensKey)
        } else if let data = try? JSONEncoder().encode(values) {
            defaults.set(data, forKey: Self.pendingActivityTokensKey)
        }
    }

    private func flushPendingActivityRegistrations() async {
        for registration in pendingActivityRegistrations() {
            await retryActivityRegistration(registration)
        }
    }

    private func forgetActivity(_ activityID: String) async {
        guard let deviceID else { return }
        _ = try? await request(path: "/v1/live-activity/devices/\(deviceID)/activities/\(activityID)", method: "DELETE")
    }

    private func forgetDevice() async {
        guard let deviceID else { return }
        _ = try? await request(path: "/v1/live-activity/devices/\(deviceID)", method: "DELETE")
        defaults.removeObject(forKey: Self.deviceIDKey)
        defaults.removeObject(forKey: Self.secretKey)
        defaults.removeObject(forKey: Self.channelIDKey)
        NativeLiveActivityController.shared.broadcastChannelID = nil
    }

    /// Upload a freshly rendered plan, skipping the round trip when nothing
    /// about it changed since the last upload.
    func submit(_ plan: [NativeLiveActivityController.PlannedPush]) {
        if #available(iOS 26.0, *) { refreshDayChannels(); return }
        guard isEnabled else { return }
        guard deviceID != nil else {
            // Scheduled Live Activities on iOS 26 do not need a push-to-start
            // token. Register a lightweight device row so the server can
            // return the school's broadcast channel.
            if #available(iOS 26.0, *) {
                Task { await self.registerDevice(startToken: "") }
            }
            return
        }
        let items = plan.map(Self.payload)
        let digest = Self.digest(of: items)
        guard digest != defaults.string(forKey: Self.digestKey) else { return }
        uploadTask?.cancel()
        uploadTask = Task { @MainActor [weak self] in
            guard let self, let deviceID = self.deviceID else { return }
            do {
                await self.refreshDeviceMetadata()
                let result = try await self.request(
                    path: "/v1/live-activity/devices/\(deviceID)/plan", method: "PUT", body: ["items": items])
                self.defaults.set(digest, forKey: Self.digestKey)
                self.apply(result)
            } catch {
                guard !Task.isCancelled else { return }
                self.defaults.removeObject(forKey: Self.digestKey)
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    private func refreshDeviceMetadata() async {
        guard let deviceID, let snapshot = NativeLiveActivityController.shared.currentScheduleMetadata else { return }
        var body: [String: Any] = [
            "deviceID": deviceID,
            "environment": Self.environment,
            "bundleID": Bundle.main.bundleIdentifier ?? "",
            "timeZone": snapshot.timeZone ?? "Asia/Shanghai",
            "schoolID": snapshot.schoolID ?? "",
            "termID": snapshot.termID ?? "",
        ]
        if #available(iOS 26.0, *) { body["supportsBroadcast"] = true }
        guard let result = try? await request(path: "/v1/live-activity/devices", method: "POST", body: body) else { return }
        if let channelID = result["channelID"] as? String {
            defaults.set(channelID, forKey: Self.channelIDKey)
            NativeLiveActivityController.shared.broadcastChannelID = channelID
        } else {
            defaults.removeObject(forKey: Self.channelIDKey)
            NativeLiveActivityController.shared.broadcastChannelID = nil
        }
    }

    func refreshStatus() async {
        if #available(iOS 26.0, *) { refreshDayChannels(); return }
        guard isEnabled, let deviceID else { return }
        if let result = try? await request(path: "/v1/live-activity/devices/\(deviceID)", method: "GET") {
            apply(result)
        }
    }

    private func apply(_ result: [String: Any]) {
        if result["pushConfigured"] as? Bool == false {
            status = .failed("服务端还没有配置 APNs 推送密钥。")
            return
        }
        if let channelID = result["channelID"] as? String {
            defaults.set(channelID, forKey: Self.channelIDKey)
            NativeLiveActivityController.shared.broadcastChannelID = channelID
        } else {
            defaults.removeObject(forKey: Self.channelIDKey)
            NativeLiveActivityController.shared.broadcastChannelID = nil
        }
        if result["hasStartToken"] as? Bool == false && channelID == nil {
            status = .waitingForToken
            return
        }
        let pending = result["pendingCount"] as? Int ?? 0
        let next = (result["nextFireAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
        status = .ready(pending: pending, nextFireAt: next)
    }

    // MARK: - Payload

    private func refreshDayChannels() {
        guard isEnabled, dayConfigTask == nil else { return }
        dayConfigTask = Task { [weak self] in
            guard let self else { return }
            defer { dayConfigTask = nil }
            // Retire the pre-upgrade credential before scheduling local starts.
            if let deviceID {
                do {
                    _ = try await request(path: "/v1/live-activity/devices/\(deviceID)", method: "DELETE")
                    defaults.removeObject(forKey: Self.deviceIDKey)
                    defaults.removeObject(forKey: Self.secretKey)
                } catch { status = .failed(error.localizedDescription); return }
            }
            guard let school = NativeLiveActivityController.shared.currentScheduleMetadata?.schoolID else { return }
            do {
                let result = try await request(path: "/v1/live-activity/day-channels", method: "POST", body: [
                    "schoolID": school, "environment": Self.environment,
                    "bundleID": Bundle.main.bundleIdentifier ?? ""
                ])
                guard !Task.isCancelled, isEnabled,
                      school == NativeLiveActivityController.shared.currentScheduleMetadata?.schoolID else { return }
                NativeLiveActivityController.shared.broadcastDayChannels = result["channels"] as? [String: String] ?? [:]
                status = .ready(pending: 0, nextFireAt: nil)
            } catch { status = .failed(error.localizedDescription) }
        }
    }

    private static func payload(_ push: NativeLiveActivityController.PlannedPush) -> [String: Any] {
        var item: [String: Any] = [
            "id": push.id,
            "event": push.event.rawValue,
            "fireAt": Int(push.fireAt.timeIntervalSince1970),
            "expiresAt": Int(push.expiresAt.timeIntervalSince1970),
            "contentState": object(from: push.state),
            "attributesType": "ScheduleLiveActivityAttributes",
            "staleDate": Int(push.staleDate.timeIntervalSince1970),
        ]
        switch push.event {
        case .start:
            item["attributes"] = object(from: push.attributes)
            // The alert is what a locked device and the Watch show when the
            // activity appears; the island itself needs none.
            item["alert"] = [
                "title": push.state.courseName,
                "body": [push.state.periodLabel, push.state.location]
                    .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "),
            ]
        case .end:
            item["dismissalDate"] = Int(push.fireAt.timeIntervalSince1970)
        case .update:
            break
        }
        return item
    }

    /// The state is coded by its own `Codable`, so the JSON the server relays
    /// is byte for byte what ActivityKit decodes on the way back in.
    private static func object<Value: Encodable>(from value: Value) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    /// Stable across launches, unlike `hashValue`, so a plan that did not
    /// change survives a restart without another upload.
    private static func digest(of items: [[String: Any]]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: items, options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Transport

    @discardableResult
    private func request(path: String, method: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let base = ScheduleSharingService.shared.validatedBaseURL,
              let url = URL(string: path, relativeTo: base) else { throw ScheduleServiceError.missingBaseURL }
        var value = URLRequest(url: url)
        value.httpMethod = method
        value.timeoutInterval = 20
        value.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let secret { value.setValue(secret, forHTTPHeaderField: "X-Device-Secret") }
        if let body { value.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: value)
        guard let http = response as? HTTPURLResponse else { throw ScheduleServiceError.invalidResponse }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 403 {
                // The server forgot this device; register again from scratch.
                defaults.removeObject(forKey: Self.deviceIDKey)
                defaults.removeObject(forKey: Self.secretKey)
            }
            throw ScheduleServiceError.server(object["error"] as? String ?? "HTTP \(http.statusCode)")
        }
        return object
    }
}
#endif
