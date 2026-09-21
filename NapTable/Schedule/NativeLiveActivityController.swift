#if os(iOS) || LIVE_ACTIVITY_CHECKS
import ActivityKit
import Combine
import Foundation

/// Keeps one schedule Live Activity in sync with the currently visible native
/// timetable. The widget renders the countdown locally, while this controller
/// only needs to refresh when the course crosses a boundary or the schedule
/// changes.
@available(iOS 17.0, *)
@MainActor
final class NativeLiveActivityController: ObservableObject {
    enum Status: Equatable {
        case disabled
        case waiting
        case active
        case unavailable(String)
        case failed(String)

        var title: String {
            switch self {
            case .disabled: return "已关闭"
            case .waiting: return "等待下一节课"
            case .active: return "实时活动已显示"
            case .unavailable: return "暂时没有可显示的课程"
            case .failed: return "启动失败"
            }
        }

        var detail: String? {
            switch self {
            case .unavailable(let message), .failed(let message): return message
            default: return nil
            }
        }
    }

    static let shared = NativeLiveActivityController()
    static let enabledKey = "scheduleLiveActivityEnabled"
    /// When set, the activity stays on screen for the whole school day and
    /// counts down to the next class during breaks. Otherwise it is dismissed
    /// as soon as a class ends and returns inside the lead window.
    static let persistentKey = "scheduleLiveActivityPersistent"
    /// 提前量：下一节课还有多久时才把实时活动放出来。设置页可调，存在 App Group 里。
    static let leadMinutesKey = "scheduleLiveActivityLeadMinutes"
    /// 一小时覆盖「下一节课在哪」，再远就交给小组件。
    static let defaultLeadMinutes = 60
    static let leadMinuteOptions = [15, 30, 60, 120, 180]

    /// 设置里选的提前量。越界或没设过都退回默认值。
    var leadMinutes: Int {
        let stored = UserDefaults(suiteName: NextWidgetConfiguration.appGroup)?
            .object(forKey: Self.leadMinutesKey) as? Int
        guard let stored, Self.leadMinuteOptions.contains(stored) else { return Self.defaultLeadMinutes }
        return stored
    }

    var leadTime: TimeInterval { TimeInterval(leadMinutes * 60) }

    func setLeadMinutes(_ minutes: Int) {
        let value = Self.leadMinuteOptions.contains(minutes) ? minutes : Self.defaultLeadMinutes
        UserDefaults(suiteName: NextWidgetConfiguration.appGroup)?.set(value, forKey: Self.leadMinutesKey)
        guard isEnabled, !isPreviewActive else { return }
        if let lastSnapshot {
            accept(lastSnapshot)
        } else {
            status = .waiting
        }
    }

    @Published private(set) var status: Status = .waiting
    @Published private(set) var isPreviewActive = false

    /// Set by the app so the controller can ask the system for background
    /// execution at the next course boundary. iOS suspends the app between
    /// classes, so without this a finished class would stay on the Lock Screen
    /// until the app is opened again.
    var scheduleBackgroundWakeup: ((Date) -> Void)?

    /// Set by `LiveActivityPushService` when server push is on. A locally
    /// created activity is only push-updatable if it was requested with a
    /// token, so the flag has to be in place before the next `request`.
    var wantsPushToken = false
    var broadcastDayChannels: [String: String] = [:] {
        didSet {
            if oldValue != broadcastDayChannels, let snapshot = lastSnapshot { accept(snapshot) }
        }
    }

