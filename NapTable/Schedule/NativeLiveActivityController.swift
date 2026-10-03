#if os(iOS) || LIVE_ACTIVITY_CHECKS
import ActivityKit
import Combine
import Foundation
#if os(iOS)
import UIKit
#endif

/// The phone's half of the course reminders. The server computes when each
/// activity starts and ends from the uploaded timetable; this renders them
/// from the local timetables, reserves the few the server hands over on
/// iOS 26, and collects the push tokens of token-mode activities.
@available(iOS 17.0, *)
@MainActor
final class NativeLiveActivityController: ObservableObject {
    enum Status: Equatable {
        case disabled, waiting, active
        case unavailable(String), failed(String), limited(String)
        var title: String {
            switch self {
            case .disabled: return "已关闭"
            case .waiting: return "等待课程提醒"
            case .active: return "实时活动已显示"
            case .unavailable: return "自动提醒暂不可用"
            case .failed: return "安排失败"
            case .limited: return "预约名额已满"
            }
        }
        var detail: String? {
            switch self { case .unavailable(let text), .failed(let text), .limited(let text): return text; default: return nil }
        }
    }
    static let shared = NativeLiveActivityController()
    static let enabledKey = "scheduleLiveActivityEnabled"
    static let leadMinutesKey = "scheduleLiveActivityLeadMinutes"
    static let sharedLeadMinutesKey = "naptable.liveActivity.sharedLeadMinutes"
    static let defaultLeadMinutes = 60
    static let leadMinuteOptions = [15, 30, 60]
    static let perPeriodKey = "naptable.liveActivity.perPeriod"
    /// Reservations to keep at most. The system allows about five pending
    /// activities; one stays free for the preview.
    static let reservationSlots = 4

    @Published private(set) var status: Status = .waiting
    @Published private(set) var isPreviewActive = false
    @Published private(set) var coverage = "尚未安排"
    @Published private(set) var conflicts: [LiveActivityTimeline.Conflict] = []
    @Published private(set) var omitted = 0
    @Published private(set) var dismissedOccurrence: String?
    @Published private(set) var restorationFailure: String?
    /// Asks the system to wake the app around an instant (see `LiveActivityBackgroundRefresh`).
    var scheduleBackgroundWakeup: ((Date) -> Void)?
    /// The timetable or a setting changed: the push service uploads it again.
    var planDidChange: (() -> Void)?
    /// A token-mode activity got a token, rotated it or went away: the push
    /// service reconciles the server's registrations.
    var activityTokensDidChange: (() -> Void)?
    /// Whether the server lets this device have reminders today, as the last
    /// sync said. False when a trial or lifetime entitlement is required and
    /// this device has none: the app then starts no
    /// activity of its own on entry either.
    var reminderAllowed = true {
        didSet { if oldValue != reminderAllowed { rebuild() } }
    }
    /// The displayed timetable: the reader's own, or a followed share.
    private(set) var currentScheduleMetadata: NativeScheduleSnapshot?
    /// The reader's own timetable while `currentScheduleMetadata` is a followed share.
    private(set) var ownScheduleMetadata: NativeScheduleSnapshot?
    private(set) var display: LiveActivityDisplaySnapshot?
    private var task: Task<Void, Never>?
    private var retirementTask: Task<Void, Never>?
    private var epoch = 0
    private var isForeground = false
    private let now: () -> Date
    private let applicationIsActive: (() -> Bool)?
    private var canStartForegroundActivity: Bool {
        guard isForeground else { return false }
        if let applicationIsActive { return applicationIsActive() }
        #if os(iOS)
        return UIApplication.shared.applicationState == .active
        #else
        return true
        #endif
    }
    private let privacyDefaults: UserDefaults
    private let defaults: UserDefaults
    /// Activity ID → hex push token. Activity registrations live only as long as the process.
    private var activityTokens: [String: String] = [:]
    private var tokenObservers: [String: Task<Void, Never>] = [:]
    private var announcedTokens: [String] = []
    /// The push service's last failure, kept apart from `status` so a local
    /// reconcile cannot paper over it; cleared by the next successful sync.
    private(set) var serviceFailure: String?
    /// Ends the preview state when the preview activity goes away on its own
    /// (it runs out, or is swiped away on the Lock Screen).
    private var previewObserver: Task<Void, Never>?
    private var dismissalObservers: [String: Task<Void, Never>] = [:]
    private var retiringActivityIDs: Set<String> = []
    private struct DismissalWindow: Codable, Equatable {
        var scope: String
        var dateKey: String
        var start: Double
        var end: Double
        func overlaps(scope: String, dateKey: String, start: Double, end: Double) -> Bool {
            self.scope == scope && self.dateKey == dateKey && self.start < end && self.end > start
        }
    }
    private var dismissalWindow: DismissalWindow?
    // Keep the user's decision across scene reactivation and cancelled rebuilds.
    // Until reconciliation runs, a missing activity is expected, not a new dismissal.
    private var restoringDismissedReminder = false
    private var restorationWindow: DismissalWindow?
    private var dismissalDefaults: UserDefaults { privacyDefaults }
    private static let skippedKey = "naptable.liveActivity.skippedOccurrences"
    private var skippedWindows: [DismissalWindow] {
        guard let data = dismissalDefaults.data(forKey: Self.skippedKey),
              let windows = try? JSONDecoder().decode([DismissalWindow].self, from: data) else { return [] }
        return windows.filter { $0.end > now().timeIntervalSince1970 }
    }
    private func isSkipped(scope: String, dateKey: String, start: Double, end: Double) -> Bool {
        skippedWindows.contains { $0.overlaps(scope: scope, dateKey: dateKey, start: start, end: end) }
    }
    private func isSkipped(_ attributes: ScheduleLiveActivityAttributes) -> Bool {
        guard let start = attributes.reservationStart, let end = attributes.reservationEnd else { return false }
        return isSkipped(scope: attributes.scheduleScope ?? "", dateKey: attributes.dateKey,
                         start: start.timeIntervalSince1970, end: end.timeIntervalSince1970)
    }
    private static let channelsKey = "naptable.liveActivity.v2.channels"

