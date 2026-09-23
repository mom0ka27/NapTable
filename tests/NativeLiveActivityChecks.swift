import ActivityKit
import Foundation

enum NextWidgetConfiguration { static let appGroup = "naptable.tests.liveActivity.\(UUID().uuidString)" }

@main
struct NativeLiveActivityChecks {
    @MainActor static func main() async throws {
        let defaults = UserDefaults(suiteName: NextWidgetConfiguration.appGroup)!
        defer { defaults.removePersistentDomain(forName: NextWidgetConfiguration.appGroup) }
        let now = ISO8601DateFormatter().date(from: "2026-09-22T00:00:00Z")!.addingTimeInterval(-1800)
        let snapshot = fixture()
        for lead in [15, 30, 60] {
            let result = LiveActivityTimeline.build(snapshot, scope: "lead-\(lead)", now: now, lead: lead, perPeriod: false, defaults: defaults)
            precondition(result.occurrences[0].start - result.occurrences[0].reminder == Double(lead * 60))
        }
        precondition(LiveActivityTimeline.instant(day: "2026-03-08", clock: "02:30", zone: TimeZone(identifier: "America/New_York")!) == nil)
        precondition(LiveActivityTimeline.instant(day: "2026-11-01", clock: "01:30", zone: TimeZone(identifier: "America/New_York")!) == nil)
        let controller = NativeLiveActivityController(now: { now }, privacyDefaults: defaults)
        controller.setEnabled(true)
        precondition(!controller.isEnabled, "Live activities require explicit privacy consent")
        let consent = PrivacyConsent(defaults: defaults)
        consent.acceptBasic(liveActivities: false)
        controller.setEnabled(true)
        precondition(!controller.isEnabled, "Basic consent does not authorize live activities")
        consent.setLiveConsent(true)
        controller.setEnabled(true)
        controller.setLeadMinutes(30)
        precondition(controller.leadMinutes == 30)
        controller.setLeadMinutes(180)
        precondition(controller.leadMinutes == 60)
        controller.setLeadMinutes(30)
        controller.accept(snapshot)
        await settle()
        precondition(live.isEmpty, "No reservation before mapping and acknowledged handoff")
        let mapping = LiveActivityMapping(schoolID: "school", scheduleId: "default", scheduleVersion: "version", periods: [
            .init(number: 1, start: "08:00", end: "08:50"), .init(number: 2, start: "09:00", end: "09:50"),
            .init(number: 3, start: "10:00", end: "10:50")], timeZone: "Asia/Taipei", channels: ["1": "one", "2": "two", "3": "three"], status: "ready", issuedAt: now.timeIntervalSince1970,
            createBefore: now.timeIntervalSince1970 + 168 * 3600, broadcastUntil: now.timeIntervalSince1970 + 192 * 3600)
        controller.applyMapping(mapping, localHandoff: false, submitted: [])
        await settle(); precondition(live.isEmpty)
        controller.applyMapping(mapping, localHandoff: true, submitted: [])
        await settle()
        precondition(live.count == 2, "Two course instances, including course beyond tomorrow")
        precondition(live.allSatisfy { $0.attributes.broadcastChannel == "two" })
        precondition(controller.pushMode == "channel" && live.allSatisfy { $0.pushType == .channel("two") && $0.attributes.pushMode == nil },
                     "The reader's own table keeps the broadcast channel")
        let channelPlan = LiveActivityPlan(planRevision: 1, scheduleScope: "scope", schoolID: "school", scheduleVersion: "version",
            coverageStart: 0, coverageEndExclusive: 86400, leadMinutes: 30, items: [], busyIntervals: [])
        let channelBody = try JSONSerialization.jsonObject(with: JSONEncoder().encode(channelPlan)) as! [String: Any]
        precondition(Set(channelBody.keys) == ["protocolVersion", "planRevision", "scheduleScope", "schoolID", "scheduleId", "scheduleVersion",
            "coverageStart", "coverageEndExclusive", "leadMinutes", "items", "busyIntervals"], "A channel plan body is unchanged: no pushMode key")
        precondition(controller.coverage.contains("2/2"))
        let ids = Set(live.map(\.id))
        controller.accept(snapshot); await settle()
        precondition(Set(live.map(\.id)) == ids, "Repeat sync must keep reservations")
        let first = live[0]
        await first.end(nil, dismissalPolicy: .immediate)
        controller.accept(snapshot); await settle()
        precondition(live.count == 1, "Same-session manual removal must not recreate")
        controller.foreground(); await settle()
        precondition(live.count == 2, "Next foreground can recover missing reservations")
        let display = controller.display!
        let firstOccurrence = display.occurrences[0]
        let textEdit = LiveActivityTimeline.build(fixture(name: "改名"), scope: "scope", now: now, lead: 30, perPeriod: false, defaults: defaults)
        precondition(textEdit.occurrences[0].item.occurrenceId == firstOccurrence.item.occurrenceId, "Text edits retain identity")
        let segmented = LiveActivityTimeline.build(snapshot, scope: "scope", now: now, lead: 30, perPeriod: true, defaults: defaults)
        let start = firstOccurrence.start
        precondition(segmented.occurrences[0].state(at: Date(timeIntervalSince1970: start + 55 * 60))?.phase == .upcoming, "Break stays within one course")
        precondition(segmented.occurrences[0].state(at: Date(timeIntervalSince1970: start + 70 * 60))?.phase == .inProgress)
        precondition(segmented.occurrences[0].state(at: Date(timeIntervalSince1970: firstOccurrence.end)) == nil)
        let matching = ScheduleLiveActivityAttributes(semester: "", dateKey: "2026-09-22", protocolVersion: 2, scheduleScope: "scope", occurrenceId: firstOccurrence.item.occurrenceId, scheduleVersion: "version")
        precondition(display.resolve(attributes: matching, at: now) != nil)
        // Scheduled activities can render at registration, before their reminder begins.
        let registration = Date(timeIntervalSince1970: firstOccurrence.reminder - 12 * 3600)
        precondition(firstOccurrence.state(at: registration) == nil, "Scheduling still respects reminder eligibility")
        let preregistered = LiveActivityDisplaySnapshot.resolveStored(attributes: matching, at: registration)
        precondition(preregistered?.courseName == "同名课程" && preregistered?.phase == .upcoming,
                     "An 08:00 reservation must render its course when prepared the previous evening")
        precondition(preregistered?.startDate == Date(timeIntervalSince1970: start))
        precondition(display.resolve(attributes: matching, at: Date(timeIntervalSince1970: firstOccurrence.reminder - 1)) == preregistered,
                     "Rendering just before wakeup must not produce an empty card")
        precondition(display.resolve(attributes: matching, at: Date(timeIntervalSince1970: start))?.phase == .inProgress)
        precondition(display.resolve(attributes: matching, at: Date(timeIntervalSince1970: firstOccurrence.end)) == nil,
                     "A finished reservation must not revive its initial state")
        let segmentedDisplay = LiveActivityDisplaySnapshot(scope: "scope", scheduleVersion: "version", occurrences: segmented.occurrences)
        precondition(segmentedDisplay.resolve(attributes: matching, at: Date(timeIntervalSince1970: start + 55 * 60))?.phase == .upcoming)
        precondition(segmentedDisplay.resolve(attributes: matching, at: Date(timeIntervalSince1970: start + 70 * 60))?.phase == .inProgress)
        let wrongIdentity = ScheduleLiveActivityAttributes(semester: "", dateKey: "2026-09-22", protocolVersion: 2, scheduleScope: "scope", occurrenceId: "missing", scheduleVersion: "version")
        precondition(display.resolve(attributes: wrongIdentity, at: registration) == nil)
        let wrongVersion = ScheduleLiveActivityAttributes(semester: "", dateKey: "2026-09-22", protocolVersion: 2, scheduleScope: "scope", occurrenceId: firstOccurrence.item.occurrenceId, scheduleVersion: "missing")
        precondition(LiveActivityDisplaySnapshot.resolveStored(attributes: wrongVersion, at: registration) == nil)
        let wrongScope = ScheduleLiveActivityAttributes(semester: "", dateKey: "2026-09-22", protocolVersion: 2, scheduleScope: "other", occurrenceId: firstOccurrence.item.occurrenceId, scheduleVersion: "version")
        precondition(display.resolve(attributes: wrongScope, at: now) == nil)
        let conflicted = LiveActivityTimeline.build(fixture(conflict: true), scope: "conflict", now: now, lead: 30, perPeriod: false, defaults: defaults)
        precondition(conflicted.conflicts.count == 2 && conflicted.occurrences.isEmpty, "Same-name different-source courses require a choice")
        defaults.set(["2026-09-22:2": "B", "2026-09-25:2": "B"], forKey: "naptable.liveActivity.conflicts.conflict")
        let resolved = LiveActivityTimeline.build(fixture(conflict: true), scope: "conflict", now: now, lead: 60, perPeriod: false, defaults: defaults)
        precondition(resolved.occurrences.count == 6, "A-B-A selection splits original course")
        precondition(resolved.occurrences[1].reminder == resolved.occurrences[0].end, "Previous class clips lead time")
        precondition(resolved.occurrences[0].sourceID != resolved.occurrences[1].sourceID)
        let adjusted = LiveActivityTimeline.build(fixture(adjusted: true), scope: "adjusted", now: now, lead: 30, perPeriod: false, defaults: defaults)
        precondition(adjusted.occurrences.contains { $0.item.dateKey == "2026-09-23" }, "Adjustment expands actual date")
        precondition(!adjusted.occurrences.contains { $0.item.dateKey == "2026-09-22" })
        // A followed share carries the reader's concurrent course as its companion.
        let share = fixture(source: "小明")
        let mineCourse = NativeScheduleCourse(liveActivitySourceID: "M", name: "有机化学", weeks: "1周", weekList: [1], location: "1教105", startSlot: 2, endSlot: 3)
        let mine = NativeScheduleSnapshot(scheduleScope: "own", periods: share.periods,
            data: NativeScheduleResult(currentSemester: "term", cells: [NativeScheduleCell(day: 2, bigSlot: 1, courses: [mineCourse])]),
            calendar: share.calendar, timeZone: "Asia/Taipei")
        let merged = LiveActivityTimeline.build(share, own: mine, scope: "share", now: now, lead: 30, perPeriod: false, defaults: defaults)
        let shared = merged.occurrences[0]
        let nine = shared.start + 60 * 60
        precondition(shared.state(at: Date(timeIntervalSince1970: shared.start + 10 * 60))?.companion == nil, "Not merged before the reader's class")
        precondition(shared.state(at: Date(timeIntervalSince1970: nine))?.companion?.courseName == "有机化学", "Merged while both are in class")
        precondition(shared.state(at: Date(timeIntervalSince1970: nine))?.sourceLabel == "小明")
        precondition(shared.frames.contains { $0.from == nine }, "Frames split where the reader's class starts")
        precondition(merged.occurrences.map(\.item) == LiveActivityTimeline.build(share, scope: "share", now: now, lead: 30, perPeriod: false, defaults: defaults).occurrences.map(\.item),
                     "The companion is display-only and never changes the plan")
        precondition(LiveActivityTimeline.build(snapshot, own: mine, scope: "scope", now: now, lead: 30, perPeriod: false, defaults: defaults)
            .occurrences.allSatisfy { $0.frames.allSatisfy { $0.state.companion == nil } }, "The reader's own table never companions itself")
        let encoded = try JSONEncoder().encode(shared.state(at: Date(timeIntervalSince1970: nine)))
        let decoded = try JSONDecoder().decode(ScheduleLiveActivityAttributes.ContentState.self, from: encoded)
        precondition(decoded.companion?.endDate == Date(timeIntervalSince1970: shared.start + 2 * 3600 + 50 * 60), "Companion round-trips through the wire format")
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let wire = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as! [String: Any]
        for event in ["start", "update", "end"] {
            let aps = (wire[event] as! [String: Any])["aps"] as! [String: Any]
            let state = try JSONDecoder().decode(ScheduleLiveActivityAttributes.ContentState.self, from: JSONSerialization.data(withJSONObject: aps["content-state"]!))
            precondition(state.broadcastTimestamp!.timeIntervalSince1970 == aps["timestamp"] as! Double)
            if event == "start" {
                let attributes = try JSONDecoder().decode(ScheduleLiveActivityAttributes.self, from: JSONSerialization.data(withJSONObject: aps["attributes"]!))
                precondition(attributes.protocolVersion == 2 && attributes.occurrenceId == "occurrence")
                precondition(attributes.reminderDate?.timeIntervalSince1970 == aps["timestamp"] as? Double)
                precondition(attributes.reservationEnd!.timeIntervalSince1970 > state.broadcastTimestamp!.timeIntervalSince1970)
            }
        }
        // Capacity is partial coverage, not a failure of already accepted reservations.
        controller.end(); await settle()
        TestActivityKit.capacity = 1
        controller.foreground(); await settle()
        precondition(live.count == 1 && controller.coverage.contains("1/2"))
        precondition(live[0].attributes.occurrenceId == controller.display!.occurrences[0].item.occurrenceId,
                     "Reserve the nearest course first")
        guard case .limited = controller.status else { preconditionFailure("Quota must show limited coverage") }
        let reservedID = live[0].id
        controller.foreground(); await settle()
        precondition(live[0].id == reservedID, "Keep the accepted reservation across quota retries")
        TestActivityKit.capacity = 2
        controller.foreground(); await settle()
        precondition(live.count == 2 && controller.coverage.contains("2/2"), "Refill when capacity becomes available")
        precondition(controller.status == .waiting)

        // Non-quota failures must not evict a valid later reservation.
        let nearest = live.first { $0.attributes.occurrenceId == controller.display!.occurrences[0].item.occurrenceId }!
        await nearest.end(nil, dismissalPolicy: .immediate)
        controller.accept(snapshot); await settle()
        TestActivityKit.failNextRequest = true
        controller.foreground(); await settle()
        precondition(live.count == 1, "A generic failure must preserve the later reservation")
        guard case .unavailable = controller.status else { preconditionFailure("Other errors remain visible") }

        controller.end(); await settle()
        TestActivityKit.capacity = 0
        TestActivityKit.capacityError = .globalMaximumExceeded
        let attempts = TestActivityKit.requestAttempts
        controller.foreground(); await settle()
        precondition(TestActivityKit.requestAttempts == attempts + 1, "Stop requesting more slots once full")
        guard case .limited = controller.status else { preconditionFailure("Global capacity is also limited") }
        TestActivityKit.capacity = 2
        controller.foreground(); await settle()
        controller.startPreview(); await settle()
        precondition(controller.isPreviewActive && live.count == 1 && live[0].attributes.semester == "__preview__",
                     "Preview waits for reservations to retire before requesting a slot")
        controller.endPreview(); await settle()
        precondition(live.count == 2, "Ending preview restores reservations")
        TestActivityKit.capacity = Int.max
        controller.setEnabled(false); await settle()
        controller.foreground(); await settle()
        precondition(live.isEmpty && !controller.isEnabled, "Foreground must never enable the user's switch")

        // Token mode: the refresh instants are exactly the display changes.
        let blank = shared.frames[0].state
        let gapped = LiveActivityOccurrence(item: .init(occurrenceId: "gap", supersedes: [], dateKey: "2026-09-22", startPeriod: 1, endPeriod: 1),
            sourceID: "A", start: 0, end: 40, reminder: 0, frames: [.init(from: 0, until: 10, state: blank), .init(from: 20, until: 40, state: blank)])
        precondition(gapped.refreshAt() == [10, 20], "A gap refreshes where it opens and where it closes")
        precondition(segmented.occurrences[0].refreshAt() == [start, start + 50 * 60, start + 60 * 60], "Per-period mode refreshes at each bell")
        precondition(shared.refreshAt() == [shared.start, nine], "The reader's own class start splits the share's frame")
        precondition(shared.refreshAt(after: shared.start + 60) == [shared.start, nine] && shared.refreshAt(after: shared.start + 61) == [nine],
                     "Instants more than a minute old are dropped")
        // A followed share reserves token activities and announces their tokens.
        let follower = NativeLiveActivityController(now: { now }, privacyDefaults: defaults)
        follower.setEnabled(true)
        var announcements = 0
        follower.activityTokensDidChange = { announcements += 1 }
        let followed = fixture(source: "小明", scope: "share")
        follower.accept(followed, own: mine)
        follower.applyMapping(mapping, localHandoff: true, submitted: []); await settle()
        precondition(follower.pushMode == "token" && live.count == 2)
        precondition(live.allSatisfy { $0.pushType == .token && $0.attributes.pushMode == "token" && $0.attributes.broadcastChannel == nil },
                     "Token mode reserves with .token and no channel")
        precondition(follower.tokenRegistrations().registrations.isEmpty && follower.tokenRegistrations().live.count == 2 && announcements == 1)
        let opening = follower.display!.occurrences[0]
        let reserved = live.first { $0.attributes.occurrenceId == opening.item.occurrenceId }!
        reserved.deliverPushToken(Data([0xab, 0xcd, 0x01])); await settle()
        var registrations = follower.tokenRegistrations().registrations
        precondition(announcements == 2 && registrations.count == 1 && registrations[0].token == "abcd01" && registrations[0].dateKey == "2026-09-22")
        precondition(registrations[0].refreshAt == [opening.start, opening.start + 3600] && registrations[0].end == opening.end,
                     "Refresh at class start and where the reader's own class joins")
        let reservations = Set(live.map(\.id))
        follower.accept(followed, own: mine); follower.foreground(); await settle()
        precondition(announcements == 2 && Set(live.map(\.id)) == reservations, "An unchanged rebuild announces nothing")
        let earlierCourse = NativeScheduleCourse(liveActivitySourceID: "M", name: "有机化学", weeks: "1周", weekList: [1], location: "1教105", startSlot: 1, endSlot: 1)
        let earlier = NativeScheduleSnapshot(scheduleScope: "own", periods: share.periods,
            data: NativeScheduleResult(currentSemester: "term", cells: [NativeScheduleCell(day: 2, bigSlot: 1, courses: [earlierCourse])]),
            calendar: share.calendar, timeZone: "Asia/Taipei")
        follower.accept(followed, own: earlier); await settle()
        registrations = follower.tokenRegistrations().registrations
        precondition(announcements == 3 && registrations[0].refreshAt == [opening.start, opening.start + 50 * 60], "Editing the reader's own table moves the refresh")
        reserved.begin()
        follower.foreground(); await settle()
        precondition(reserved.content.staleDate == Date(timeIntervalSince1970: opening.start), "A local update goes stale at the next display change, not the end")
        // An older server refused token mode: channel for the rest of the session.
        follower.disableTokenMode(); await settle()
        precondition(follower.pushMode == "channel" && follower.tokenNotice == "服务端尚不支持共享课表的实时刷新")
        let fallback = live.filter { $0.id != reserved.id }
        precondition(live.contains { $0.id == reserved.id } && fallback.count == 1 && fallback[0].pushType == .channel("two") && fallback[0].attributes.pushMode == nil,
                     "Pending reservations move to the channel; the active one finishes")
        follower.setEnabled(false); await settle()
        print("Live Activity v2 Swift checks passed")
    }
    @MainActor static var live: [Activity<ScheduleLiveActivityAttributes>] {
        Activity<ScheduleLiveActivityAttributes>.activities.filter { $0.activityState != .ended && $0.activityState != .dismissed }
    }
    static func settle() async { for _ in 0..<12 { await Task.yield() }; try? await Task.sleep(nanoseconds: 10_000_000) }
    static func fixture(name: String = "同名课程", conflict: Bool = false, adjusted: Bool = false, source: String? = nil, scope: String = "scope") -> NativeScheduleSnapshot {
        let a = NativeScheduleCourse(liveActivitySourceID: "A", name: name, weeks: "1周", weekList: [1], startSlot: 1, endSlot: conflict ? 3 : 2)
        let b = NativeScheduleCourse(liveActivitySourceID: "B", name: name, weeks: "1周", weekList: [1], startSlot: 2, endSlot: 2)
        let periods = [NativeSchedulePeriod(number: 1, startTime: "08:00", endTime: "08:50"), NativeSchedulePeriod(number: 2, startTime: "09:00", endTime: "09:50"), NativeSchedulePeriod(number: 3, startTime: "10:00", endTime: "10:50")]
        return NativeScheduleSnapshot(scheduleScope: scope, periods: periods,
            data: NativeScheduleResult(currentSemester: "term", cells: [NativeScheduleCell(day: 2, bigSlot: 1, courses: conflict ? [a, b] : [a]), NativeScheduleCell(day: 5, bigSlot: 1, courses: conflict ? [a, b] : [a])]),
            calendar: NativeScheduleCalendar(weeks: [NativeCalendarWeek(week: 1, days: ["2026-09-21", "2026-09-22", "2026-09-23", "2026-09-24", "2026-09-25", "2026-09-26", "2026-09-27"])], adjustments: adjusted ? CalendarAdjustmentResolver.index([CalendarAdjustment(date: "2026-09-22", kind: .off, note: "放假"), CalendarAdjustment(date: "2026-09-23", kind: .swap, source: "2026-09-22", note: "调课")], semesterStartMonday: "2026-09-21") : [:]), sourceLabel: source, schoolID: "school", timeZone: "Asia/Taipei")
    }
}
