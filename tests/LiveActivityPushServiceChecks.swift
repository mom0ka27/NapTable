import ActivityKit
import Foundation

enum NextWidgetConfiguration { static let appGroup = "naptable.tests.network.\(UUID().uuidString)" }
@MainActor final class ScheduleSharingService {
    static let shared = ScheduleSharingService()
    var validatedBaseURL: URL? { URL(string: "https://example.invalid") }
}
enum ScheduleServiceError: Error { case missingBaseURL, invalidResponse, server(String) }

@main struct LiveActivityPushServiceChecks {
    @MainActor static func main() async throws {
        let group = UserDefaults(suiteName: NextWidgetConfiguration.appGroup)!
        let suite = "naptable.tests.coordinator.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { group.removePersistentDomain(forName: NextWidgetConfiguration.appGroup); defaults.removePersistentDomain(forName: suite) }
        let controller = NativeLiveActivityController(privacyDefaults: defaults)
        var keys: [String: String] = [:]
        let credentials = LiveActivityPushService.CredentialStore(read: { keys[$0] }, write: { keys[$0] = $1 }, remove: { keys[$0] = nil })
        var registration: CheckedContinuation<Void, Never>?
        var requests: [URLRequest] = []
        var failDelete = false
        let service = LiveActivityPushService(controller: controller, defaults: defaults, credentials: credentials,
            baseURL: URL(string: "https://example.invalid")) { request in
                requests.append(request)
                let path = request.url!.path
                if path.hasSuffix("/devices") {
                    await withCheckedContinuation { registration = $0 }
                    return response(request, ["launchMode": "remote"])
                }
                if request.httpMethod == "DELETE" {
                    if failDelete { throw ScheduleServiceError.server("offline") }
                    return response(request, ["forgotten": true])
                }
                if path.hasSuffix("local-handoff") { return response(request, ["launchMode": "local", "history": []]) }
                if path.hasSuffix("broadcast-config") {
                    return response(request, ["schoolID": "school", "scheduleId": "default", "scheduleVersion": "v", "periods": [["number": 1, "start": "08:00", "end": "08:50"]], "timeZone": "Asia/Taipei", "channels": ["1": "channel"], "status": "ready", "issuedAt": Date().timeIntervalSince1970, "createBefore": Date().timeIntervalSince1970 + 604800, "broadcastUntil": Date().timeIntervalSince1970 + 691200])
                }
                fatalError("unexpected request \(path)")
            }
        controller.accept(snapshot("scope-1"))
        service.activate()
        await settle()
        precondition(requests.isEmpty, "No device registration or plan requests before privacy consent")
        let consent = PrivacyConsent(defaults: defaults)
        consent.acceptBasic(liveActivities: false)
        service.activate()
        await settle()
        precondition(requests.isEmpty, "Basic consent alone never enables notification uploads")
        consent.setLiveConsent(true)
        service.activate()
        await settle()
        precondition(registration != nil)
        let installation = defaults.string(forKey: "naptable.liveActivity.deviceID")!
        let savedSecret = keys[installation]!
        precondition(requests[0].value(forHTTPHeaderField: "X-Device-Secret") == savedSecret, "Bootstrap secret survives a lost response")
        group.set(false, forKey: NativeLiveActivityController.enabledKey)
        failDelete = true
        service.enabledDidChange(false)
        registration?.resume(); registration = nil
        await settle()
        precondition(defaults.bool(forKey: "naptable.liveActivity.pendingRevocation"))
        precondition(keys[installation] == savedSecret, "Offline revoke retains credentials even after late registration")
        precondition(!requests.contains { $0.url!.path.hasSuffix("local-handoff") }, "Late response cannot re-enable local scheduling")
        failDelete = false
        await service.refreshStatus()
        precondition(defaults.string(forKey: "naptable.liveActivity.deviceID") == nil)
        precondition(keys[installation] == nil)
        precondition(!controller.isEnabled)
        group.set(true, forKey: NativeLiveActivityController.enabledKey)
        service.enabledDidChange(true)
        await settle()
        precondition(registration != nil)
        controller.accept(snapshot("scope-2"))
        registration?.resume(); registration = nil
        await settle()
        precondition(controller.currentScheduleMetadata?.scheduleScope == "scope-2")
        precondition(defaults.bool(forKey: "naptable.liveActivity.v2.handoff"))
        precondition(controller.mapping?.scheduleVersion == "v")
        precondition(!requests.contains { $0.url!.path.hasSuffix("/plan") }, "Local mode must never upload a remote plan")
        precondition(requests.filter { $0.url!.path.hasSuffix("local-handoff") }.count == 1)
        let beforeRevoke = requests.count
        consent.setLiveConsent(false)
        service.revoke()
        await settle()
        precondition(!controller.isEnabled)
        precondition(defaults.string(forKey: "naptable.liveActivity.deviceID") == nil)
        precondition(requests.dropFirst(beforeRevoke).allSatisfy { $0.httpMethod == "DELETE" }, "Withdrawal only sends cleanup requests, never course data")
        print("Live Activity coordinator late-response / offline-revocation checks passed")
    }
    static func response(_ request: URLRequest, _ value: [String: Any]) -> (Data, HTTPURLResponse) {
        (try! JSONSerialization.data(withJSONObject: value), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
    static func settle() async { for _ in 0..<20 { await Task.yield() }; try? await Task.sleep(nanoseconds: 20_000_000) }
    static func snapshot(_ scope: String) -> NativeScheduleSnapshot {
        NativeScheduleSnapshot(scheduleScope: scope, periods: [.init(number: 1, startTime: "08:00", endTime: "08:50")], data: NativeScheduleResult(), calendar: NativeScheduleCalendar(), schoolID: "school", timeZone: "Asia/Taipei")
    }
}
