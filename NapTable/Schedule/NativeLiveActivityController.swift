#if os(iOS) || LIVE_ACTIVITY_CHECKS
import ActivityKit
import Combine
import Foundation

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
    /// Asks the system to wake the app around an instant (see `LiveActivityBackgroundRefresh`).
    var scheduleBackgroundWakeup: ((Date) -> Void)?
    /// The timetable or a setting changed: the push service uploads it again.
    var planDidChange: (() -> Void)?
    /// A token-mode activity got a token, rotated it or went away: the push
    /// service reconciles the server's registrations.
    var activityTokensDidChange: (() -> Void)?
    /// The displayed timetable: the reader's own, or a followed share.
    private(set) var currentScheduleMetadata: NativeScheduleSnapshot?
    /// The reader's own timetable while `currentScheduleMetadata` is a followed share.
    private(set) var ownScheduleMetadata: NativeScheduleSnapshot?
    private(set) var display: LiveActivityDisplaySnapshot?
    private var task: Task<Void, Never>?
    private var retirementTask: Task<Void, Never>?
    private var epoch = 0
    private let now: () -> Date
    private let privacyDefaults: UserDefaults
    private let defaults: UserDefaults
    /// Activity ID → hex push token. Subscriptions live only as long as the process.
    private var activityTokens: [String: String] = [:]
    private var tokenObservers: [String: Task<Void, Never>] = [:]
    private var announcedTokens: [String] = []

    init(now: @escaping () -> Date = { .now }, privacyDefaults: UserDefaults = .standard) {
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
        if value { rebuild() } else { end(); status = .disabled }
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
        return LiveActivityTimeline.timetable(own: own, share: following ? snapshot : nil, choices: choices,
                                              lead: leadMinutes, sharedLead: sharedLeadMinutes, perPeriod: perPeriod)
    }
    func accept(_ snapshot: NativeScheduleSnapshot, own: NativeScheduleSnapshot? = nil) {
        guard !snapshot.cancelled else { return }
        // Activities of another table end; the server plans the new one once it is uploaded.
        if currentScheduleMetadata?.scheduleScope != snapshot.scheduleScope { end() }
        ownScheduleMetadata = snapshot.sourceLabel == nil ? nil : own
        currentScheduleMetadata = snapshot
        rebuild()
    }
    private func rebuild() {
        guard let snapshot = currentScheduleMetadata, !isPreviewActive else { return }
        epoch += 1
        task?.cancel()
        guard isEnabled else { status = .disabled; return }
        guard let scope = snapshot.scheduleScope else { status = .unavailable("课表缺少稳定身份，请重新打开课表。"); return }
        let built = LiveActivityTimeline.build(snapshot, own: ownScheduleMetadata, now: now(), lead: leadMinutes, sharedLead: sharedLeadMinutes,
                                               perPeriod: perPeriod, choices: choices)
        conflicts = built.conflicts
        omitted = built.omitted
        let value = LiveActivityDisplaySnapshot(scope: scope, sourceLabel: snapshot.sourceLabel, occurrences: built.occurrences)
        do { try value.save(); display = value }
        catch { status = .failed(error.localizedDescription); return }
        planDidChange?()
        let generation = epoch
        task = Task { [weak self] in
            guard let self else { return }
            await self.retirementTask?.value
            await self.reconcile(generation: generation)
        }
    }
    func setServiceFailure(_ reason: String) { status = .unavailable(reason) }
    /// Token-mode activities still running and their tokens. `live` also names
    /// those whose token this process has not received yet, so a cold start
    /// does not mistake them for gone.
    func tokenRegistrations() -> (registrations: [LiveActivityTokenRegistration], live: Set<String>) {
        guard let display else { return ([], []) }
        var registrations: [LiveActivityTokenRegistration] = []
        var live: Set<String> = []
        for activity in Activity<ScheduleLiveActivityAttributes>.activities where activity.attributes.pushMode == "token" &&
            activity.activityState != .ended && activity.activityState != .dismissed && activity.attributes.scheduleScope == display.scope {
            guard let id = activity.attributes.occurrenceId, (activity.attributes.reservationEnd ?? .distantPast) > now(), !live.contains(id) else { continue }
            live.insert(id)
            if let token = activityTokens[activity.id] { registrations.append(.init(occurrenceId: id, token: token)) }
        }
        return (registrations, live)
    }
    func observeTokens(of activity: Activity<ScheduleLiveActivityAttributes>) {
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
    /// Tokens can rotate and subscriptions die with the process, so every pass
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
    func foreground() { if !isPreviewActive { rebuild() } }
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
        guard #available(iOS 18.0, *) else {
            coverage = "iOS 17 仅支持预览"
            status = .unavailable("自动提醒需要 iOS 18 或更新版本；iOS 17 仍可预览效果。")
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { status = .unavailable("请在系统设置中允许实时活动。"); return }
        for activity in Activity<ScheduleLiveActivityAttributes>.activities where activity.activityState != .ended && activity.activityState != .dismissed {
            guard valid(generation) else { return }
            // One-time retirement is also safe after an interrupted upgrade.
            if (activity.attributes.reservationEnd ?? activity.content.state.endDate) <= now() ||
                activity.attributes.protocolVersion != 2 || activity.attributes.scheduleScope != display.scope {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        observeTokenActivities()
        defer { announceTokens() }
        let running = courseActivities.filter { $0.activityState == .active || $0.activityState == .stale }
        for activity in running {
            if let state = display.resolve(attributes: activity.attributes, at: now()) {
                await activity.update(ActivityContent(state: state, staleDate: staleDate(activity.attributes, in: display)))
            }
        }
        // Without a push at the end (offline), the next wakeup still retires it.
        if let end = running.compactMap(\.attributes.reservationEnd).min() { scheduleBackgroundWakeup?(end) }
        if case .limited = status { return }
        coverage = reservationCount > 0 ? "本机预约最近 \(reservationCount) 节，其余由服务端远程启动" : "由服务端远程启动"
        status = running.isEmpty ? .waiting : .active
    }
    /// Reserves the reminders the server handed to the phone and returns the
    /// ones to give back: those it could not reserve. A reservation the server
    /// no longer holds, or holds with other times, is withdrawn first.
    @available(iOS 26.0, *)
    func reserve(_ claims: [LiveActivityClaim]) async -> [String] {
        guard let display, isEnabled, !isPreviewActive else { return [] }
        await retirementTask?.value
        let current = now().timeIntervalSince1970
        let semester = currentScheduleMetadata?.data?.currentSemester ?? ""
        let wanted = Dictionary(claims.map { ($0.occurrenceId, $0.attributes(semester: semester)) }, uniquingKeysWith: { first, _ in first })
        for activity in courseActivities where activity.activityState == .pending {
            guard let id = activity.attributes.occurrenceId, wanted[id] != activity.attributes else { continue }
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        var release: [String] = []
        var accepted = 0
        var quotaReached = false
        var failure: String?
        for claim in claims.sorted(by: { $0.reminder < $1.reminder }) {
            let attributes = claim.attributes(semester: semester)
            if courseActivities.contains(where: { $0.attributes.occurrenceId == claim.occurrenceId }) { accepted += 1; continue }
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
                accepted += 1
            } catch {
                release.append(claim.occurrenceId)
                if Self.isCapacityError(error) { quotaReached = true } else { failure = error.localizedDescription }
            }
        }
        observeTokenActivities()
        announceTokens()
        coverage = "本机预约最近 \(reservationCount) 节，其余由服务端远程启动"
        if let failure { status = .unavailable(failure) }
        else if quotaReached {
            status = .limited(accepted > 0
                ? "本机已预约 \(accepted) 节，其余因系统名额限制交给服务端远程启动。"
                : "系统暂无可用的实时活动名额，提醒交给服务端远程启动。")
        } else if case .limited = status { status = .waiting }
        return release
    }
    private static func isCapacityError(_ error: Error) -> Bool {
        guard let error = error as? ActivityAuthorizationError else { return false }
        return error == .targetMaximumExceeded || error == .globalMaximumExceeded
    }
    func end() {
        epoch += 1
        task?.cancel()
        isPreviewActive = false
        let activities = Activity<ScheduleLiveActivityAttributes>.activities
        let tokens = activities.contains { $0.attributes.pushMode == "token" }
        retirementTask = Task { [weak self] in
            for activity in activities { await activity.end(nil, dismissalPolicy: .immediate) }
            // Lets the push service withdraw the ended activities' refreshes.
            if tokens { self?.announceTokens() }
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
                _ = try Activity<ScheduleLiveActivityAttributes>.request(attributes: .init(semester: "__preview__", dateKey: "preview"), content: ActivityContent(state: state, staleDate: state.endDate), pushType: nil)
                self.status = .active
            } catch {
                self.isPreviewActive = false
                self.status = Self.isCapacityError(error)
                    ? .limited("系统暂无可用的实时活动名额，请稍后重试预览。")
                    : .failed(error.localizedDescription)
            }
        }
    }
    /// The reservations the preview displaced come back with the next sync.
    func endPreview() { end(); rebuild() }
    func reconcileInBackground() async {
        guard !isPreviewActive else { return }
        let current = now()
        observeTokenActivities()
        let stored = display ?? LiveActivityDisplaySnapshot.load()
        for activity in Activity<ScheduleLiveActivityAttributes>.activities where activity.activityState != .ended && activity.activityState != .dismissed {
            if !isEnabled || (activity.attributes.reservationEnd ?? activity.content.state.endDate) <= current {
                await activity.end(nil, dismissalPolicy: .immediate)
            } else if !Self.isPending(activity), let state = stored?.resolve(attributes: activity.attributes, at: current) {
                await activity.update(ActivityContent(state: state, staleDate: staleDate(activity.attributes, in: stored)))
            }
        }
    }
}

/// One token-mode activity as the server should know it: its token, never any course content.
nonisolated struct LiveActivityTokenRegistration: Equatable {
    var occurrenceId: String
    var token: String
}
#endif
