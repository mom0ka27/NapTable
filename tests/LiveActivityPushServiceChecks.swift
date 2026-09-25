import ActivityKit
import Foundation

enum NextWidgetConfiguration { static let appGroup = "naptable.tests.network.\(UUID().uuidString)" }
@MainActor final class ScheduleSharingService {
    static let shared = ScheduleSharingService()
    var validatedBaseURL: URL? { URL(string: "https://example.invalid") }
}
enum ScheduleServiceError: LocalizedError {
    case missingBaseURL, invalidResponse, server(String)
    var errorDescription: String? { if case .server(let text) = self { return text }; return nil }
}

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
                    return response(request, ["deviceID": "x"])
                }
                if request.httpMethod == "DELETE" {
                    if failDelete { throw ScheduleServiceError.server("offline") }
                    return response(request, ["forgotten": true])
                }
                if path.hasSuffix("/timetable") { return response(request, ["pendingCount": 0]) }
                if path.hasSuffix("/claims") { return response(request, ["claims": []]) }
                fatalError("unexpected request \(path)")
            }
        controller.accept(timetable(scope: "scope-1", first: 1, last: 1))
        service.activate()
        await settle()
        precondition(requests.isEmpty, "No device registration or upload before privacy consent")
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
        precondition(!requests.contains { $0.url!.path.hasSuffix("/timetable") }, "A late response cannot upload the timetable of a disabled device")
        failDelete = false
        await service.refreshStatus()
        precondition(defaults.string(forKey: "naptable.liveActivity.deviceID") == nil)
        precondition(keys[installation] == nil)
        precondition(!controller.isEnabled)
        group.set(true, forKey: NativeLiveActivityController.enabledKey)
        service.enabledDidChange(true)
        await settle()
        precondition(registration != nil)
        controller.accept(timetable(scope: "scope-2", first: 1, last: 1))
        registration?.resume(); registration = nil
        for _ in 0..<2 { await settle() }
        let uploads = requests.filter { $0.url!.path.hasSuffix("/timetable") }
        precondition(uploads.count == 1 && (body(uploads[0])["own"] as? [String: Any])?["scope"] as? String == "scope-2",
                     "Only the timetable in force when the registration returns goes up")
        let beforeRevoke = requests.count
        consent.setLiveConsent(false)
        service.revoke()
        await settle()
        precondition(!controller.isEnabled)
        precondition(defaults.string(forKey: "naptable.liveActivity.deviceID") == nil)
        precondition(requests.dropFirst(beforeRevoke).allSatisfy { $0.httpMethod == "DELETE" }, "Withdrawal only sends cleanup requests, never course data")
        try await server(group: group)
        print("Live Activity coordinator late-response / offline-revocation checks passed")
    }

    /// The whole exchange with a server that schedules: the timetable goes up
    /// when it changes, the nearest reminders come back as claims to reserve,
    /// and token-mode activities report their tokens.
    @MainActor static func server(group: UserDefaults) async throws {
        let suite = "naptable.tests.server.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        PrivacyConsent(defaults: defaults).acceptBasic(liveActivities: true)
        group.set(true, forKey: NativeLiveActivityController.enabledKey)
        let clock = ISO8601DateFormatter().date(from: "2026-09-22T00:00:00Z")!.addingTimeInterval(-1800)  // 07:30 Asia/Taipei
        let start = clock.timeIntervalSince1970 + 1800
        let controller = NativeLiveActivityController(now: { clock }, privacyDefaults: defaults)
        var keys: [String: String] = [:]
        var requests: [URLRequest] = []
        var serverRevision = 0
        var claims: [[String: Any]] = []
        var shareGone = false
        var unknownActivity = false
        let service = LiveActivityPushService(controller: controller, defaults: defaults,
            credentials: .init(read: { keys[$0] }, write: { keys[$0] = $1 }, remove: { keys[$0] = nil }), baseURL: URL(string: "https://example.invalid")) { request in
                requests.append(request)
                let path = request.url!.path
                if path.hasSuffix("/devices") { return response(request, ["deviceID": "x"]) }
                if path.hasSuffix("/timetable") {
                    let sent = body(request)
                    if shareGone, sent["follow"] != nil { return response(request, ["error": "followed share not found"], status: 404) }
                    guard let revision = sent["revision"] as? Int, revision > serverRevision else { return response(request, ["error": "timetable revision conflict"], status: 409) }
                    serverRevision = revision
                    return response(request, ["revision": revision, "pendingCount": 2])
                }
                if request.httpMethod == "GET" { return response(request, ["timetableRevision": serverRevision]) }
                if path.hasSuffix("/claims") { return response(request, ["claims": claims]) }
                if path.contains("/claims/") { return response(request, ["released": true]) }
                if path.contains("/activities/") {
                    if unknownActivity, request.httpMethod == "PUT" { return response(request, ["error": "unknown or finished occurrence"], status: 404) }
                    return response(request, ["pending": 3])
                }
                fatalError("unexpected request \(request.httpMethod!) \(path)")
            }
        func calls(_ suffix: String, _ method: String? = nil) -> [URLRequest] {
            requests.filter { $0.url!.path.hasSuffix(suffix) && (method == nil || $0.httpMethod == method) }
        }
        func containing(_ part: String, _ method: String) -> [URLRequest] { requests.filter { $0.url!.path.contains(part) && $0.httpMethod == method } }
        func claim(_ id: String, minutes: Double, mode: String = "channel", channel: String? = "two", scope: String = "own") -> [String: Any] {
            var value: [String: Any] = ["occurrenceId": id, "dateKey": "2026-09-22", "reminder": start - minutes * 60, "start": start, "end": start + 3000,
                                        "pushMode": mode, "scheduleScope": scope, "scheduleVersion": "v", "shared": []]
            if let channel { value["channel"] = channel }
            return value
        }
        let own = timetable(scope: "own", first: 1, last: 1)
        claims = [claim("first", minutes: 20), claim("broken", minutes: 10, channel: nil)]
        controller.accept(own)
        service.activate()
        for _ in 0..<3 { await settle() }
        // The timetable goes up once, with its first revision; no names.
        precondition(calls("/timetable").count == 1 && body(calls("/timetable")[0])["revision"] as? Int == 1)
        precondition(!String(decoding: calls("/timetable")[0].httpBody!, as: UTF8.self).contains("有机化学"), "Course names never leave the phone")
        // iOS 26 claims its free slots, reserves them, and gives back what it could not.
        precondition(body(calls("/claims")[0])["slots"] as? Int == NativeLiveActivityController.reservationSlots)
        precondition(pending("own").count == 1 && pending("own")[0].attributes.occurrenceId == "first" && pending("own")[0].pushType == .channel("two"))
        precondition(containing("/claims/", "DELETE").map { $0.url!.lastPathComponent } == ["broken"], "A claim without a channel goes back to the server")
        precondition(service.status == .waitingForToken, "Synced; remote starts wait for the system's push-to-start token")
        // Unchanged: nothing goes up again; a foreground claims only the free slots.
        claims = [claim("first", minutes: 20)]
        controller.foreground()
        for _ in 0..<2 { await settle() }
        precondition(calls("/timetable").count == 1, "An unchanged timetable is not uploaded again in this launch")
        precondition(body(calls("/claims").last!)["slots"] as? Int == NativeLiveActivityController.reservationSlots - 1)
        // A setting changes: the next revision.
        controller.setLeadMinutes(15)
        for _ in 0..<2 { await settle() }
        precondition(calls("/timetable").count == 2 && body(calls("/timetable")[1])["revision"] as? Int == 2
                     && (body(calls("/timetable")[1])["settings"] as? [String: Any])?["leadMinutes"] as? Int == 15)
        // Restored from a backup, the phone is behind the server: it continues after the server's revision.
        defaults.set(1, forKey: "naptable.liveActivity.v2.timetableRevision")
        controller.setLeadMinutes(30)
        for _ in 0..<2 { await settle() }
        let retried = calls("/timetable").suffix(2).map { body($0)["revision"] as? Int }
        precondition(retried == [2, 3] && calls("", "GET").count == 1, "A revision conflict asks the server where it is and retries once")

        // Following a share: its code and the phone's name for it go up; the server starts it remotely.
        let share = timetable(scope: "share", source: "小明", first: 1, last: 2)
        claims = []
        controller.accept(share, own: own)
        for _ in 0..<3 { await settle() }
        let followed = body(calls("/timetable").last!)
        precondition(followed["follow"] as? [String: String] == ["share": "SHARE1", "scope": "share"] && (followed["own"] as? [String: Any])?["scope"] as? String == "own")
        precondition(pending("own").isEmpty, "Switching tables ends the other table's reservations")
        let remote = Activity<ScheduleLiveActivityAttributes>.remoteStart(attributes: .init(semester: "", dateKey: "2026-09-22", protocolVersion: 2, scheduleScope: "share",
            occurrenceId: "remote", scheduleVersion: "", reservationStart: Date(timeIntervalSince1970: start), reservationEnd: Date(timeIntervalSince1970: start + 6600),
            reminderDate: Date(timeIntervalSince1970: start - 1800), pushMode: "token"), content: .init(state: controller.display!.occurrences[0].frames[0].state, staleDate: nil))
        await settle()
        precondition(containing("/activities/", "PUT").isEmpty, "No upload before the system issues a token")
        remote.deliverPushToken(Data(repeating: 0xab, count: 16))
        for _ in 0..<2 { await settle() }
        let tokens = containing("/activities/", "PUT")
        precondition(tokens.count == 1 && tokens[0].url!.path.hasSuffix("/activities/remote") && body(tokens[0]) as? [String: String] == ["token": String(repeating: "ab", count: 16)],
                     "Only the token goes up: the refresh instants are the server's")
        controller.foreground()
        for _ in 0..<2 { await settle() }
        precondition(containing("/activities/", "PUT").count == 1, "An unchanged token is not sent again")
        remote.deliverPushToken(Data(repeating: 0xcd, count: 16))
        for _ in 0..<2 { await settle() }
        precondition(containing("/activities/", "PUT").count == 2, "A rotated token is")
        unknownActivity = true
        remote.deliverPushToken(Data(repeating: 0xef, count: 16))
        for _ in 0..<3 { await settle() }
        precondition(containing("/activities/", "PUT").count == 3, "A 404 means nothing left to refresh: not retried")
        // Unfollowing ends the share's activity and withdraws its token.
        controller.accept(own)
        for _ in 0..<3 { await settle() }
        precondition(remote.activityState == .ended && containing("/activities/remote", "DELETE").count == 1)
        // A share that went away is reported, not retried in a loop.
        shareGone = true
        controller.accept(share, own: own)
        for _ in 0..<3 { await settle() }
        if case .failed(let reason) = service.status { precondition(reason.contains("失效"), reason) } else { preconditionFailure("A share that is gone is reported") }
        controller.setEnabled(false)
        for _ in 0..<2 { await settle() }
    }
    @MainActor static func pending(_ scope: String) -> [Activity<ScheduleLiveActivityAttributes>] {
        Activity<ScheduleLiveActivityAttributes>.activities.filter { $0.attributes.scheduleScope == scope && $0.activityState == .pending }
    }
    static func body(_ request: URLRequest) -> [String: Any] { try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any] }
    static func timetable(scope: String, source: String? = nil, first: Int, last: Int) -> NativeScheduleSnapshot {
        let course = NativeScheduleCourse(liveActivitySourceID: source == nil ? "M" : "A", name: source == nil ? "有机化学" : "高等数学", weeks: "1周", weekList: [1], startSlot: first, endSlot: last)
        let periods = [NativeSchedulePeriod(number: 1, startTime: "08:00", endTime: "08:50"), NativeSchedulePeriod(number: 2, startTime: "09:00", endTime: "09:50"), NativeSchedulePeriod(number: 3, startTime: "10:00", endTime: "10:50")]
        return NativeScheduleSnapshot(scheduleScope: scope, periods: periods,
            data: NativeScheduleResult(currentSemester: "term", cells: [NativeScheduleCell(day: 2, bigSlot: 1, courses: [course])]),
            calendar: NativeScheduleCalendar(weeks: [NativeCalendarWeek(week: 1, days: ["2026-09-21", "2026-09-22", "2026-09-23", "2026-09-24", "2026-09-25", "2026-09-26", "2026-09-27"])], adjustments: [:]),
            auth: NativeScheduleAuth(authenticated: true, account: source == nil ? nil : "SHARE1"), sourceLabel: source, schoolID: "school", timeZone: "Asia/Taipei")
    }
    static func response(_ request: URLRequest, _ value: [String: Any], status: Int = 200) -> (Data, HTTPURLResponse) {
        (try! JSONSerialization.data(withJSONObject: value), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
    static func settle() async { for _ in 0..<20 { await Task.yield() }; try? await Task.sleep(nanoseconds: 20_000_000) }
}