    /// The APNs channel assigned to the selected school. iOS 26 uses this for
    /// scheduled activities; older systems keep using the device-token path.
    var broadcastChannelID: String? {
        didSet {
            guard oldValue != broadcastChannelID,
                  let snapshot = lastSnapshot,
                  !isPreviewActive else { return }
            refreshTask?.cancel()
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.endActivities()
                guard self.isEnabled, !self.isPreviewActive else { return }
                self.accept(snapshot)
            }
        }
    }

    var currentScheduleMetadata: NativeScheduleSnapshot? { lastSnapshot }

    /// Called with a freshly rendered plan whenever the timetable or the
    /// activity settings change. The push service uploads it; nothing else
    /// observes it.
    var planDidChange: (([PlannedPush]) -> Void)?

    private var refreshTask: Task<Void, Never>?
    private var previewEndTask: Task<Void, Never>?
    private var lastSnapshot: NativeScheduleSnapshot?
    private let now: () -> Date
    private var currentActivity: Activity<ScheduleLiveActivityAttributes>? {
        Activity<ScheduleLiveActivityAttributes>.activities.first {
            $0.activityState == .active || $0.activityState == .stale
        }
    }

    private var anyActivity: Activity<ScheduleLiveActivityAttributes>? {
        Activity<ScheduleLiveActivityAttributes>.activities.first
    }

    init(now: @escaping () -> Date = { .now }) {
        self.now = now
        if !isEnabled {
            status = .disabled
        } else if !ActivityAuthorizationInfo().areActivitiesEnabled {
            status = .unavailable("请在系统设置中允许“实时活动”。")
        } else if currentActivity != nil {
            status = .active
        }
    }

    var isEnabled: Bool {
        UserDefaults(suiteName: NextWidgetConfiguration.appGroup)?
            .object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults(suiteName: NextWidgetConfiguration.appGroup)?.set(enabled, forKey: Self.enabledKey)
        // Server push has no switch of its own: registering here is what lets
        // the activity appear while the app is suspended.
        #if os(iOS)
        if #available(iOS 17.2, *) { LiveActivityPushService.shared.enabledDidChange(enabled) }
        #endif
        if enabled, let lastSnapshot {
            status = .waiting
            accept(lastSnapshot)
        } else if !enabled {
            status = .disabled
            end()
        } else {
            status = .waiting
        }
    }

    /// Whether the activity remains on screen between today's classes.
    var isPersistent: Bool {
        UserDefaults(suiteName: NextWidgetConfiguration.appGroup)?
            .object(forKey: Self.persistentKey) as? Bool ?? false
    }

    func setPersistent(_ persistent: Bool) {
        UserDefaults(suiteName: NextWidgetConfiguration.appGroup)?.set(persistent, forKey: Self.persistentKey)
        guard isEnabled, !isPreviewActive else { return }
        if let lastSnapshot {
            accept(lastSnapshot)
        } else {
            status = .waiting
        }
    }

    func refreshForThemeChange() {
        if isPreviewActive {
            endPreview()
            startPreview()
            return
        }
        guard let lastSnapshot else { return }
        accept(lastSnapshot)
    }

    func accept(_ snapshot: NativeScheduleSnapshot) {
        lastSnapshot = snapshot
        if isPreviewActive { return }
        // Rendering a week of frames is only worth it when someone is
        // listening; without server push nothing observes the plan.
        if let planDidChange { planDidChange(pushPlan(from: snapshot)) }
        refreshTask?.cancel()
        guard isEnabled else {
            status = .disabled
            end()
            return
        }
        status = currentActivity == nil ? .waiting : .active
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let delay = await self.synchronize(snapshot) else { return }
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
            }
        }
    }

    /// A push-to-start and the in-app refresh loop can both create an activity
    /// for the same class -- the app is not always suspended when a push
    /// lands. iOS shows every one of them, so keep the activity that just
    /// appeared and dismiss whatever it superseded.
    func dropDuplicates(keeping activity: Activity<ScheduleLiveActivityAttributes>) {
        let others = Activity<ScheduleLiveActivityAttributes>.activities.filter {
            $0.id != activity.id && ($0.activityState == .active || $0.activityState == .stale)
        }
        guard !others.isEmpty else { return }
        Task { @MainActor in
            for other in others {
                await other.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// Re-render and hand out the plan without disturbing the live activity.
    /// Used when the push feature is switched on, or a device token arrives.
    func replanForPush() {
        guard let lastSnapshot else { return }
        planDidChange?(pushPlan(from: lastSnapshot))
    }

    /// Reconcile boundaries and permission changes after app suspension.
    func foreground() {
        if isPreviewActive {
            if (currentActivity?.content.state.endDate ?? .distantPast) <= now() {
                endPreview()
            }
        } else if let lastSnapshot {
            accept(lastSnapshot)
        }
    }

    /// Discard the retained timetable when local data is cleared.
    func reset() {
        lastSnapshot = nil
        end()
        status = isEnabled ? .waiting : .disabled
    }

    /// Starts a local, self-contained activity so users can inspect the lock
    /// screen and Dynamic Island layout without waiting for a real class.
    func startPreview() {
        guard isEnabled else {
            status = .disabled
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            status = .unavailable("请在系统设置中允许“实时活动”。")
            return
        }

        refreshTask?.cancel()
        refreshTask = nil
        previewEndTask?.cancel()
        previewEndTask = nil
        isPreviewActive = true
        status = .waiting

        let start = now().addingTimeInterval(-20 * 60)
        let end = now().addingTimeInterval(55 * 60)
        let state = ScheduleLiveActivityAttributes.ContentState(
            phase: .inProgress,
            courseName: "演示课程 · 实验课",
            teacher: "李老师",
            location: "药学楼 302",
            periodLabel: "第 3-4 节",
            dateLabel: "今天 · 演示",
            weekRangeLabel: "第 3 周",
            startDate: start,
            endDate: end,
            nextCourseName: "演示课程 · 理论课",
            nextCoursePeriod: "第 6 节",
            nextCourseDateLabel: "今天",
            nextCourseWeekRangeLabel: "第 3 周",
            nextCourseTeacher: "王老师",
            nextCourseLocation: "教学楼 101",
            nextCourseStart: end.addingTimeInterval(40 * 60),
            nextCourseEnd: end.addingTimeInterval(130 * 60),
            updatedAt: .now
        )
        let attributes = ScheduleLiveActivityAttributes(
            semester: "__preview__",
            dateKey: "preview",
            week: 0
        )
        let content = ActivityContent(state: state, staleDate: end)

        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await endActivities()
            guard !Task.isCancelled, isPreviewActive, isEnabled else { return }
            do {
                _ = try Activity<ScheduleLiveActivityAttributes>.request(
                    attributes: attributes,
                    content: content,
                    pushType: nil
                )
                status = .active
                previewEndTask = Task { @MainActor [weak self] in
                    let seconds = max(1, end.timeIntervalSinceNow)
                    do {
                        try await Task.sleep(for: .seconds(seconds))
                    } catch {
                        return
                    }
                    guard let self, self.isPreviewActive else { return }
                    self.endPreview()
                }
            } catch {
                isPreviewActive = false
                status = .failed(error.localizedDescription)
            }
        }
    }

    func endPreview() {
        guard isPreviewActive else { return }
        previewEndTask?.cancel()
        previewEndTask = nil
        isPreviewActive = false
        end()
        if isEnabled, let lastSnapshot {
            accept(lastSnapshot)
        } else if isEnabled {
            status = .waiting
        }
    }

    func end() {
        refreshTask?.cancel()
        refreshTask = nil
        previewEndTask?.cancel()
        previewEndTask = nil
        isPreviewActive = false
        if !isEnabled { status = .disabled }
        let activities = Activity<ScheduleLiveActivityAttributes>.activities
        guard !activities.isEmpty else { return }
        Task { @MainActor in
            for activity in activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// Entry point for the background task that runs at a course boundary.
    /// Returns once the activity matches the clock again.
    func reconcileInBackground() async {
        guard !isPreviewActive else { return }
        guard isEnabled else {
            await endActivities()
            status = .disabled
            return
        }
        if let lastSnapshot {
            _ = await synchronize(lastSnapshot)
            return
        }
        await reconcileFromActivityState()
    }

    /// A background launch starts with no timetable in memory. The activity's
    /// own content still carries this class's boundaries and the next course,
    /// which is enough to advance or dismiss it. Starting a new activity needs
    /// the foreground, so a dismissed activity waits for the app.
    private func reconcileFromActivityState() async {
        guard let activity = currentActivity else { return }
        let state = activity.content.state
        let currentDate = now()
        if state.phase == .upcoming, currentDate >= state.startDate, currentDate < state.endDate {
            let running = Self.contentState(from: state, phase: .inProgress, updatedAt: state.startDate)
            await activity.update(ActivityContent(state: running, staleDate: state.endDate))
            status = .active
            scheduleBackgroundWakeup?(state.endDate)
            return
        }
        guard currentDate >= state.endDate else { return }

        // The class is over. Persistent mode carries the activity to today's
        // next course; otherwise it is dismissed right here.
        guard isPersistent,
              let next = state.afterEndState,
              next.endDate > currentDate else {
            await endActivities()
            status = .waiting
            return
        }
        let inProgress = currentDate >= next.startDate
        let advanced = inProgress
            ? Self.contentState(from: next, phase: .inProgress, updatedAt: next.startDate)
            : next
        await activity.update(ActivityContent(state: advanced, staleDate: next.endDate))
        status = .active
        scheduleBackgroundWakeup?(inProgress ? next.endDate : next.startDate)
    }

    /// Same course, new phase: only the countdown anchor changes.
    private static func contentState(
        from state: ScheduleLiveActivityAttributes.ContentState,
        phase: ScheduleLiveActivityAttributes.ContentState.Phase,
        updatedAt: Date
    ) -> ScheduleLiveActivityAttributes.ContentState {
        ScheduleLiveActivityAttributes.ContentState(
            phase: phase,
            courseName: state.courseName,
            teacher: state.teacher,
            location: state.location,
            periodLabel: state.periodLabel,
            dateLabel: state.dateLabel,
            weekRangeLabel: state.weekRangeLabel,
            startDate: state.startDate,
            endDate: state.endDate,
            nextCourseName: state.nextCourseName,
            nextCoursePeriod: state.nextCoursePeriod,
            nextCourseDateLabel: state.nextCourseDateLabel,
            nextCourseWeekRangeLabel: state.nextCourseWeekRangeLabel,
            nextCourseTeacher: state.nextCourseTeacher,
            nextCourseLocation: state.nextCourseLocation,
            nextCourseStart: state.nextCourseStart,
            nextCourseEnd: state.nextCourseEnd,
            sourceLabel: state.sourceLabel,
            adjustmentNote: state.adjustmentNote,
            updatedAt: updatedAt
        )
    }

    private func synchronize(_ snapshot: NativeScheduleSnapshot) async -> TimeInterval? {
        guard !Task.isCancelled, !isPreviewActive, isEnabled else { return nil }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            status = .unavailable("请在系统设置中允许“实时活动”。")
            await endActivities()
            return nil
        }
        guard snapshot.auth.authenticated else {
            status = .unavailable("先在设置里导入或新建一张课表。")
            await endActivities()
            return nil
        }
        if #available(iOS 26.0, *), !broadcastDayChannels.isEmpty {
            return await synchronizeScheduled(snapshot, channelID: "")
        }
        let currentDate = now()
        guard let occurrence = nextOccurrence(in: snapshot, now: currentDate) else {
            status = .unavailable("今天和接下来没有可显示的课程。")
            await endActivities()
            return nil
        }

        if !occurrence.isInProgress {
            if isPersistent {
                // Stay on screen through breaks, counting down to the next
                // class, but only while that class is still part of today.
                if occurrence.dateKey != Self.dayKey(for: currentDate) {
                    status = .unavailable("今日无课。")
                    await endActivities()
                    return refreshDelay(for: occurrence)
                }
                // 常驻说的是「课间不收起」，不是「一整天都挂着」：今天第一节课
                // 还没开始时，照样等它进入提前量再出现，否则早上一睁眼就能看到
                // 晚上的课。
                if let firstStart = firstStart(of: currentDate, in: snapshot),
                   currentDate < firstStart,
                   occurrence.start.timeIntervalSince(currentDate) > leadTime {
                    status = .waiting
                    await endActivities()
                    return refreshDelay(for: occurrence)
                }
            } else if occurrence.dateKey != Self.dayKey(for: currentDate) {
                // 只显示今天的课：今天上完就报「今日无课」，明天的课交给小组件。
                status = .unavailable("今日无课。")
                await endActivities()
                return refreshDelay(for: occurrence)
            } else if occurrence.start.timeIntervalSince(currentDate) > leadTime {
                // Keep the island quiet while the next class is still far away.
                // The refresh loop stays alive so it can start automatically as
                // the class enters the lead window.
                status = .waiting
                await endActivities()
                return refreshDelay(for: occurrence)
            }
        }

        let attributes = Self.attributes(for: occurrence, in: snapshot)
        let state = Self.contentState(
            for: occurrence,
            phase: occurrence.isInProgress ? .inProgress : .upcoming,
            sourceLabel: snapshot.sourceLabel,
            updatedAt: occurrence.isInProgress ? occurrence.start : currentDate
        )
        // The system should consider the activity stale as soon as this
        // occurrence ends. The controller wakes at the same boundary and
        // either advances to a nearby class or dismisses the activity.
        let content = ActivityContent(state: state, staleDate: occurrence.end)

        if let activity = currentActivity,
           activity.attributes == attributes {
            await activity.update(content)
            guard !Task.isCancelled else { return nil }
            status = .active
            scheduleBackgroundWakeup?(occurrence.isInProgress ? occurrence.end : occurrence.start)
            return refreshDelay(for: occurrence)
        }
        await endActivities()
        guard !Task.isCancelled, isEnabled, !isPreviewActive else { return nil }
        do {
            _ = try Activity<ScheduleLiveActivityAttributes>.request(
                attributes: attributes,
                content: content,
                pushType: wantsPushToken ? .token : nil
            )
            status = .active
            scheduleBackgroundWakeup?(occurrence.isInProgress ? occurrence.end : occurrence.start)
            return refreshDelay(for: occurrence)
        } catch {
            status = .failed(error.localizedDescription)
            // Retry transient failures while the app can execute.
            return 30
        }
    }

    /// iOS 26 can schedule the activity itself. The activity starts locally at
    /// the first class of a day, while the school channel only carries compact
    /// boundary markers afterwards. No course text is sent through APNs.
    @available(iOS 26.0, *)
    private func synchronizeScheduled(_ snapshot: NativeScheduleSnapshot, channelID: String) async -> TimeInterval? {
        let currentDate = now()
        let events = occurrences(in: snapshot)
            .filter { $0.end > currentDate && $0.start < currentDate.addingTimeInterval(2 * 24 * 3600) }
            .sorted { $0.start < $1.start }
        guard !events.isEmpty else {
            status = .unavailable("今天和明天没有可显示的课程。")
            await endActivities()
            return nil
        }

        let reservations = events.compactMap { event -> (Occurrence, ScheduleLiveActivityAttributes, String)? in
            guard let channel = broadcastDayChannels[event.dateKey] else { return nil }
            let attributes = ScheduleLiveActivityAttributes(
                semester: snapshot.data?.currentSemester ?? "", dateKey: event.dateKey, week: event.week,
                reservationStart: event.start, reservationEnd: event.end, broadcastChannel: channel,
                reminderDate: event.start.addingTimeInterval(-leadTime))
            return (event, attributes, channel)
        }
        for activity in Activity<ScheduleLiveActivityAttributes>.activities {
            if !reservations.contains(where: { $0.1 == activity.attributes }) {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        for (first, attributes, channelID) in reservations {
            guard !Task.isCancelled, isEnabled, !isPreviewActive else { return nil }
            let exists = Activity<ScheduleLiveActivityAttributes>.activities.contains {
                $0.attributes == attributes && $0.activityState != .ended && $0.activityState != .dismissed
            }
            if exists { continue }

            let start = max(first.start.addingTimeInterval(-leadTime), currentDate.addingTimeInterval(1))
            guard first.end.timeIntervalSince(start) < 8 * 3600 else {
                status = .failed("课程及提前提醒超过实时活动的 8 小时上限。")
                return nil
            }
            let initial = Self.contentState(
                for: first,
                phase: first.start <= currentDate ? .inProgress : .upcoming,
                sourceLabel: snapshot.sourceLabel,
                updatedAt: first.start <= currentDate ? first.start : currentDate
            )
            let alert = AlertConfiguration(
                title: "课程提醒",
                body: LocalizedStringResource(stringLiteral: first.name),
                sound: .default
            )
            do {
                _ = try Activity<ScheduleLiveActivityAttributes>.request(
                    attributes: attributes,
                    content: ActivityContent(state: initial, staleDate: first.end),
                    pushType: .channel(channelID),
                    style: .standard,
                    alertConfiguration: alert,
                    start: start
                )
            } catch {
                status = .failed(error.localizedDescription)
                return 30
            }
        }
        status = anyActivity == nil ? .waiting : .active
        return 60
    }

    /// Wake at the next meaningful boundary instead of polling on a fixed
    /// cadence. This keeps a finished class from lingering on the lock screen
    /// while still starting the activity as the next class enters the lead
    /// window.
    private func refreshDelay(for occurrence: Occurrence) -> TimeInterval {
        let now = now()
        if occurrence.isInProgress {
            return max(1, min(15, occurrence.end.timeIntervalSince(now)))
        }

        // 常驻模式在今天第一节课开始之后就一直显示，所以只有「课在别的一天」和
        // 「今天还没开课」两种情况需要等；其余和非常驻一样等到提前量。
        let untilVisible: TimeInterval
        if isPersistent, occurrence.dateKey == Self.dayKey(for: now), dayHasStarted(at: now) {
            untilVisible = 0
        } else if isPersistent, occurrence.dateKey != Self.dayKey(for: now) {
            untilVisible = occurrence.start.timeIntervalSince(now)
        } else {
            untilVisible = occurrence.start.timeIntervalSince(now) - leadTime
        }
        if untilVisible > 0 {
            return max(5, min(60, untilVisible))
        }
        return max(1, min(15, occurrence.start.timeIntervalSince(now)))
    }

    /// The activity identity for an occurrence. Two occurrences on the same
    /// day share it, which is what lets the controller update one activity
    /// instead of replacing it.
    static func attributes(for occurrence: Occurrence, in snapshot: NativeScheduleSnapshot) -> ScheduleLiveActivityAttributes {
        ScheduleLiveActivityAttributes(
            semester: snapshot.data?.currentSemester ?? "",
            dateKey: occurrence.dateKey,
            week: occurrence.week
        )
    }

    /// What the island shows for one occurrence in one phase. Shared by the
    /// live path and by the push plan so a pushed frame cannot render
    /// differently from the same frame produced on device.
    static func contentState(
        for occurrence: Occurrence,
        phase: ScheduleLiveActivityAttributes.ContentState.Phase,
        sourceLabel: String?,
        updatedAt: Date
    ) -> ScheduleLiveActivityAttributes.ContentState {
        ScheduleLiveActivityAttributes.ContentState(
            phase: phase,
            courseName: occurrence.name,
            teacher: occurrence.teacher,
            location: occurrence.location,
            periodLabel: occurrence.periodLabel,
            dateLabel: occurrence.dateLabel,
            weekRangeLabel: occurrence.weekRangeLabel,
            startDate: occurrence.start,
            endDate: occurrence.end,
            nextCourseName: occurrence.next?.name,
            nextCoursePeriod: occurrence.next?.periodLabel,
            nextCourseDateLabel: occurrence.next?.dateLabel,
            nextCourseWeekRangeLabel: occurrence.next?.weekRangeLabel,
            nextCourseTeacher: occurrence.next?.teacher,
            nextCourseLocation: occurrence.next?.location,
            nextCourseStart: occurrence.next?.start,
            nextCourseEnd: occurrence.next?.end,
            sourceLabel: sourceLabel,
            adjustmentNote: occurrence.adjustmentNote.trimmedNonEmpty,
            updatedAt: updatedAt
        )
    }

    // MARK: - 推送计划

    /// One push a server sends on this device's behalf.
    ///
    /// iOS refuses `Activity.request` from the background, so a class that
    /// starts while the app is suspended can only reach the Lock Screen as a
    /// push-to-start notification. The device stays the author of what is
    /// shown: it renders every frame here and hands the server the instants to
    /// relay them.
    struct PlannedPush: Equatable {
        enum Event: String { case start, update, end }

        let id: String
        let event: Event
        let fireAt: Date
        /// When this frame stops being true. A push that arrives later would
        /// put a finished class back on the Lock Screen, so the server drops
        /// the item instead of sending it late.
        let expiresAt: Date
        let state: ScheduleLiveActivityAttributes.ContentState
        let attributes: ScheduleLiveActivityAttributes
        let staleDate: Date
    }

    /// A week covers any gap the user can leave between two launches without
    /// the plan going stale, and stays far inside the server's item limit.
    nonisolated static let planHorizon: TimeInterval = 7 * 24 * 3600
    nonisolated static let planItemLimit = 200
    /// A dismissal stays worth sending long after its moment; everything else
    /// is about a frame that has already passed.
    private static let endPushGrace: TimeInterval = 6 * 3600

    private struct PlanFrame {
        let from: Date
        let until: Date
        let state: ScheduleLiveActivityAttributes.ContentState
        let attributes: ScheduleLiveActivityAttributes
        let staleDate: Date
        let startsRun: Bool
    }

    /// Render the next `horizon` worth of activity frames as pushes.
    ///
    /// The rules are the ones `synchronize(_:)` applies live -- the lead
    /// window, the persistent mode carrying through a break, one activity per
    /// day -- so the island looks the same whether the frame arrived from the
    /// refresh loop or from APNs.
    func pushPlan(
        from snapshot: NativeScheduleSnapshot,
        now current: Date? = nil,
        horizon: TimeInterval = planHorizon
    ) -> [PlannedPush] {
        let currentDate = current ?? now()
        guard isEnabled, snapshot.auth.authenticated else { return [] }
        let deadline = currentDate.addingTimeInterval(horizon)
        let events = occurrences(in: snapshot)
            .filter { $0.end > currentDate && $0.start < deadline }
            .sorted { $0.start < $1.start }
        guard !events.isEmpty else { return [] }

        var frames: [PlanFrame] = []
        var previous: Occurrence?
        var previousAttributes: ScheduleLiveActivityAttributes?
        for (index, event) in events.enumerated() {
            let occurrence = Self.enriched(event, followedBy: index + 1 < events.count ? events[index + 1] : nil)
            let attributes = Self.attributes(for: occurrence, in: snapshot)
            var from = occurrence.start.addingTimeInterval(-leadTime)
            var continues = false
            if let previous, previousAttributes == attributes {
                // The break is shorter than the lead window, or the persistent
                // mode keeps the activity up across it: either way the same
                // activity carries on instead of being replaced.
                if previous.end >= from || isPersistent {
                    from = previous.end
                    continues = true
                }
            }
            if from < occurrence.start {
                frames.append(PlanFrame(
                    from: from,
                    until: occurrence.start,
                    state: Self.contentState(for: occurrence, phase: .upcoming, sourceLabel: snapshot.sourceLabel, updatedAt: from),
                    attributes: attributes,
                    staleDate: occurrence.end,
                    startsRun: !continues
                ))
            }
            frames.append(PlanFrame(
                from: occurrence.start,
                until: occurrence.end,
                state: Self.contentState(for: occurrence, phase: .inProgress, sourceLabel: snapshot.sourceLabel, updatedAt: occurrence.start),
                attributes: attributes,
                staleDate: occurrence.end,
                startsRun: !continues && from >= occurrence.start
            ))
            previous = occurrence
            previousAttributes = attributes
        }

        var plan: [PlannedPush] = []
        var run: [PlanFrame] = []
        for frame in frames {
            if frame.startsRun, !run.isEmpty {
                plan += Self.pushes(for: run)
                run = []
            }
            run.append(frame)
        }
        plan += Self.pushes(for: run)
        return Array(plan.filter { $0.fireAt > currentDate }.prefix(Self.planItemLimit))
    }

    /// Turn one uninterrupted stretch of frames into its pushes: start the
    /// activity, update it at every later frame, dismiss it at the end.
    private static func pushes(for run: [PlanFrame]) -> [PlannedPush] {
        guard let last = run.last else { return [] }
        var pushes: [PlannedPush] = []
        for (index, frame) in run.enumerated() {
            pushes.append(PlannedPush(
                id: identifier(at: frame.from, event: index == 0 ? .start : .update),
                event: index == 0 ? .start : .update,
                fireAt: frame.from,
                expiresAt: frame.until,
                state: frame.state,
                attributes: frame.attributes,
                staleDate: frame.staleDate
            ))
        }
        pushes.append(PlannedPush(
            id: identifier(at: last.until, event: .end),
            event: .end,
            fireAt: last.until,
            expiresAt: last.until.addingTimeInterval(endPushGrace),
            state: last.state,
            attributes: last.attributes,
            staleDate: last.staleDate
        ))
        return pushes
    }

    private static func identifier(at date: Date, event: PlannedPush.Event) -> String {
        "\(Int(date.timeIntervalSince1970))-\(event.rawValue)"
    }

    /// 「下一节」只认同一天的课。跨天的那节课交给小组件，实时活动不提前一天预告。
    private static func follower(_ candidate: Occurrence?, after current: Occurrence) -> Occurrence.NextCourse? {
        guard let candidate, candidate.dateKey == current.dateKey else { return nil }
        return Occurrence.NextCourse(
            name: candidate.name,
            teacher: candidate.teacher,
            location: candidate.location,
            start: candidate.start,
            end: candidate.end,
            periodLabel: candidate.periodLabel,
            dateLabel: candidate.dateLabel,
            weekRangeLabel: candidate.weekRangeLabel
        )
    }

    /// Attach the following course and mark the in-progress phase, the way
    /// `occurrence(from:now:)` does for the live path.
    private static func enriched(_ occurrence: Occurrence, followedBy next: Occurrence?) -> Occurrence {
        Occurrence(
            name: occurrence.name,
            teacher: occurrence.teacher,
            location: occurrence.location,
            periodLabel: occurrence.periodLabel,
            dateLabel: occurrence.dateLabel,
            start: occurrence.start,
            end: occurrence.end,
            dateKey: occurrence.dateKey,
            week: occurrence.week,
            isInProgress: false,
            next: follower(next, after: occurrence),
            weekRangeLabel: occurrence.weekRangeLabel,
            adjustmentNote: occurrence.adjustmentNote
        )
    }

    private func endActivities() async {
        for activity in Activity<ScheduleLiveActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    struct Occurrence {
        struct NextCourse {
            let name: String
            let teacher: String
            let location: String
            let start: Date
            let end: Date
            let periodLabel: String
            let dateLabel: String
            let weekRangeLabel: String
        }

        let name: String
        let teacher: String
        let location: String
        let periodLabel: String
        let dateLabel: String
        let start: Date
        let end: Date
        let dateKey: String
        let week: Int
        let isInProgress: Bool
        let next: NextCourse?
        let weekRangeLabel: String
        /// 这一天的调休说明。补课那天要说清楚上的是哪天的课，否则锁屏上是
        /// 一节看起来不该存在的课。
        let adjustmentNote: String
    }

    /// 今天第一节课的开始时间；今天没有课就是 `nil`。
    func firstStart(of date: Date, in snapshot: NativeScheduleSnapshot) -> Date? {
        let key = Self.dayKey(for: date)
        return occurrences(in: snapshot).filter { $0.dateKey == key }.map(\.start).min()
    }

    /// 今天的第一节课是否已经开始。常驻模式靠它区分「早上还没开课」和「课间」。
    private func dayHasStarted(at date: Date) -> Bool {
        guard let lastSnapshot, let first = firstStart(of: date, in: lastSnapshot) else { return false }
        return date >= first
    }

    func nextOccurrence(in snapshot: NativeScheduleSnapshot, now: Date = .now) -> Occurrence? {
        let events = occurrences(in: snapshot)
            .filter { $0.end > now }
            .sorted { $0.start < $1.start }
        guard !events.isEmpty else { return nil }
        return occurrence(from: events, now: now)
    }

    /// 课表里所有有日期的课程，不做时间过滤。
    private func occurrences(in snapshot: NativeScheduleSnapshot) -> [Occurrence] {
        guard let data = snapshot.data, let calendar = snapshot.calendar else { return [] }
        var dateCalendar = Calendar(identifier: .gregorian)
        dateCalendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let periods = snapshot.periods.isEmpty ? NativeSchedulePeriod.bundledTimetable : snapshot.periods
        let periodByNumber = Dictionary(uniqueKeysWithValues: periods.map { ($0.number, $0) })
        // The timetable payload can contain the whole semester while the
        // visible grid is only one week. Build occurrences for every dated
        // week so a no-class day still gets the next scheduled course.
        let events = calendar.weeks.flatMap { week -> [Occurrence] in
            week.days.enumerated().flatMap { dayIndex, day -> [Occurrence] in
                // 调休：放假那天没有课程要提醒，补班那天提醒的是另一天的课。
                let adjustment = calendar.adjustments[day]
                if adjustment?.suppressesCourses == true { return [] }
                let sourceDay = adjustment?.sourceDay ?? (dayIndex + 1)
                let sourceWeek = adjustment?.sourceWeek ?? week.week
                return data.cells
                    .filter { $0.day == sourceDay }
                    .flatMap { cell in
                        cell.courses.compactMap { course -> Occurrence? in
                            guard course.weekList.isEmpty || course.weekList.contains(sourceWeek) else { return nil }
                            let range = NativeSchedulePeriod.normalizedRange(
                                bigSlot: cell.bigSlot,
                                startSlot: course.startSlot,
                                endSlot: course.endSlot,
                                periods: periods
                            )
                            guard let startPeriod = periodByNumber[range.start],
                                  let endPeriod = periodByNumber[range.end] else {
                                return nil
                            }
                            guard let start = date(day, time: startPeriod.startTime, calendar: dateCalendar),
                                  let end = date(day, time: endPeriod.endTime, calendar: dateCalendar),
                                  end > start else {
                                return nil
                            }
                            return Occurrence(
                                name: course.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "课程" : course.name,
                                teacher: course.teacher?.trimmedNonEmpty ?? "",
                                location: course.location?.trimmedNonEmpty ?? "",
                                periodLabel: Self.periodLabel(start: range.start, end: range.end),
                                dateLabel: Self.dateLabel(day: day, week: week.week),
                                start: start,
                                end: end,
                                dateKey: day,
                                week: week.week,
                                isInProgress: false,
                                next: nil,
                                weekRangeLabel: course.weeks.trimmedNonEmpty ?? "",
                                adjustmentNote: adjustment?.detail ?? ""
                            )
                        }
                    }
            }
        }
        return events
    }

    private func occurrence(from events: [Occurrence], now: Date) -> Occurrence? {
        if let index = events.firstIndex(where: { $0.start <= now && now < $0.end }) {
            let current = events[index]
            return Occurrence(
                name: current.name,
                teacher: current.teacher,
                location: current.location,
                periodLabel: current.periodLabel,
                dateLabel: current.dateLabel,
                start: current.start,
                end: current.end,
                dateKey: current.dateKey,
                week: current.week,
                isInProgress: true,
                next: Self.follower(events.dropFirst(index + 1).first, after: current),
                weekRangeLabel: current.weekRangeLabel,
                adjustmentNote: current.adjustmentNote
            )
        }
        let upcoming = events[0]
        let next = Self.follower(events.dropFirst().first, after: upcoming)
        return Occurrence(
            name: upcoming.name,
            teacher: upcoming.teacher,
            location: upcoming.location,
            periodLabel: upcoming.periodLabel,
            dateLabel: upcoming.dateLabel,
            start: upcoming.start,
            end: upcoming.end,
            dateKey: upcoming.dateKey,
            week: upcoming.week,
            isInProgress: false,
            next: next,
            weekRangeLabel: upcoming.weekRangeLabel,
            adjustmentNote: upcoming.adjustmentNote
        )
    }

    private static func periodLabel(start: Int, end: Int) -> String {
        start == end ? "第 " + String(start) + " 节" : "第 " + String(start) + "-" + String(end) + " 节"
    }

    /// The `dateKey` an occurrence would carry if it happened on `date`.
    static func dayKey(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return "" }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func dateLabel(day: String, week: Int) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return week > 0 ? "第 " + String(week) + " 周" : "" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        let weekday = date.map { calendar.component(.weekday, from: $0) }
        let labels = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let dayLabel = weekday.flatMap { labels.indices.contains($0 - 1) ? labels[$0 - 1] : nil }
        if let dayLabel, week > 0 { return dayLabel + " · 第 " + String(week) + " 周" }
        return dayLabel ?? (week > 0 ? "第 " + String(week) + " 周" : "")
    }

    private func date(_ day: String, time: String, calendar: Calendar) -> Date? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        let dateParts = day.split(separator: "-").compactMap { Int($0) }
        guard dateParts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = dateParts[0]
        components.month = dateParts[1]
        components.day = dateParts[2]
        components.hour = parts[0]
        components.minute = parts[1]
        components.second = 0
        return calendar.date(from: components)
    }
}

#endif
