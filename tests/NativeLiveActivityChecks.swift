import ActivityKit
import Foundation

// Isolated preferences: the checks never touch the installed app's App Group.
enum NextWidgetConfiguration {
    static let appGroup = "cn.cputime.tests.live-activity.\(UUID().uuidString)"
}

@main
struct NativeLiveActivityChecks {
    @MainActor
    static func main() async throws {
        let defaults = UserDefaults(suiteName: NextWidgetConfiguration.appGroup)!
        defer { defaults.removePersistentDomain(forName: NextWidgetConfiguration.appGroup) }
        let start = ISO8601DateFormatter().date(from: "2026-09-16T00:00:00Z")!
        let end = start.addingTimeInterval(45 * 60)
        var clock = start
        let controller = NativeLiveActivityController(now: { clock })
        // 提前量来自设置，默认 1 小时。
        precondition(controller.leadMinutes == NativeLiveActivityController.defaultLeadMinutes)
        precondition(controller.leadTime == 3600, "Default lead time must be one hour")
        let lead = controller.leadTime
        clock = start.addingTimeInterval(-lead - 60)
        let snapshot = fixture()

        // A real authenticated timetable, just outside the lead window.
        controller.accept(snapshot)
        await settle()
        precondition(activeActivities.isEmpty)
        precondition(controller.status == .waiting)

        // The original regression immediately ended this requested activity.
        clock = start.addingTimeInterval(-lead + 60)
        controller.foreground()
        await settle()
        precondition(activeActivities.count == 1, "Upcoming activity must remain active after creation")
        let activity = activeActivities[0]
        precondition(TestActivityKit.events == ["request"], "Creation must not schedule an immediate end or prematurely enter class")
        precondition(activity.content.state.phase == .upcoming)
        precondition(activity.content.staleDate == end)
        precondition(activity.content.state.dateLabel == "周三 · 第 3 周")
        precondition(activity.attributes.week == 3)

        // Snapshot/cache re-delivery must update the same activity.
        controller.accept(snapshot)
        await settle()
        precondition(activeActivities.count == 1 && activeActivities[0].id == activity.id)
        precondition(controller.status == .active)

        // Foreground boundary and resuming after background both reconcile
        // against the clock, instead of waiting for another network fetch.
        clock = start
        controller.foreground()
        await settle()
        precondition(activeActivities[0].content.state.phase == .inProgress)
        precondition(activeActivities[0].content.state.endDate == end)
        precondition(activeActivities[0].id == activity.id)

        clock = end.addingTimeInterval(-1)
        controller.foreground()
        await settle()
        precondition(activeActivities.count == 1, "A class must not end before its actual end time")

        clock = end
        controller.foreground()
        await settle()
        precondition(activeActivities.isEmpty, "An ended class must be dismissed on reconciliation")

        // Transient failure does not permanently prevent a future retry.
        clock = start.addingTimeInterval(60)
        TestActivityKit.failNextRequest = true
        controller.accept(snapshot)
        await settle()
        if case .failed = controller.status {} else { preconditionFailure("Expected request failure") }
        controller.foreground()
        await settle()
        precondition(activeActivities.count == 1, "Foreground retries a previously failed request")
        precondition(activeActivities[0].id != activity.id, "An ended activity must not be reused")

        // A transient request failure must retry even without a foreground
        // notification or a new timetable snapshot.
        controller.reset()
        await settle()
        TestActivityKit.failNextRequest = true
        controller.accept(snapshot)
        await settle()
        if case .failed = controller.status {} else { preconditionFailure("Expected retryable failure") }
        // Allow the system's sleep coalescing tolerance on a busy build host.
        let retryDeadline = Date().addingTimeInterval(40)
        while activeActivities.isEmpty && Date() < retryDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        precondition(activeActivities.count == 1, "The timer must retry a failed request automatically")

        controller.setEnabled(false)
        await settle()
        precondition(activeActivities.isEmpty && controller.status == .disabled)
        controller.setEnabled(true)
        await settle()
        precondition(activeActivities.count == 1)

        // Clearing local data must remove the retained snapshot, including resume.
        controller.reset()
        await settle()
        controller.foreground()
        await settle()
        precondition(activeActivities.isEmpty, "Cleared data must not restart an old class")

        // A system permission change is picked up without refreshing data.
        TestActivityKit.activitiesEnabled = false
        controller.accept(snapshot)
        await settle()
        precondition(activeActivities.isEmpty)
        TestActivityKit.activitiesEnabled = true
        controller.foreground()
        await settle()
        precondition(activeActivities.count == 1)

        controller.accept(fixture(authenticated: false))
        await settle()
        precondition(activeActivities.isEmpty)

        controller.accept(snapshot)
        controller.reset()
        await settle()
        precondition(activeActivities.isEmpty, "A cancelled load cannot create an activity after reset")

        // Exercise the real foreground timer loop, with no new snapshot or
        // foreground notification at either course boundary.
        clock = start.addingTimeInterval(-0.1)
        controller.accept(snapshot)
        await settle()
        precondition(activeActivities[0].content.state.phase == .upcoming)
        clock = start
        try await Task.sleep(for: .milliseconds(1100))
        precondition(activeActivities[0].content.state.phase == .inProgress,
                     "The running loop must transition at class start")
        clock = end.addingTimeInterval(-0.1)
        controller.accept(snapshot)
        await settle()
        clock = end
        try await Task.sleep(for: .milliseconds(1100))
        precondition(activeActivities.isEmpty, "The running loop must dismiss at class end")
        controller.reset()

        // 设置里调大提前量，同一时刻就该放出来；调回来又安静下去。
        controller.reset()
        await settle()
        clock = start.addingTimeInterval(-90 * 60)
        controller.accept(snapshot)
        await settle()
        precondition(activeActivities.isEmpty, "90 minutes out is outside the default one-hour window")
        controller.setLeadMinutes(120)
        await settle()
        precondition(controller.leadTime == 2 * 3600)
        precondition(activeActivities.count == 1, "A larger lead time must open the activity right away")
        controller.setLeadMinutes(NativeLiveActivityController.defaultLeadMinutes)
        await settle()
        precondition(activeActivities.isEmpty, "Going back to one hour closes it again")
        controller.reset()
        await settle()

        // Persistent mode keeps the activity on screen through a break and
        // counts down to today's next class instead of waiting for the lead
        // window.
        controller.reset()
        await settle()
        controller.setPersistent(true)
        let dayFixture = multiCourseFixture()
        let firstEnd = start.addingTimeInterval(45 * 60)
        // 下午那节课：和上午隔了一整个午休，超过提前量，课间才有「安静」可言。
        let secondStart = start.addingTimeInterval(6 * 3600)
        let secondEnd = secondStart.addingTimeInterval(45 * 60)

        // 常驻也要等提前量：今天第一节课还没开始时，早于窗口就不该出现。
        clock = start.addingTimeInterval(-lead - 3600)
        controller.accept(dayFixture)
        await settle()
        precondition(activeActivities.isEmpty && controller.status == .waiting,
                     "Persistent mode still waits for the lead window before the day's first class")

        clock = start.addingTimeInterval(-lead + 60)
        controller.foreground()
        await settle()
        precondition(activeActivities.count == 1, "Persistent mode opens once the first class enters the lead window")
        precondition(activeActivities[0].content.state.phase == .upcoming)
        precondition(activeActivities[0].content.state.startDate == start)

        clock = firstEnd
        controller.foreground()
        await settle()
        // 上午课结束到下午课隔了 5 小时多，远超提前量：常驻模式照样顶着。
        precondition(activeActivities.count == 1, "Persistent mode must survive the break between classes")
        precondition(activeActivities[0].content.state.phase == .upcoming)
        precondition(activeActivities[0].content.state.startDate == secondStart,
                     "A break must count down to today's next class")

        clock = secondEnd
        controller.foreground()
        await settle()
        precondition(activeActivities.isEmpty, "Persistent mode dismisses once today has no class left")

        // The same break stays quiet when the activity is not persistent.
        controller.setPersistent(false)
        clock = firstEnd
        controller.accept(dayFixture)
        await settle()
        precondition(activeActivities.isEmpty && controller.status == .waiting)
        clock = secondStart.addingTimeInterval(-lead + 60)
        controller.foreground()
        await settle()
        precondition(activeActivities.count == 1 && activeActivities[0].content.state.startDate == secondStart,
                     "The lead window still reopens the activity without persistence")
        controller.reset()
        await settle()

        // iOS suspends the app between classes, so the boundary work has to be
        // reachable from a background launch that holds no timetable.
        controller.reset()
        await settle()
        controller.setPersistent(false)
        var wakeups: [Date] = []
        controller.scheduleBackgroundWakeup = { wakeups.append($0) }
        clock = start
        controller.accept(dayFixture)
        await settle()
        precondition(activeActivities.count == 1 && activeActivities[0].content.state.phase == .inProgress)
        precondition(wakeups.last == firstEnd, "The app must ask to be woken at the class boundary")

        clock = firstEnd
        await NativeLiveActivityController(now: { clock }).reconcileInBackground()
        await settle()
        precondition(activeActivities.isEmpty, "A finished class must be dismissed without opening the app")

        // The same launch advances a persistent activity to today's next class.
        controller.reset()
        await settle()
        controller.setPersistent(true)
        clock = start
        controller.accept(dayFixture)
        await settle()
        let persistentID = activeActivities[0].id
        clock = firstEnd
        await NativeLiveActivityController(now: { clock }).reconcileInBackground()
        await settle()
        precondition(activeActivities.count == 1 && activeActivities[0].id == persistentID,
                     "Persistent mode keeps one activity across the break")
        precondition(activeActivities[0].content.state.phase == .upcoming)
        precondition(activeActivities[0].content.state.startDate == secondStart)
        precondition(activeActivities[0].content.state.courseName == "有机化学")

        clock = secondEnd
        await NativeLiveActivityController(now: { clock }).reconcileInBackground()
        await settle()
        precondition(activeActivities.isEmpty, "Today's last class is dismissed in the background too")

        // A class that starts while the app is suspended still switches phase.
        controller.setPersistent(false)
        controller.reset()
        await settle()
        clock = start.addingTimeInterval(-10 * 60)
        controller.accept(dayFixture)
        await settle()
        precondition(activeActivities[0].content.state.phase == .upcoming)
        clock = start
        await NativeLiveActivityController(now: { clock }).reconcileInBackground()
        await settle()
        precondition(activeActivities[0].content.state.phase == .inProgress,
                     "A class starting while suspended must enter its in-progress phase")
        controller.reset()
        await settle()

        // Preview uses separate content and must be cancelled by data reset.
        controller.startPreview()
        await settle()
        precondition(controller.isPreviewActive && activeActivities.count == 1)
        precondition(activeActivities[0].attributes.semester == "__preview__")
        controller.reset()
        await settle()
        controller.foreground()
        await settle()
        precondition(!controller.isPreviewActive && activeActivities.isEmpty)

        controller.startPreview()
        controller.setEnabled(false)
        await settle()
        precondition(activeActivities.isEmpty, "A cancelled preview cannot recreate an activity")

        // Two activities for the same class -- one started locally, one by a
        // push that landed while the app was awake -- must not both stay up.
        controller.setEnabled(true)
        controller.reset()
        await settle()
        clock = start
        controller.accept(fixture())
        await settle()
        precondition(activeActivities.count == 1)
        let pushed = try Activity<ScheduleLiveActivityAttributes>.request(
            attributes: ScheduleLiveActivityAttributes(semester: "2026-2027-1", dateKey: "2026-09-16", week: 3),
            content: ActivityContent(state: activeActivities[0].content.state, staleDate: end),
            pushType: .token
        )
        precondition(activeActivities.count == 2, "The fixture allows the overlap the dedupe has to clean up")
        controller.dropDuplicates(keeping: pushed)
        await settle()
        precondition(activeActivities.count == 1 && activeActivities[0].id == pushed.id,
                     "The activity that arrived last is the one that stays")
        controller.reset()
        await settle()

        // MARK: 推送计划
        //
        // The plan is what a server replays while the app is suspended, so it
        // has to describe the same frames the refresh loop would have drawn.
        controller.setEnabled(true)
        controller.setPersistent(false)
        controller.setLeadMinutes(60)
        controller.reset()
        await settle()
        let planClock = ISO8601DateFormatter().date(from: "2026-09-16T00:00:00+08:00")!
        let multi = multiCourseFixture()
        let plan = controller.pushPlan(from: multi, now: planClock)
        precondition(plan.map(\.event.rawValue) == ["start", "update", "end", "start", "update", "end", "start", "update", "end"],
                     "Every class gets its own run when the break is longer than the lead window")
        precondition(Set(plan.map(\.id)).count == plan.count, "Plan item ids must be unique")
        precondition(plan.allSatisfy { $0.fireAt > planClock }, "A plan never contains a push that is already due")

        let firstStart = plan[0]
        let classStart = ISO8601DateFormatter().date(from: "2026-09-16T08:00:00+08:00")!
        let classEnd = ISO8601DateFormatter().date(from: "2026-09-16T08:45:00+08:00")!
        precondition(firstStart.fireAt == classStart.addingTimeInterval(-3600), "The run opens one lead window early")
        precondition(firstStart.state.phase == .upcoming && firstStart.state.courseName == "药理学实验")
        precondition(firstStart.state.nextCourseName == "有机化学", "A planned frame carries the following course too")
        precondition(firstStart.expiresAt == classStart, "An upcoming frame stops being true when the class starts")
        precondition(firstStart.staleDate == classEnd)
        precondition(firstStart.attributes.dateKey == "2026-09-16")
        precondition(plan[1].fireAt == classStart && plan[1].state.phase == .inProgress)
        precondition(plan[2].fireAt == classEnd, "The activity is dismissed as the class ends")
        precondition(plan[2].expiresAt > classEnd, "A dismissal is still worth sending a little late")

        // Persistent mode carries one activity across the break, so the second
        // class of the day is an update rather than a second start.
        controller.setPersistent(true)
        let persistentPlan = controller.pushPlan(from: multi, now: planClock)
        precondition(persistentPlan.map(\.event.rawValue) == ["start", "update", "update", "update", "end", "start", "update", "end"],
                     "Persistent mode keeps today on one activity and still breaks at the day boundary")
        precondition(persistentPlan[2].fireAt == classEnd, "The break frame begins the moment the class ends")
        precondition(persistentPlan[2].state.courseName == "有机化学" && persistentPlan[2].state.phase == .upcoming)
        precondition(persistentPlan[5].attributes.dateKey == "2026-09-17", "Tomorrow is a new activity")
        controller.setPersistent(false)

        // Frames already under way are the running app's business.
        let midday = ISO8601DateFormatter().date(from: "2026-09-16T08:20:00+08:00")!
        let latePlan = controller.pushPlan(from: multi, now: midday)
        precondition(latePlan.map(\.event.rawValue) == ["end", "start", "update", "end", "start", "update", "end"],
                     "A run already on screen keeps only the pushes still ahead of it")

        precondition(controller.pushPlan(from: fixture(authenticated: false), now: planClock).isEmpty,
                     "No timetable, no plan")
        controller.setEnabled(false)
        precondition(controller.pushPlan(from: multi, now: planClock).isEmpty, "A disabled activity plans nothing")
        controller.setEnabled(true)

        // The push carries `content-state` as JSON that ActivityKit decodes on
        // its own terms, so the instants have to be plain Unix seconds.
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(firstStart.state)) as! [String: Any]
        precondition(encoded["startDate"] as? Double == classStart.timeIntervalSince1970,
                     "Dates are coded as Unix seconds, not against the 2001 reference date")
        precondition(encoded["phase"] as? String == "upcoming")
        let decoded = try JSONDecoder().decode(
            ScheduleLiveActivityAttributes.ContentState.self,
            from: JSONEncoder().encode(firstStart.state)
        )
        precondition(decoded == firstStart.state, "Content state must round trip through its own wire format")

