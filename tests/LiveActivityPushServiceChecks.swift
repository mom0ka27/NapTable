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
        try await tokenMode(group: group)
        print("Live Activity coordinator late-response / offline-revocation checks passed")
    }
    /// A followed share starts remotely, even on iOS 26: the plan goes up in token mode and each
    /// remotely started activity's token and refresh times follow, and nothing else.
    @MainActor static func tokenMode(group: UserDefaults) async throws {
        let suite = "naptable.tests.token.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        PrivacyConsent(defaults: defaults).acceptBasic(liveActivities: true)
        group.set(true, forKey: NativeLiveActivityController.enabledKey)
        let clock = ISO8601DateFormatter().date(from: "2026-09-22T00:00:00Z")!.addingTimeInterval(-1800)  // 07:30 Asia/Taipei
        let controller = NativeLiveActivityController(now: { clock }, privacyDefaults: defaults)
        var keys: [String: String] = [:]
        var requests: [URLRequest] = []
        var olderServer = false
        let service = LiveActivityPushService(controller: controller, defaults: defaults,
            credentials: .init(read: { keys[$0] }, write: { keys[$0] = $1 }, remove: { keys[$0] = nil }), baseURL: URL(string: "https://example.invalid")) { request in
                requests.append(request)
                let path = request.url!.path
                if path.hasSuffix("/devices") { return response(request, ["launchMode": "remote"]) }
                if path.hasSuffix("local-handoff") { return response(request, ["launchMode": "local", "history": []]) }
                if path.hasSuffix("remote-resume") || path.contains("/activities/") {
                    if olderServer { return response(request, ["error": "not found"], status: 404) }
                    return response(request, path.contains("/activities/") ? ["pending": 2] : ["launchMode": "remote", "history": []])
                }
                if path.hasSuffix("/plan") { return response(request, ["launchMode": "remote", "pendingCount": 1]) }
                if path.hasSuffix("broadcast-config") {
                    return response(request, ["schoolID": "school", "scheduleId": "default", "scheduleVersion": "v", "periods": [["number": 1, "start": "08:00", "end": "08:50"], ["number": 2, "start": "09:00", "end": "09:50"], ["number": 3, "start": "10:00", "end": "10:50"]], "timeZone": "Asia/Taipei", "channels": ["1": "one", "2": "two", "3": "three"], "status": "ready", "issuedAt": Date().timeIntervalSince1970, "createBefore": Date().timeIntervalSince1970 + 604800, "broadcastUntil": Date().timeIntervalSince1970 + 691200])
                }
                fatalError("unexpected request \(path)")
            }
        func calls(_ suffix: String) -> [URLRequest] { requests.filter { $0.url!.path.hasSuffix(suffix) } }
        func activityCalls() -> [URLRequest] { requests.filter { $0.url!.path.contains("/activities/") } }
        func body(_ request: URLRequest) -> [String: Any] { try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any] }
        func pending(_ scope: String) -> [Activity<ScheduleLiveActivityAttributes>] {
            Activity<ScheduleLiveActivityAttributes>.activities.filter { $0.attributes.scheduleScope == scope && $0.activityState == .pending }
        }
        let share = timetable(scope: "share", source: "小明", first: 1, last: 2)
        controller.accept(share, own: timetable(scope: "own", first: 2, last: 3))
        service.activate()
        for _ in 0..<3 { await settle() }
        precondition(calls("local-handoff").isEmpty && calls("remote-resume").isEmpty, "A fresh device stays remote while following")
        precondition(calls("/plan").count == 1 && body(calls("/plan")[0])["pushMode"] as? String == "token", "The share's plan goes up in token mode")
        precondition(pending("share").isEmpty && activityCalls().isEmpty, "No local reservation, so nothing to upload yet")
        let occurrence = controller.display!.occurrences[0]
        // The system starts the activity from the push and wakes the app for its token.
        let remote = Activity<ScheduleLiveActivityAttributes>.remoteStart(attributes: .init(semester: "", dateKey: "2026-09-22", protocolVersion: 2, scheduleScope: "share",
            occurrenceId: occurrence.item.occurrenceId, scheduleVersion: "v", pushMode: "token"), content: .init(state: occurrence.frames[0].state, staleDate: nil))
        await settle()
        precondition(activityCalls().isEmpty, "No upload before the system issues a token")
        remote.deliverPushToken(Data(repeating: 0xab, count: 16))
        for _ in 0..<2 { await settle() }
        precondition(activityCalls().count == 1 && activityCalls()[0].httpMethod == "PUT" && activityCalls()[0].url!.path.hasSuffix("/activities/" + occurrence.item.occurrenceId))
        let uploaded = body(activityCalls()[0])
        precondition(Set(uploaded.keys) == ["token", "dateKey", "refreshAt", "end"] && uploaded["token"] as? String == String(repeating: "ab", count: 16))
        precondition(uploaded["dateKey"] as? String == "2026-09-22" && uploaded["end"] as? Double == occurrence.end)
        precondition(uploaded["refreshAt"] as? [Double] == [occurrence.start, occurrence.start + 3600], "Class start and the reader's own class start")
        controller.accept(share, own: timetable(scope: "own", first: 2, last: 3)); controller.foreground()
        for _ in 0..<2 { await settle() }
        precondition(activityCalls().count == 1, "An unchanged rebuild sends nothing")
        controller.accept(share, own: timetable(scope: "own", first: 1, last: 1))
        for _ in 0..<2 { await settle() }
        precondition(activityCalls().count == 2 && body(activityCalls()[1])["refreshAt"] as? [Double] == [occurrence.start, occurrence.start + 50 * 60],
                     "The reader's own edit moves the companion boundary")
        remote.deliverPushToken(Data(repeating: 0xcd, count: 16))
        for _ in 0..<2 { await settle() }
        precondition(activityCalls().count == 3 && body(activityCalls()[2])["token"] as? String == String(repeating: "cd", count: 16), "A rotated token is uploaded")
        // No longer following: the activity ends, its refreshes are withdrawn and iOS 26 reserves locally.
        controller.accept(timetable(scope: "own", first: 2, last: 3), own: nil)
        for _ in 0..<3 { await settle() }
        precondition(activityCalls().count == 4 && activityCalls()[3].httpMethod == "DELETE", "Unfollowing withdraws the token activity")
        precondition(controller.pushMode == "channel" && calls("local-handoff").count == 1 && defaults.bool(forKey: "naptable.liveActivity.v2.handoff"))
        precondition(pending("own").count == 1 && pending("own")[0].pushType == .channel("three"), "The reader's own table reserves on the channel")
        // Following again: local reservations go first, then the server resumes remote starts.
        let plans = calls("/plan").count
        controller.accept(share, own: timetable(scope: "own", first: 2, last: 3))
        for _ in 0..<3 { await settle() }
        precondition(calls("remote-resume").count == 1 && !defaults.bool(forKey: "naptable.liveActivity.v2.handoff"))
        precondition(pending("own").isEmpty && pending("share").isEmpty && calls("/plan").count > plans, "Back to remote with no reservation left")
        // An older server cannot resume remote: the share reserves on the channel for this session.
        controller.accept(timetable(scope: "own", first: 2, last: 3), own: nil)
        for _ in 0..<3 { await settle() }
        olderServer = true
        precondition(LiveActivityPushService.refusesTokenMode(status: 400, error: "expected complete v2 plan; personal display fields are forbidden"))
        precondition(!LiveActivityPushService.refusesTokenMode(status: 400, error: "resolve overlapping courses before scheduling"))
        controller.accept(share, own: timetable(scope: "own", first: 2, last: 3))
        for _ in 0..<4 { await settle() }
        precondition(controller.tokenModeUnsupported && controller.pushMode == "channel" && controller.tokenNotice != nil)
        precondition(pending("share").count == 1 && pending("share")[0].pushType == .channel("two"), "Reservations use the broadcast channel")
        let refused = calls("remote-resume").count
        controller.foreground()
        for _ in 0..<2 { await settle() }
        precondition(calls("remote-resume").count == refused, "No retry loop against an older server")
        controller.setEnabled(false)
        for _ in 0..<2 { await settle() }
    }
    static func timetable(scope: String, source: String? = nil, first: Int, last: Int) -> NativeScheduleSnapshot {
        let course = NativeScheduleCourse(liveActivitySourceID: source == nil ? "M" : "A", name: source == nil ? "有机化学" : "高等数学", weeks: "1周", weekList: [1], startSlot: first, endSlot: last)
        let periods = [NativeSchedulePeriod(number: 1, startTime: "08:00", endTime: "08:50"), NativeSchedulePeriod(number: 2, startTime: "09:00", endTime: "09:50"), NativeSchedulePeriod(number: 3, startTime: "10:00", endTime: "10:50")]
        return NativeScheduleSnapshot(scheduleScope: scope, periods: periods,
            data: NativeScheduleResult(currentSemester: "term", cells: [NativeScheduleCell(day: 2, bigSlot: 1, courses: [course])]),
            calendar: NativeScheduleCalendar(weeks: [NativeCalendarWeek(week: 1, days: ["2026-09-21", "2026-09-22", "2026-09-23", "2026-09-24", "2026-09-25", "2026-09-26", "2026-09-27"])], adjustments: [:]),
            sourceLabel: source, schoolID: "school", timeZone: "Asia/Taipei")
    }
    static func response(_ request: URLRequest, _ value: [String: Any], status: Int = 200) -> (Data, HTTPURLResponse) {
        (try! JSONSerialization.data(withJSONObject: value), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
    static func settle() async { for _ in 0..<20 { await Task.yield() }; try? await Task.sleep(nanoseconds: 20_000_000) }
    static func snapshot(_ scope: String) -> NativeScheduleSnapshot {
        NativeScheduleSnapshot(scheduleScope: scope, periods: [.init(number: 1, startTime: "08:00", endTime: "08:50")], data: NativeScheduleResult(), calendar: NativeScheduleCalendar(), schoolID: "school", timeZone: "Asia/Taipei")
    }
}