    init(now: @escaping () -> Date = { .now }, privacyDefaults: UserDefaults = .standard,
         applicationIsActive: (() -> Bool)? = nil) {
        self.applicationIsActive = applicationIsActive
        self.privacyDefaults = privacyDefaults
        self.now = now
        defaults = UserDefaults(suiteName: NextWidgetConfiguration.appGroup) ?? .standard
        if !isEnabled { status = .disabled }
    }
    var isEnabled: Bool { PrivacyPolicy.liveAllowed(privacyDefaults) && (defaults.object(forKey: Self.enabledKey) as? Bool ?? true) }
    var leadMinutes: Int { Self.lead(defaults.integer(forKey: Self.leadMinutesKey)) ?? Self.defaultLeadMinutes }
    /// Minutes ahead for a followed share's courses; the reader's own lead until set.
    var sharedLeadMinutes: Int { Self.lead(defaults.integer(forKey: Self.sharedLeadMinutesKey)) ?? leadMinutes }
    var perPeriod: Bool { defaults.bool(forKey: Self.perPeriodKey) }
    var following: Bool { currentScheduleMetadata?.sourceLabel != nil }
    private static func lead(_ value: Int) -> Int? { leadMinuteOptions.contains(value) ? value : nil }

    func setEnabled(_ requested: Bool) {
        let value = requested && PrivacyPolicy.liveAllowed(privacyDefaults)
        defaults.set(value, forKey: Self.enabledKey)
        if value { rebuild() } else { clearDismissalNotice(); end(); status = .disabled }
        #if os(iOS)
        if #available(iOS 17.2, *) { LiveActivityPushService.shared.enabledDidChange(value) }
        #endif
    }
    func setLeadMinutes(_ value: Int) {
        defaults.set(Self.lead(value) ?? Self.defaultLeadMinutes, forKey: Self.leadMinutesKey)
        rebuild()
    }
    func setSharedLeadMinutes(_ value: Int) {
        defaults.set(Self.lead(value) ?? Self.defaultLeadMinutes, forKey: Self.sharedLeadMinutesKey)
        rebuild()
    }
    func setPerPeriod(_ value: Bool) { defaults.set(value, forKey: Self.perPeriodKey); rebuild() }
    /// Conflict choices of the displayed table, `date:period` → source.
    var choices: [String: String] {
        guard let scope = currentScheduleMetadata?.scheduleScope else { return [:] }
        return defaults.dictionary(forKey: "naptable.liveActivity.conflicts." + scope) as? [String: String] ?? [:]
    }
    func selectedSource(for conflict: LiveActivityTimeline.Conflict) -> String { choices[conflict.id] ?? "" }
    func selectSource(_ source: String, for conflict: LiveActivityTimeline.Conflict) {
        guard let scope = currentScheduleMetadata?.scheduleScope else { return }
        var selections = choices
        selections[conflict.id] = source
        defaults.set(selections, forKey: "naptable.liveActivity.conflicts." + scope)
        rebuild()
    }
    /// What the server needs to compute the reminders; `nil` without a usable semester.
    func timetable() -> [String: Any]? {
        guard let snapshot = currentScheduleMetadata, let own = following ? ownScheduleMetadata : snapshot else { return nil }
        guard var body = LiveActivityTimeline.timetable(own: own, share: following ? snapshot : nil, choices: choices,
                                              lead: leadMinutes, sharedLead: sharedLeadMinutes, perPeriod: perPeriod) else { return nil }
        body["skippedOccurrences"] = skippedWindows.map {
            ["scope": $0.scope, "dateKey": $0.dateKey, "start": $0.start, "end": $0.end] as [String: Any]
        }
        return body
    }
    func accept(_ snapshot: NativeScheduleSnapshot, own: NativeScheduleSnapshot? = nil) {
        guard !snapshot.cancelled else { return }
        // Activities of another table end; the server plans the new one once it is uploaded.
        // On a cold start nothing was shown yet: the running activities stay, and
        // reconcile retires those of any other table by their scope.
        if let old = currentScheduleMetadata?.scheduleScope, old != snapshot.scheduleScope { end() }
        ownScheduleMetadata = snapshot.sourceLabel == nil ? nil : own
        currentScheduleMetadata = snapshot
        rebuild()
    }
    private func rebuild() {
        guard let snapshot = currentScheduleMetadata, !isPreviewActive else { return }
        epoch += 1
        task?.cancel()
        guard isEnabled else { status = .disabled; return }
        guard let scope = snapshot.scheduleScope else { status = .unavailable("请重新打开一次课表后再试。"); return }
        let built = LiveActivityTimeline.build(snapshot, own: ownScheduleMetadata, now: now(), lead: leadMinutes, sharedLead: sharedLeadMinutes,
                                               perPeriod: perPeriod, choices: choices)
        conflicts = built.conflicts
        omitted = built.omitted
        let value = LiveActivityDisplaySnapshot(scope: scope, sourceLabel: snapshot.sourceLabel, occurrences: built.occurrences)
        do { try value.save(); display = value }
        catch { status = .failed("暂时无法保存提醒，请稍后重试。"); return }
        validateDismissalNotice()
        planDidChange?()
        let generation = epoch
        task = Task { [weak self] in
            guard let self else { return }
            await self.retirementTask?.value
            await self.reconcile(generation: generation)
        }
    }
    func setServiceFailure(_ reason: String) { serviceFailure = reason; status = .unavailable(reason) }
    /// A sync went through: the local state shows again.
    func clearServiceFailure() {
        guard serviceFailure != nil else { return }
        serviceFailure = nil
        guard isEnabled, !isPreviewActive, display != nil else { return }
        let generation = epoch
        Task { [weak self] in await self?.reconcile(generation: generation) }
    }
    /// The scope token-mode activities are matched against. A push-to-start
    /// can launch the app in the background before any timetable is accepted:
    /// the last saved display snapshot still names it.
    var tokenScope: String? { display?.scope ?? LiveActivityDisplaySnapshot.load()?.scope }
    /// Token-mode activities still running and their tokens. `live` also names
    /// those whose token this process has not received yet, so a cold start
    /// does not mistake them for gone.
    func tokenRegistrations() -> (registrations: [LiveActivityTokenRegistration], live: Set<String>) {
        guard let scope = tokenScope else { return ([], []) }
        var registrations: [LiveActivityTokenRegistration] = []
        var live: Set<String> = []
        for activity in Activity<ScheduleLiveActivityAttributes>.activities where activity.attributes.pushMode == "token" &&
            activity.activityState != .ended && activity.activityState != .dismissed && activity.attributes.scheduleScope == scope {
            guard let id = activity.attributes.occurrenceId, (activity.attributes.reservationEnd ?? .distantPast) > now(), !live.contains(id) else { continue }
            live.insert(id)
            if let token = activityTokens[activity.id] {
                // Not in the server's plan: it has to be told when to end it.
                let local = id.hasPrefix("foreground:") ? activity.attributes.reservationEnd?.timeIntervalSince1970 : nil
                registrations.append(.init(occurrenceId: id, token: token, end: local))
            }
        }
        return (registrations, live)
    }
    func observeTokens(of activity: Activity<ScheduleLiveActivityAttributes>) {
        if !isEnabled || isSkipped(activity.attributes) {
            Task { await self.endActivity(activity) }
            return
        }
        // A delayed push can arrive after the foreground fallback. Retire
        // the fallback once the server-backed activity is actually running.
        if activity.attributes.occurrenceId?.hasPrefix("foreground:") != true,
           activity.activityState == .active || activity.activityState == .stale {
            let fallbacks = courseActivities.filter {
                $0.attributes.occurrenceId?.hasPrefix("foreground:") == true &&
                $0.attributes.scheduleScope == activity.attributes.scheduleScope &&
                $0.attributes.dateKey == activity.attributes.dateKey &&
                ($0.attributes.reservationStart ?? .distantFuture) < (activity.attributes.reservationEnd ?? .distantPast) &&
                ($0.attributes.reservationEnd ?? .distantPast) > (activity.attributes.reservationStart ?? .distantFuture)
            }
            if !fallbacks.isEmpty {
                Task { for fallback in fallbacks { await self.endActivity(fallback) } }
            }
        }
        guard activity.attributes.pushMode == "token", tokenObservers[activity.id] == nil else { return }
        let id = activity.id
        tokenObservers[id] = Task { [weak self] in
            for await data in activity.pushTokenUpdates {
                guard let self else { return }
                activityTokens[id] = data.map { String(format: "%02x", $0) }.joined()
                announceTokens()
            }
            self?.tokenObservers[id] = nil
        }
    }
    /// Tokens can rotate and registrations die with the process, so every pass
    /// re-attaches to each token-mode activity still around.
    private func observeTokenActivities() {
        let current = Activity<ScheduleLiveActivityAttributes>.activities.filter { $0.activityState != .ended && $0.activityState != .dismissed }
        let ids = Set(current.map(\.id))
        activityTokens = activityTokens.filter { ids.contains($0.key) }
        for activity in current { observeTokens(of: activity) }
    }
    private func announceTokens() {
        let state = tokenRegistrations()
        let key = state.registrations.map { $0.occurrenceId + ":" + $0.token }.sorted() + state.live.sorted()
        guard key != announcedTokens else { return }
        announcedTokens = key
        activityTokensDidChange?()
    }
    /// A local update goes stale at the next display change, so the system
    /// redraws then even if no push arrives.
    private func staleDate(_ attributes: ScheduleLiveActivityAttributes, in display: LiveActivityDisplaySnapshot?) -> Date? {
        display?.nextChange(attributes: attributes, after: now()) ?? attributes.reservationEnd
    }
    func foreground() {
        isForeground = true
        // Refresh the course window before retaining or presenting any notice.
        // Absence alone does not prove dismissal (a reminder may not have arrived).
        if !isPreviewActive { rebuild() }
        validateDismissalNotice()
        observeDismissals()
    }
    private func currentOccurrence(overlapping window: DismissalWindow) -> LiveActivityOccurrence? {
        guard isEnabled, !isPreviewActive, let display, display.scope == window.scope else { return nil }
        let instant = now().timeIntervalSince1970
        return display.occurrences.first {
            $0.reminder <= instant && instant < $0.end &&
            window.overlaps(scope: display.scope, dateKey: $0.dateKey, start: $0.start, end: $0.end)
        }
    }
    private func validateDismissalNotice() {
        guard let window = dismissalWindow else { return }
        if currentOccurrence(overlapping: window) == nil { clearDismissalNotice() }
    }
    func clearDismissalNotice() { dismissedOccurrence = nil; dismissalWindow = nil }
    func continueDismissedReminder() {
        restorationFailure = nil
        restorationWindow = dismissalWindow
        if restorationWindow == nil, let display,
           let occurrence = display.occurrences.first(where: { $0.reminder <= now().timeIntervalSince1970 && now().timeIntervalSince1970 < $0.end }) {
            restorationWindow = .init(scope: display.scope, dateKey: occurrence.dateKey, start: occurrence.start, end: occurrence.end)
        }
        clearDismissalNotice()
        guard isEnabled else { restorationFailure = "实时通知已关闭，请先在设置中开启。"; return }
        guard currentScheduleMetadata != nil, !isPreviewActive else {
            restorationFailure = "请先结束预览并打开课表，再恢复实时通知。"; return
        }
        guard restorationWindow != nil else { restorationFailure = "本次课程已结束或不在提醒时间内。"; return }
        restoringDismissedReminder = true
        // Do not pretend the app is active while its alert is still dismissing.
        // foreground() will retry when the actual application becomes active.
        rebuild()
    }
    func clearRestorationFailure() { restorationFailure = nil }
    func resumeReminderRestoration() {
        guard restoringDismissedReminder else { return }
        foreground()
    }
    /// Channel mode: the server's broadcast channel of each final period of the
    /// table `scope`, so an activity started on entry follows the school's bells.
    /// Empty in token mode (a followed share, or bells the school does not have).
    func setBroadcastChannels(_ channels: [String: String], scope: String) {
        defaults.set(["scope": scope, "channels": channels] as [String: Any], forKey: Self.channelsKey)
    }
    /// The channel ending with the period that ends `occurrence`, when the table shown has them.
    private func broadcastChannel(for occurrence: LiveActivityOccurrence, in display: LiveActivityDisplaySnapshot) -> String? {
        guard let stored = defaults.dictionary(forKey: Self.channelsKey), stored["scope"] as? String == display.scope,
              let channels = stored["channels"] as? [String: String], let snapshot = currentScheduleMetadata,
              let zone = TimeZone(identifier: snapshot.timeZone ?? TimeZone.current.identifier),
              let period = snapshot.periods(on: occurrence.dateKey).first(where: {
                  LiveActivityTimeline.instant(day: occurrence.dateKey, clock: $0.endTime, zone: zone) == occurrence.end
              }) else { return nil }
        return channels[String(period.number)]
    }
    func suppressDismissal(for occurrenceID: String, permanently: Bool) {
        if permanently { setEnabled(false); return }
        guard occurrenceID == dismissedOccurrence, let window = dismissalWindow else { return }
        var windows = skippedWindows
        if !windows.contains(window) { windows.append(window) }
        if let data = try? JSONEncoder().encode(windows) { dismissalDefaults.set(data, forKey: Self.skippedKey) }
        clearDismissalNotice()
        let previousRetirement = retirementTask
        let activities = courseActivities.filter { isSkipped($0.attributes) }
        retirementTask = Task { [weak self] in
            guard let self else { return }
            await previousRetirement?.value
            for activity in activities { await self.endActivity(activity) }
            self.announceTokens()
        }
        rebuild()
    }
    private func endActivity(_ activity: Activity<ScheduleLiveActivityAttributes>) async {
        // Immediate ends also report dismissed. Stop observing before the API
        // call so replacing or retiring an activity cannot prompt the user.
        retiringActivityIDs.insert(activity.id)
        dismissalObservers.removeValue(forKey: activity.id)?.cancel()
        defer { retiringActivityIDs.remove(activity.id) }
        await activity.end(nil, dismissalPolicy: .immediate)
    }
    private func observeDismissals() {
        for activity in courseActivities where dismissalObservers[activity.id] == nil && !retiringActivityIDs.contains(activity.id) {
            let id = activity.id
            let initiallyVisible = activity.activityState == .active || activity.activityState == .stale
            dismissalObservers[id] = Task { [weak self] in
                // A pending reservation being removed is not a displayed activity
                // being dismissed. Remember whether this activity actually started.
                var wasVisible = initiallyVisible
                for await state in activity.activityStateUpdates {
                    guard !Task.isCancelled, state != .ended else { break }
                    if state == .active || state == .stale { wasVisible = true }
                    guard state == .dismissed else { continue }
                    guard let self, wasVisible, self.isEnabled, !self.isPreviewActive, !self.restoringDismissedReminder,
                          let occurrence = activity.attributes.occurrenceId,
                          let scope = activity.attributes.scheduleScope,
                          let start = activity.attributes.reservationStart, let end = activity.attributes.reservationEnd,
                          let reminder = activity.attributes.reminderDate,
                          reminder <= self.now(), self.now() < end, !self.isSkipped(activity.attributes) else { break }
                    let window = DismissalWindow(scope: scope, dateKey: activity.attributes.dateKey,
                                                 start: start.timeIntervalSince1970, end: end.timeIntervalSince1970)
                    guard self.currentOccurrence(overlapping: window) != nil else { break }
                    self.dismissalWindow = window
                    self.dismissedOccurrence = occurrence
                }
                self?.dismissalObservers[id] = nil
            }
        }
    }
    func leaveForeground() { isForeground = false }
    func refreshForThemeChange() { rebuild() }
    func reset() {
        currentScheduleMetadata = nil
        ownScheduleMetadata = nil
        display = nil
        defaults.removeObject(forKey: LiveActivityDisplaySnapshot.key)
        end()
        #if os(iOS)
        if #available(iOS 17.2, *) { LiveActivityPushService.shared.revoke() }
        #endif
    }