        // 调休：放假那天一条都不推，补课那天推的是被调走那天的课，并且带上说明。
        let adjusted = adjustedFixture()
        let adjustedPlan = controller.pushPlan(from: adjusted, now: planClock)
        let holidayKey = "2026-09-16"
        precondition(adjustedPlan.allSatisfy { $0.attributes.dateKey != holidayKey },
                     "A holiday must not keep a single push on the plan")
        let makeUp = adjustedPlan.filter { $0.attributes.dateKey == "2026-09-19" }
        precondition(!makeUp.isEmpty, "The make-up day runs the classes that were moved off the holiday")
        precondition(makeUp.contains { $0.state.courseName == "药理学实验" },
                     "The make-up day shows the moved day's courses")
        precondition(makeUp.allSatisfy { ($0.state.normalizedAdjustmentNote ?? "").isEmpty == false },
                     "Every make-up frame says which day's classes it is showing")
        precondition(adjustedPlan.first { $0.attributes.dateKey == "2026-09-17" }?
                        .state.normalizedAdjustmentNote == nil,
                     "An ordinary day carries no adjustment note")

        // A school channel continues sending boundaries after our last class.
        // Tomorrow's scheduled activity must not keep today's empty one alive.
        controller.end()
        await settle()
        defaults.set(true, forKey: NativeLiveActivityController.enabledKey)
        clock = start
        controller.broadcastDayChannels = ["2026-09-16": "school-16", "2026-09-17": "school-17"]
        await settle()
        controller.accept(multiCourseFixture())
        await settle()
        precondition(activeActivities.contains { $0.attributes.dateKey == "2026-09-16" })
        precondition(activeActivities.contains { $0.attributes.dateKey == "2026-09-17" })
        clock = start.addingTimeInterval(8 * 3600)
        controller.foreground()
        await settle()
        precondition(!activeActivities.contains { $0.attributes.dateKey == "2026-09-16" }, "Finished day must be dismissed even with tomorrow scheduled")
        precondition(activeActivities.contains { $0.attributes.dateKey == "2026-09-17" }, "Tomorrow's activity must survive cleanup")
        controller.end()
        await settle()

