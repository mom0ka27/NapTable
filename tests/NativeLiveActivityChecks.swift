import ActivityKit
import Foundation

enum NextWidgetConfiguration { static let appGroup = "naptable.tests.liveActivity.\(UUID().uuidString)" }

@main
struct NativeLiveActivityChecks {
    @MainActor static func main() async throws {
        let defaults = UserDefaults(suiteName: NextWidgetConfiguration.appGroup)!
        defer { defaults.removePersistentDomain(forName: NextWidgetConfiguration.appGroup) }
        let now = ISO8601DateFormatter().date(from: "2026-09-22T00:00:00Z")!.addingTimeInterval(-1800)  // Tuesday 07:30 Asia/Taipei
        let snapshot = fixture()
        for lead in [15, 30, 60] {
            let result = LiveActivityTimeline.build(snapshot, now: now, lead: lead, perPeriod: false)
            precondition(result.occurrences[0].start - result.occurrences[0].reminder == Double(lead * 60))
        }
        precondition(LiveActivityTimeline.instant(day: "2026-03-08", clock: "02:30", zone: TimeZone(identifier: "America/New_York")!) == nil)
        precondition(LiveActivityTimeline.instant(day: "2026-11-01", clock: "01:30", zone: TimeZone(identifier: "America/New_York")!) == nil)
        precondition(LiveActivityTimeline.build(snapshot, now: now, lead: 30, perPeriod: false).occurrences.map(\.dateKey) == ["2026-09-22"],
                     "Only today and tomorrow are built: the server keeps no more")
        precondition(LiveActivityTimeline.build(snapshot, now: now, lead: 30, perPeriod: false, days: 7).occurrences.map(\.dateKey) == ["2026-09-22", "2026-09-25"])

        // MARK: Settings and consent
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
        precondition(controller.leadMinutes == 30 && controller.sharedLeadMinutes == 30, "The share's lead follows the reader's until set")
        controller.setLeadMinutes(180)
        precondition(controller.leadMinutes == 60)
        controller.setLeadMinutes(30)
        controller.setSharedLeadMinutes(15)
        precondition(controller.leadMinutes == 30 && controller.sharedLeadMinutes == 15)
        var uploads = 0
        controller.planDidChange = { uploads += 1 }
        controller.accept(snapshot)
        await settle()
        precondition(uploads == 1 && live.isEmpty, "Accepting a timetable asks for an upload and reserves nothing by itself")

        // MARK: Rendering by the activity's window
        let display = controller.display!
        let first = display.occurrences[0]
        let start = first.start
        func attributes(id: String = "server-id", scope: String = "scope", reminder: Double? = nil, end: Double? = nil, day: String = "2026-09-22",
                        shared: [ScheduleLiveActivityAttributes.SharedCourse]? = nil) -> ScheduleLiveActivityAttributes {
            .init(semester: "", dateKey: day, protocolVersion: 2, scheduleScope: scope, occurrenceId: id, scheduleVersion: "",
                  reservationStart: Date(timeIntervalSince1970: start), reservationEnd: Date(timeIntervalSince1970: end ?? first.end),
                  reminderDate: Date(timeIntervalSince1970: reminder ?? first.reminder), shared: shared)
        }
        let matching = attributes()
        precondition(display.resolve(attributes: matching, at: now)?.phase == .upcoming, "Any id renders: the window decides")
        let registration = Date(timeIntervalSince1970: first.reminder - 12 * 3600)
        let preregistered = LiveActivityDisplaySnapshot.resolveStored(attributes: matching, at: registration)
        precondition(preregistered?.courseName == "同名课程" && preregistered?.phase == .upcoming && preregistered?.startDate == Date(timeIntervalSince1970: start),
                     "An 08:00 reservation must render its course when prepared the previous evening")
        precondition(display.resolve(attributes: matching, at: Date(timeIntervalSince1970: start))?.phase == .inProgress)
        precondition(display.resolve(attributes: matching, at: Date(timeIntervalSince1970: first.end)) == nil, "A finished window must not revive its initial state")
        precondition(display.resolve(attributes: attributes(scope: "other"), at: now) == nil, "Another table's activity is not this one's")
        precondition(display.resolve(attributes: attributes(day: "2026-09-23"), at: now) == nil)
        let early = display.resolve(attributes: attributes(reminder: first.reminder - 1800), at: Date(timeIntervalSince1970: first.reminder - 900))
        precondition(early?.phase == .upcoming && early?.courseName == "同名课程", "A server reminder ahead of the local one counts down meanwhile")
        precondition(display.nextChange(attributes: matching, after: now) == Date(timeIntervalSince1970: start), "A local update goes stale at the next display change")
        let segmented = LiveActivityTimeline.build(snapshot, now: now, lead: 30, perPeriod: true)
        let segmentedDisplay = LiveActivityDisplaySnapshot(scope: "scope", occurrences: segmented.occurrences)
        precondition(segmentedDisplay.resolve(attributes: matching, at: Date(timeIntervalSince1970: start + 55 * 60))?.phase == .upcoming, "Break stays within one course")
        precondition(segmentedDisplay.resolve(attributes: matching, at: Date(timeIntervalSince1970: start + 70 * 60))?.phase == .inProgress)
        // The phone's copy of a share is older than the server's: the push lists the class itself.
        let moved = ScheduleLiveActivityAttributes.SharedCourse(course: "7", first: 3, last: 3, start: start + 7200, end: start + 10200, name: "高数", teacher: "王", location: "A101")
        let stale = LiveActivityDisplaySnapshot(scope: "share", sourceLabel: "小明", occurrences: [])
        let fromPush = stale.resolve(attributes: attributes(scope: "share", reminder: start + 6300, end: start + 10200, shared: [moved]), at: Date(timeIntervalSince1970: start + 6400))
        precondition(fromPush?.courseName == "高数" && fromPush?.phase == .upcoming && fromPush?.periodLabel == "第 3 节" && fromPush?.sourceLabel == "小明")
        precondition(stale.resolve(attributes: attributes(scope: "share", reminder: start + 6300, end: start + 10200), at: now) == nil)

        // MARK: Conflicts and adjustments
        let conflicted = LiveActivityTimeline.build(fixture(conflict: true), now: now, lead: 30, perPeriod: false, days: 7)
        precondition(conflicted.conflicts.count == 2 && conflicted.occurrences.isEmpty, "Same-name different-source courses require a choice")
        let resolved = LiveActivityTimeline.build(fixture(conflict: true), now: now, lead: 60, perPeriod: false, choices: ["2026-09-22:2": "B", "2026-09-25:2": "B"], days: 7)
        precondition(resolved.occurrences.count == 6, "A-B-A selection splits original course")
        precondition(resolved.occurrences[1].reminder == resolved.occurrences[0].end, "Previous class clips lead time")
        precondition(resolved.occurrences[0].sourceID != resolved.occurrences[1].sourceID)
        let adjusted = LiveActivityTimeline.build(fixture(adjusted: true), now: now, lead: 30, perPeriod: false)
        precondition(adjusted.occurrences.map(\.dateKey) == ["2026-09-23"], "Adjustment expands actual date")

        // MARK: Following a share
        let share = fixture(source: "小明", scope: "share")
        let mineCourse = NativeScheduleCourse(liveActivitySourceID: "M", name: "有机化学", weeks: "1周", weekList: [1], location: "1教105", startSlot: 2, endSlot: 3)
        let wednesdayCourse = NativeScheduleCourse(liveActivitySourceID: "W", name: "物理化学", weeks: "1周", weekList: [1], location: "2教201", startSlot: 1, endSlot: 1)
        let mine = own([NativeScheduleCell(day: 2, bigSlot: 1, courses: [mineCourse]), NativeScheduleCell(day: 3, bigSlot: 1, courses: [wednesdayCourse])], like: share)
        let union = LiveActivityTimeline.build(share, own: mine, now: now, lead: 30, perPeriod: false, days: 7).occurrences
        precondition(union.count == 3, "Tuesday merged, the reader's Wednesday alone, the share's Friday alone")
        let tuesday = union[0]
        precondition(tuesday.start == start && tuesday.end == start + 170 * 60 && tuesday.reminder == start - 1800,
                     "Overlapping courses become one occurrence spanning both")
        func at(_ occurrence: LiveActivityOccurrence, _ minutes: Double) -> ScheduleLiveActivityAttributes.ContentState? {
            occurrence.state(at: Date(timeIntervalSince1970: occurrence.start + minutes * 60))
        }
        precondition(at(tuesday, -10)?.phase == .upcoming && at(tuesday, -10)?.sourceLabel == "小明", "The share's reminder opens the merged activity")
        precondition(at(tuesday, 40)?.sourceLabel == "小明" && at(tuesday, 40)?.companion?.phase == .upcoming && at(tuesday, 40)?.companion?.courseName == "有机化学",
                     "While only the share is in class it leads; the reader's course counts down beside it")
        let both = at(tuesday, 70)
        precondition(both?.courseName == "有机化学" && both?.sourceLabel == nil && both?.companion?.courseName == "同名课程" && both?.companion?.phase == .inProgress,
                     "Both in class: the reader's own course leads, the share's rides along")
        let alone = at(tuesday, 120)
        precondition(alone?.courseName == "有机化学" && alone?.companion == nil && alone?.phase == .inProgress, "After the share's class the reader's course leads alone")
        let wednesday = union[1]
        precondition(wednesday.dateKey == "2026-09-23" && wednesday.start - wednesday.reminder == 1800, "The reader's own course gets its own reminder")
        precondition(at(wednesday, -10)?.courseName == "物理化学" && at(wednesday, -10)?.sourceLabel == nil)
        precondition(union[2].dateKey == "2026-09-25" && union[2].frames.allSatisfy { $0.state.companion == nil })
        // Separate leads: each course reminds by its own table's, the activity opens at the earliest.
        let leads = LiveActivityTimeline.build(share, own: mine, now: now.addingTimeInterval(-3600), lead: 60, sharedLead: 15, perPeriod: false).occurrences[0]
        precondition(leads.reminder == start - 900 && at(leads, -10)?.sourceLabel == "小明", "Their class at 08:00, 15 minutes ahead; mine at 09:00, an hour ahead")
        let longer = LiveActivityTimeline.build(share, own: mine, now: now.addingTimeInterval(-3600), lead: 15, sharedLead: 60, perPeriod: false).occurrences[0]
        precondition(longer.reminder == start - 3600)
        precondition(LiveActivityTimeline.build(snapshot, own: mine, now: now, lead: 30, perPeriod: false)
            .occurrences.allSatisfy { $0.frames.allSatisfy { $0.state.companion == nil } }, "The reader's own table never companions itself")
        // 分节计时 splits the reader's own course exactly like the shared one.
        let pairedCourse = NativeScheduleCourse(liveActivitySourceID: "P", name: "有机化学", weeks: "1周", weekList: [1], location: "1教105", startSlot: 1, endSlot: 2)
        let paired = own([NativeScheduleCell(day: 2, bigSlot: 1, courses: [pairedCourse])], like: share)
        let split = LiveActivityTimeline.build(share, own: paired, now: now, lead: 30, perPeriod: true).occurrences[0]
        let inFirst = split.state(at: Date(timeIntervalSince1970: split.start + 10 * 60))
        precondition(inFirst?.courseName == "有机化学" && inFirst?.endDate == Date(timeIntervalSince1970: split.start + 50 * 60) && inFirst?.companion?.phase == .inProgress,
                     "Per period, the reader's class counts down to the end of the current period")
        let onBreak = split.state(at: Date(timeIntervalSince1970: split.start + 55 * 60))
        precondition(onBreak?.phase == .upcoming && onBreak?.companion?.phase == .upcoming, "Both rows are on break together")
        let wire = try JSONDecoder().decode(ScheduleLiveActivityAttributes.ContentState.self, from: JSONEncoder().encode(onBreak))
        precondition(wire.companion == onBreak?.companion, "Companion phase and origin round-trip")
        let legacy = try JSONDecoder().decode(ScheduleLiveActivityAttributes.ContentState.Companion.self,
            from: Data(#"{"courseName":"旧","startDate":1790000000,"endDate":1790003000}"#.utf8))
        precondition(legacy.phase == .inProgress && legacy.updatedAt == legacy.startDate, "A companion encoded before phases decodes as in class")

        // MARK: What goes to the server
        let body = LiveActivityTimeline.timetable(own: fixture(adjusted: true), share: nil, choices: ["2026-09-22:2": "B"], lead: 30, sharedLead: 15, perPeriod: true)!
        let ownBody = body["own"] as! [String: Any]
        precondition(Set(body.keys) == ["own", "conflicts", "settings"], "Not following: no share")
        precondition(ownBody["scope"] as? String == "scope" && ownBody["schoolID"] as? String == "school" && ownBody["semesterStartMonday"] as? String == "2026-09-21" && ownBody["weekCount"] as? Int == 1)
        precondition((ownBody["periods"] as! [[String: String]])[0] == ["start": "08:00", "end": "08:50"])
        precondition((ownBody["adjustments"] as! [[String: String]]) == [["date": "2026-09-22", "kind": "off"], ["date": "2026-09-23", "kind": "swap", "source": "2026-09-22"]])
        let courses = ownBody["courses"] as! [[String: Any]]
        precondition(courses.count == 2 && courses[0]["id"] as? String == "A" && courses[0]["day"] as? Int == 2 && courses[0]["first"] as? Int == 1
                     && courses[0]["last"] as? Int == 2 && courses[0]["weeks"] as? [Int] == [1])
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        precondition(!encoded.contains("同名课程") && !encoded.contains("teacher") && !encoded.contains("location"), "Names, teachers and rooms never leave the phone")
        precondition(body["settings"] as? [String: AnyHashable] == ["leadMinutes": 30, "perPeriod": true], "The share's lead only matters while following")
        precondition(body["conflicts"] as? [String: String] == ["2026-09-22:2": "B"])
        let following = LiveActivityTimeline.timetable(own: mine, share: share, choices: [:], lead: 30, sharedLead: 15, perPeriod: false)!
        precondition(following["follow"] as? [String: String] == ["share": "SHARE1", "scope": "share"] && (following["own"] as! [String: Any])["scope"] as? String == "own",
                     "The share goes up by its code and the phone's name for it; the timetable is the reader's own")
        precondition((following["settings"] as! [String: AnyHashable])["sharedLeadMinutes"] == AnyHashable(15))
        precondition(LiveActivityTimeline.timetable(own: NativeScheduleSnapshot(scheduleScope: "empty"), share: nil, choices: [:], lead: 30, sharedLead: 30, perPeriod: false) == nil,
                     "No semester, nothing to place courses in")
        let follower = NativeLiveActivityController(now: { now }, privacyDefaults: defaults)
        follower.accept(share, own: mine)
        precondition(follower.following && (follower.timetable()?["own"] as? [String: Any])?["scope"] as? String == "own")

        // MARK: A start from the server
        let start1 = try JSONDecoder().decode(ScheduleLiveActivityAttributes.self, from: Data("""
            {"semester": "", "week": 0, "dateKey": "2026-09-22", "protocolVersion": 2, "scheduleScope": "share", "occurrenceId": "server-id",
             "scheduleVersion": "", "reservationStart": \(start - 978307200), "reservationEnd": \(start + 10200 - 978307200),
             "reminderDate": \(start - 1800 - 978307200), "pushMode": "token",
             "shared": [{"course": "7", "first": 1, "last": 2, "start": \(start), "end": \(start + 6600), "name": "高数", "teacher": "王", "location": "A101"}]}
            """.utf8))
        precondition(start1.shared?.first?.name == "高数" && start1.pushMode == "token" && start1.reservationEnd == Date(timeIntervalSince1970: start + 10200))
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixtureWire = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as! [String: Any]
        for event in ["start", "update", "end"] {
            let aps = (fixtureWire[event] as! [String: Any])["aps"] as! [String: Any]
            let state = try JSONDecoder().decode(ScheduleLiveActivityAttributes.ContentState.self, from: JSONSerialization.data(withJSONObject: aps["content-state"]!))
            precondition(state.broadcastTimestamp!.timeIntervalSince1970 == aps["timestamp"] as! Double)
            if event == "start" {
                let decoded = try JSONDecoder().decode(ScheduleLiveActivityAttributes.self, from: JSONSerialization.data(withJSONObject: aps["attributes"]!))
                precondition(decoded.protocolVersion == 2 && decoded.occurrenceId == "occurrence" && decoded.shared == nil)
            }
        }
        // The system starts it and wakes the app: it renders from the local timetables.
        follower.setEnabled(true)
        var announcements = 0
        follower.activityTokensDidChange = { announcements += 1 }
        let remote = Activity<ScheduleLiveActivityAttributes>.remoteStart(attributes: start1, content: .init(state: tuesday.frames[0].state, staleDate: nil))
        follower.foreground(); await settle()
        precondition(remote.content.state.courseName == "同名课程" && remote.content.staleDate == Date(timeIntervalSince1970: start - 900),
                     "Updated from the local frames (their reminder at 07:45, 15 minutes ahead), stale at the next display change")
        precondition(follower.tokenRegistrations().registrations.isEmpty && follower.tokenRegistrations().live == ["server-id"] && announcements == 1)
        remote.deliverPushToken(Data([0xab, 0xcd, 0x01])); await settle()
        precondition(announcements == 2 && follower.tokenRegistrations().registrations == [.init(occurrenceId: "server-id", token: "abcd01")])
        follower.foreground(); await settle()
        precondition(announcements == 2, "An unchanged rebuild announces nothing")
        follower.accept(fixture(), own: nil); await settle()
        precondition(remote.activityState == .ended && announcements == 3, "Another table ends the share's activity and withdraws its token")

        // MARK: Reservations the server hands over (iOS 26)
        let a = LiveActivityClaim(occurrenceId: "claim-a", dateKey: "2026-09-22", reminder: first.reminder + 600, start: start, end: first.end,
                                  pushMode: "channel", scheduleScope: "scope", scheduleVersion: "v", channel: "two", shared: [])
        let b = LiveActivityClaim(occurrenceId: "claim-b", dateKey: "2026-09-22", reminder: first.reminder + 660, start: start, end: first.end,
                                  pushMode: "token", scheduleScope: "scope", scheduleVersion: "", channel: nil, shared: [])
        var noChannel = a; noChannel.occurrenceId = "claim-c"; noChannel.channel = nil
        var elsewhere = a; elsewhere.occurrenceId = "claim-d"; elsewhere.scheduleScope = "other"
        let released1 = await controller.reserve([a, b, noChannel, elsewhere])
        precondition(released1 == ["claim-c", "claim-d"], "What cannot be reserved goes back")
        precondition(live.count == 2 && controller.reservationCount == 2)
        precondition(live.first { $0.attributes.occurrenceId == "claim-a" }!.pushType == .channel("two") && live.first { $0.attributes.occurrenceId == "claim-b" }!.pushType == .token)
        precondition(live.allSatisfy { $0.activityState == .pending && $0.content.state.courseName == "同名课程" && $0.content.state.phase == .upcoming })
        let reservedA = live.first { $0.attributes.occurrenceId == "claim-a" }!
        precondition(reservedA.attributes == a.attributes(semester: "term"), "Reserved with exactly the attributes the server's own start would carry")
        let released2 = await controller.reserve([a, b])
        precondition(released2.isEmpty && live.count == 2 && live.contains { $0.id == reservedA.id }, "A repeat claim keeps its reservation")
        var later = a; later.reminder += 600
        let released3 = await controller.reserve([later])
        precondition(released3.isEmpty)
        precondition(live.count == 1 && live[0].id != reservedA.id && live[0].attributes.reminderDate == Date(timeIntervalSince1970: later.reminder),
                     "A moved reminder is reserved again; one the server no longer hands out is withdrawn")
        // Capacity: what does not fit goes back to the server.
        TestActivityKit.capacity = live.count + 1
        var c = b; c.occurrenceId = "claim-e"; c.reminder += 120
        let released4 = await controller.reserve([later, b, c])
        precondition(released4 == ["claim-e"])
        guard case .limited = controller.status else { preconditionFailure("A full system shows limited coverage") }
        TestActivityKit.capacity = Int.max
        var past = a; past.occurrenceId = "claim-f"; past.reminder = now.timeIntervalSince1970 - 60
        let released5 = await controller.reserve([later, b, past])
        precondition(released5.isEmpty && !live.contains { $0.attributes.occurrenceId == "claim-f" },
                     "A claim whose reminder passed has nothing left to reserve")
        TestActivityKit.failNextRequest = true
        var failing = a; failing.occurrenceId = "claim-g"
        let released6 = await controller.reserve([later, b, failing])
        precondition(released6 == ["claim-g"])
        guard case .unavailable = controller.status else { preconditionFailure("Other errors remain visible") }

        // MARK: Preview and the switch
        controller.startPreview(); await settle()
        precondition(controller.isPreviewActive && live.count == 1 && live[0].attributes.semester == "__preview__",
                     "Preview waits for reservations to retire before requesting a slot")
        let released7 = await controller.reserve([a])
        precondition(released7.isEmpty && live.count == 1, "No reservation during the preview")
        controller.endPreview(); await settle()
        precondition(live.isEmpty && !controller.isPreviewActive, "The next sync brings the reservations back")
        controller.setEnabled(false); await settle()
        controller.foreground(); await settle()
        precondition(live.isEmpty && !controller.isEnabled, "Foreground must never enable the user's switch")
        follower.setEnabled(false); await settle()
        print("Live Activity v2 Swift checks passed")
    }
    @MainActor static var live: [Activity<ScheduleLiveActivityAttributes>] {
        Activity<ScheduleLiveActivityAttributes>.activities.filter { $0.activityState != .ended && $0.activityState != .dismissed }
    }
    static func settle() async { for _ in 0..<12 { await Task.yield() }; try? await Task.sleep(nanoseconds: 10_000_000) }
    static func own(_ cells: [NativeScheduleCell], like share: NativeScheduleSnapshot) -> NativeScheduleSnapshot {
        NativeScheduleSnapshot(scheduleScope: "own", periods: share.periods, data: NativeScheduleResult(currentSemester: "term", cells: cells),
                               calendar: share.calendar, timeZone: "Asia/Taipei")
    }
    static func fixture(name: String = "同名课程", conflict: Bool = false, adjusted: Bool = false, source: String? = nil, scope: String = "scope") -> NativeScheduleSnapshot {
        let a = NativeScheduleCourse(liveActivitySourceID: "A", name: name, weeks: "1周", weekList: [1], startSlot: 1, endSlot: conflict ? 3 : 2)
        let b = NativeScheduleCourse(liveActivitySourceID: "B", name: name, weeks: "1周", weekList: [1], startSlot: 2, endSlot: 2)
        let periods = [NativeSchedulePeriod(number: 1, startTime: "08:00", endTime: "08:50"), NativeSchedulePeriod(number: 2, startTime: "09:00", endTime: "09:50"), NativeSchedulePeriod(number: 3, startTime: "10:00", endTime: "10:50")]
        return NativeScheduleSnapshot(scheduleScope: scope, periods: periods,
            data: NativeScheduleResult(currentSemester: "term", cells: [NativeScheduleCell(day: 2, bigSlot: 1, courses: conflict ? [a, b] : [a]), NativeScheduleCell(day: 5, bigSlot: 1, courses: conflict ? [a, b] : [a])]),
            calendar: NativeScheduleCalendar(weeks: [NativeCalendarWeek(week: 1, days: ["2026-09-21", "2026-09-22", "2026-09-23", "2026-09-24", "2026-09-25", "2026-09-26", "2026-09-27"])], adjustments: adjusted ? CalendarAdjustmentResolver.index([CalendarAdjustment(date: "2026-09-22", kind: .off, note: "放假"), CalendarAdjustment(date: "2026-09-23", kind: .swap, source: "2026-09-22", note: "调课")], semesterStartMonday: "2026-09-21") : [:]),
            auth: NativeScheduleAuth(authenticated: true, account: source == nil ? nil : "SHARE1"), sourceLabel: source, schoolID: "school", timeZone: "Asia/Taipei")
    }
}