    private func valid(_ generation: Int) -> Bool { generation == epoch && !Task.isCancelled && isEnabled && !isPreviewActive }
    private var courseActivities: [Activity<ScheduleLiveActivityAttributes>] {
        Activity<ScheduleLiveActivityAttributes>.activities.filter { $0.attributes.protocolVersion == 2 && $0.activityState != .ended && $0.activityState != .dismissed }
    }
    /// Reservations still waiting for their reminder.
    var reservationCount: Int { courseActivities.filter { Self.isPending($0) && $0.attributes.scheduleScope == display?.scope }.count }
    private static func isPending(_ activity: Activity<ScheduleLiveActivityAttributes>) -> Bool {
        if #available(iOS 26.0, *) { return activity.activityState == .pending }
        return false
    }
    private func reconcile(generation: Int) async {
        guard valid(generation), let display else { return }
        // A superseded task must not consume the decision: its successor still
        // needs to restore the activity. If the scene is inactive, wait for entry.
        defer {
            if valid(generation), canStartForegroundActivity, restoringDismissedReminder {
                let restored = courseActivities.contains { activity in
                    (activity.activityState == .active || activity.activityState == .stale) &&
                    restorationWindow?.overlaps(scope: activity.attributes.scheduleScope ?? "", dateKey: activity.attributes.dateKey,
                        start: activity.attributes.reservationStart?.timeIntervalSince1970 ?? .infinity,
                        end: activity.attributes.reservationEnd?.timeIntervalSince1970 ?? 0) == true
                }
                if !restored {
                    restorationFailure = status.detail ?? "本次课程已结束，或系统未能恢复实时通知。请重新打开课表后重试。"
                }
                restoringDismissedReminder = false
                restorationWindow = nil
            }
        }
        guard #available(iOS 18.0, *) else {
            coverage = "当前系统仅支持预览效果"
            status = .unavailable("自动提醒需要 iOS 18 或更新版本。")
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { status = .unavailable("请在系统设置中允许实时活动。"); return }
        for activity in Activity<ScheduleLiveActivityAttributes>.activities where activity.activityState != .ended && activity.activityState != .dismissed {
            guard valid(generation) else { return }
            // One-time retirement is also safe after an interrupted upgrade.
            if isSkipped(activity.attributes) || (activity.attributes.reservationEnd ?? activity.content.state.endDate) <= now() ||
                activity.attributes.protocolVersion != 2 || activity.attributes.scheduleScope != display.scope {
                await endActivity(activity)
            }
        }
        observeTokenActivities()
        defer { announceTokens() }
        guard valid(generation) else { return }
        guard reminderAllowed else {
            coverage = "需要试用或买断"
            status = .unavailable("实时活动需要 30 天试用或一次买断。")
            return
        }
        if canStartForegroundActivity {
            let instant = now()
            for occurrence in display.occurrences where occurrence.reminder <= instant.timeIntervalSince1970 && instant.timeIntervalSince1970 < occurrence.end {
                guard !isSkipped(scope: display.scope, dateKey: occurrence.dateKey, start: occurrence.start, end: occurrence.end),
                      dismissalWindow?.overlaps(scope: display.scope, dateKey: occurrence.dateKey, start: occurrence.start, end: occurrence.end) != true else { continue }
                // On explicit restore a pending reservation is not a visible
                // activity. Retire it first so it cannot block an immediate start.
                if restoringDismissedReminder {
                    for activity in courseActivities where Self.isPending(activity) &&
                        activity.attributes.scheduleScope == display.scope && activity.attributes.dateKey == occurrence.dateKey &&
                        (activity.attributes.reservationStart?.timeIntervalSince1970 ?? .infinity) < occurrence.end &&
                        (activity.attributes.reservationEnd?.timeIntervalSince1970 ?? 0) > occurrence.start {
                        await endActivity(activity)
                    }
                    guard valid(generation), canStartForegroundActivity else { return }
                }
                // Outside an explicit restore, keep the server reservation.
                guard !courseActivities.contains(where: {
                    $0.attributes.scheduleScope == display.scope && $0.attributes.dateKey == occurrence.dateKey &&
                    ($0.attributes.reservationStart?.timeIntervalSince1970 ?? .infinity) < occurrence.end &&
                    ($0.attributes.reservationEnd?.timeIntervalSince1970 ?? 0) > occurrence.start
                }), let state = occurrence.state(at: instant) else { continue }
                // The server ends it on time, the process may be long gone by then:
                // on the school's bells like its own activities, else by its token.
                let channel = broadcastChannel(for: occurrence, in: display)
                let attributes = ScheduleLiveActivityAttributes(
                    semester: currentScheduleMetadata?.data?.currentSemester ?? "", dateKey: occurrence.dateKey,
                    protocolVersion: 2, scheduleScope: display.scope,
                    occurrenceId: "foreground:" + occurrence.sourceID + ":" + String(occurrence.start),
                    reservationStart: Date(timeIntervalSince1970: occurrence.start),
                    reservationEnd: Date(timeIntervalSince1970: occurrence.end),
                    broadcastChannel: channel,
                    reminderDate: Date(timeIntervalSince1970: occurrence.reminder), pushMode: channel == nil ? "token" : nil)
                do {
                    let activity = try Activity<ScheduleLiveActivityAttributes>.request(attributes: attributes,
                        content: ActivityContent(state: state, staleDate: staleDate(attributes, in: display)),
                        pushType: channel.map { .channel($0) } ?? .token)
                    observeTokens(of: activity)
                } catch {
                    status = Self.isCapacityError(error)
                        ? .limited("系统暂无可用的实时活动名额，请稍后重试。")
                        : .failed("实时通知没能启动：\(error.localizedDescription)")
                    return
                }
            }
        }
        observeDismissals()
        let running = courseActivities.filter { $0.activityState == .active || $0.activityState == .stale }
        for activity in running {
            if let state = display.resolve(attributes: activity.attributes, at: now()) {
                await activity.update(ActivityContent(state: state, staleDate: staleDate(activity.attributes, in: display)))
            }
        }
        // Without a push at the end (offline), the next wakeup still retires it.
        if let end = running.compactMap(\.attributes.reservationEnd).min() { scheduleBackgroundWakeup?(end) }
        if let serviceFailure { status = .unavailable(serviceFailure); return }
        if case .limited = status { return }
        coverage = "已开启自动提醒"
        status = running.isEmpty ? .waiting : .active
    }
    /// Reserves the reminders the server handed to the phone and returns the
    /// ones to give back: those it could not reserve. A reservation the server
    /// no longer holds, or holds with other times, is withdrawn first.
    ///
    /// The server counts every claim as reserved on the phone until it comes
    /// back, so a claim this pass cannot act on (switched off, previewing, or
    /// superseded while waiting) is returned rather than dropped.
    @available(iOS 26.0, *)
    func reserve(_ claims: [LiveActivityClaim]) async -> [String] {
        let all = claims.map(\.occurrenceId)
        guard let display, isEnabled, !isPreviewActive else { return all }
        let generation = epoch
        await retirementTask?.value
        guard valid(generation) else { return unreserved(claims) }
        let current = now().timeIntervalSince1970
        let semester = currentScheduleMetadata?.data?.currentSemester ?? ""
        let wanted = Dictionary(claims.map { ($0.occurrenceId, $0.attributes(semester: semester)) }, uniquingKeysWith: { first, _ in first })
        for activity in courseActivities where activity.activityState == .pending {
            guard let id = activity.attributes.occurrenceId, wanted[id] != activity.attributes else { continue }
            await endActivity(activity)
        }
        guard valid(generation) else { return unreserved(claims) }
        var release: [String] = []
        var quotaReached = false
        var failure: String?
        for (index, claim) in claims.sorted(by: { $0.reminder < $1.reminder }).enumerated() {
            guard valid(generation) else {
                release += unreserved(Array(claims.sorted(by: { $0.reminder < $1.reminder })[index...]))
                break
            }
            let attributes = claim.attributes(semester: semester)
            if isSkipped(attributes) { release.append(claim.occurrenceId); continue }
            if courseActivities.contains(where: { $0.attributes.occurrenceId == claim.occurrenceId }) { continue }
            // Already started (or dismissed): nothing left to reserve.
            guard claim.reminder > current else { continue }
            let pushType: PushType
            if claim.pushMode == "token" { pushType = .token }
            else if let channel = claim.channel { pushType = .channel(channel) }
            else { release.append(claim.occurrenceId); continue }
            guard !quotaReached, claim.scheduleScope == display.scope,
                  let state = display.resolve(attributes: attributes, at: Date(timeIntervalSince1970: claim.reminder)) else {
                release.append(claim.occurrenceId)
                continue
            }
            do {
                _ = try Activity<ScheduleLiveActivityAttributes>.request(attributes: attributes, content: ActivityContent(state: state, staleDate: Date(timeIntervalSince1970: claim.end)),
                    pushType: pushType, style: .standard, alertConfiguration: AlertConfiguration(title: "课程提醒", body: "即将上课", sound: .default),
                    start: Date(timeIntervalSince1970: claim.reminder))
            } catch {
                release.append(claim.occurrenceId)
                if Self.isCapacityError(error) { quotaReached = true } else { failure = "部分提醒暂时没能安排，稍后会自动重试。" }
            }
        }
        observeTokenActivities()
        announceTokens()
        coverage = "已开启自动提醒"
        if let failure { status = .unavailable(failure) }
        else if quotaReached {
            status = .limited("系统的实时活动数量已达上限，课程提醒仍会照常出现。")
        } else if case .limited = status { status = .waiting }
        return release
    }
    /// The claims to give back once this pass is superseded. Switched off or
    /// previewing, `end()` retires every activity, so all of them; after a mere
    /// rebuild those already reserved stay (the server would start them twice).
    private func unreserved(_ claims: [LiveActivityClaim]) -> [String] {
        guard isEnabled, !isPreviewActive else { return claims.map(\.occurrenceId) }
        return claims.map(\.occurrenceId).filter { id in !courseActivities.contains { $0.attributes.occurrenceId == id } }
    }
    private static func isCapacityError(_ error: Error) -> Bool {
        guard let error = error as? ActivityAuthorizationError else { return false }
        return error == .targetMaximumExceeded || error == .globalMaximumExceeded
    }
    func end() {
        clearDismissalNotice()
        restoringDismissedReminder = false
        restorationWindow = nil
        epoch += 1
        task?.cancel()
        isPreviewActive = false
        previewObserver?.cancel()
        previewObserver = nil
        let activities = Activity<ScheduleLiveActivityAttributes>.activities
        let tokens = activities.contains { $0.attributes.pushMode == "token" }
        retirementTask = Task { [weak self] in
            guard let self else { return }
            for activity in activities { await self.endActivity(activity) }
            // Lets the push service withdraw the ended activities' refreshes.
            if tokens { self.announceTokens() }
        }
    }
    func startPreview() {
        guard isEnabled else { return }
        end()
        isPreviewActive = true
        let date = now()
        let state = ScheduleLiveActivityAttributes.ContentState(phase: .inProgress, courseName: "演示课程", teacher: "李老师", location: "教学楼 101", startDate: date, endDate: date.addingTimeInterval(15 * 60), updatedAt: date)
        let generation = epoch
        task = Task { [weak self] in
            guard let self else { return }
            await self.retirementTask?.value
            guard self.epoch == generation, self.isPreviewActive, self.isEnabled, !Task.isCancelled else { return }
            do {
                let preview = try Activity<ScheduleLiveActivityAttributes>.request(attributes: .init(semester: "__preview__", dateKey: "preview"), content: ActivityContent(state: state, staleDate: state.endDate), pushType: nil)
                self.status = .active
                self.observePreview(preview, generation: generation)
            } catch {
                self.isPreviewActive = false
                self.status = Self.isCapacityError(error)
                    ? .limited("系统暂无可用的实时活动名额，请稍后重试预览。")
                    : .failed("预览没能启动，请稍后重试。")
            }
        }
    }
    /// The reservations the preview displaced come back with the next sync.
    func endPreview() { end(); rebuild() }
    /// Swiped away or ended by the system: the reminders come back as if
    /// 「结束预览」 had been tapped.
    private func observePreview(_ activity: Activity<ScheduleLiveActivityAttributes>, generation: Int) {
        previewObserver?.cancel()
        previewObserver = Task { [weak self] in
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                guard let self, self.epoch == generation, self.isPreviewActive else { return }
                self.previewObserver = nil
                self.endPreview()
                return
            }
        }
    }
    func reconcileInBackground() async {
        guard !isPreviewActive else { return }
        let current = now()
        observeTokenActivities()
        let stored = display ?? LiveActivityDisplaySnapshot.load()
        for activity in Activity<ScheduleLiveActivityAttributes>.activities where activity.activityState != .ended && activity.activityState != .dismissed {
            if !isEnabled || isSkipped(activity.attributes) || (activity.attributes.reservationEnd ?? activity.content.state.endDate) <= current {
                await endActivity(activity)
            } else if !Self.isPending(activity), let state = stored?.resolve(attributes: activity.attributes, at: current) {
                await activity.update(ActivityContent(state: state, staleDate: staleDate(activity.attributes, in: stored)))
            }
        }
        // The system runs a refresh once: ask again for the next activity to retire.
        let remaining = Activity<ScheduleLiveActivityAttributes>.activities.filter { $0.activityState != .ended && $0.activityState != .dismissed }
        if let next = remaining.compactMap(\.attributes.reservationEnd).filter({ $0 > current }).min() { scheduleBackgroundWakeup?(next) }
    }
}

/// One token-mode activity as the server should know it: its token, never any course content.
nonisolated struct LiveActivityTokenRegistration: Equatable {
    var occurrenceId: String
    var token: String
    /// The end of an activity the app started on entry, which the server has no plan for.
    var end: Double? = nil
}
#endif