        print("Live Activity checks passed: lead window, lead setting, create, cache update, start, end, retry, settings, permission, persistence, background reconcile, reset, preview, push plan, scheduled cleanup and 调休")
    }

    @MainActor
    private static var activeActivities: [Activity<ScheduleLiveActivityAttributes>] {
        Activity<ScheduleLiveActivityAttributes>.activities.filter {
            $0.activityState == .active || $0.activityState == .stale
        }
    }

    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(20))
    }

    /// Two classes on the same day plus one the next day, so a break and the
    /// end of the school day are both observable.
    private static func multiCourseFixture() -> NativeScheduleSnapshot {
        NativeScheduleSnapshot(
            completeSemester: true,
            source: .cache,
            periods: [
                NativeSchedulePeriod(number: 1, startTime: "08:00", endTime: "08:45"),
                NativeSchedulePeriod(number: 3, startTime: "14:00", endTime: "14:45"),
            ],
            data: NativeScheduleResult(
                currentSemester: "2026-2027-1", currentWeek: "3",
                cells: [
                    NativeScheduleCell(day: 3, bigSlot: 1, courses: [
                        NativeScheduleCourse(name: "药理学实验", teacher: "李老师", weeks: "3周", weekList: [3], location: "药学楼 302", startSlot: 1, endSlot: 1),
                    ]),
                    NativeScheduleCell(day: 3, bigSlot: 2, courses: [
                        NativeScheduleCourse(name: "有机化学", teacher: "王老师", weeks: "3周", weekList: [3], location: "教学楼 101", startSlot: 3, endSlot: 3),
                    ]),
                    NativeScheduleCell(day: 4, bigSlot: 1, courses: [
                        NativeScheduleCourse(name: "生理学", teacher: "张老师", weeks: "3周", weekList: [3], location: "教学楼 205", startSlot: 1, endSlot: 1),
                    ]),
                ]
            ),
            calendar: NativeScheduleCalendar(
                currentSemester: "2026-2027-1", currentWeek: 3,
                weeks: [NativeCalendarWeek(week: 3, days: ["2026-09-14", "2026-09-15", "2026-09-16", "2026-09-17", "2026-09-18", "2026-09-19", "2026-09-20"])]
            ),
            auth: NativeScheduleAuth(authenticated: true)
        )
    }

    /// 周三放假，周六补这天的课：计划必须跟着挪，而且说清楚挪的是哪天。
    private static func adjustedFixture() -> NativeScheduleSnapshot {
        let base = multiCourseFixture()
        let adjustments = CalendarAdjustmentResolver.index(
            [
                CalendarAdjustment(date: "2026-09-16", kind: .off, source: nil, note: "国庆节"),
                CalendarAdjustment(date: "2026-09-19", kind: .swap, source: "2026-09-16", note: ""),
            ],
            semesterStartMonday: "2026-08-31"
        )
        return NativeScheduleSnapshot(
            completeSemester: true,
            source: .cache,
            periods: base.periods,
            data: base.data,
            calendar: NativeScheduleCalendar(
                currentSemester: "2026-2027-1", currentWeek: 3,
                weeks: base.calendar?.weeks ?? [],
                adjustments: adjustments
            ),
            auth: NativeScheduleAuth(authenticated: true)
        )
    }

    private static func fixture(authenticated: Bool = true) -> NativeScheduleSnapshot {
        NativeScheduleSnapshot(
            completeSemester: true,
            source: .cache,
            periods: [NativeSchedulePeriod(number: 1, startTime: "08:00", endTime: "08:45")],
            data: NativeScheduleResult(
                currentSemester: "2026-2027-1", currentWeek: "3",
                cells: [NativeScheduleCell(day: 3, bigSlot: 1, courses: [
                    NativeScheduleCourse(name: "药理学实验", teacher: "李老师", weeks: "3周", weekList: [3], location: "药学楼 302", startSlot: 1, endSlot: 1),
                ])]
            ),
            calendar: NativeScheduleCalendar(
                currentSemester: "2026-2027-1", currentWeek: 3,
                weeks: [NativeCalendarWeek(week: 3, days: ["2026-09-14", "2026-09-15", "2026-09-16", "2026-09-17", "2026-09-18", "2026-09-19", "2026-09-20"])]
            ),
            auth: NativeScheduleAuth(authenticated: authenticated)
        )
    }
}
