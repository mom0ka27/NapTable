#if os(iOS) || LIVE_ACTIVITY_CHECKS
import ActivityKit
import Combine
import Foundation

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
    struct LedgerEntry: Codable {
        var activityID: String?
        var state: String
        var end: Double
    }
    static let shared = NativeLiveActivityController()
    static let enabledKey = "scheduleLiveActivityEnabled"
    static let leadMinutesKey = "scheduleLiveActivityLeadMinutes"
    static let defaultLeadMinutes = 60
    static let leadMinuteOptions = [15, 30, 60]
    static let perPeriodKey = "naptable.liveActivity.perPeriod"
    private static let ledgerKey = "naptable.liveActivity.v2.ledger"

    @Published private(set) var status: Status = .waiting
    @Published private(set) var isPreviewActive = false
    @Published private(set) var coverage = "尚未安排"
    @Published private(set) var conflicts: [LiveActivityTimeline.Conflict] = []
    @Published private(set) var omitted = 0
    var scheduleBackgroundWakeup: ((Date) -> Void)?
    var planDidChange: (() -> Void)?
    private(set) var currentScheduleMetadata: NativeScheduleSnapshot?
    private(set) var display: LiveActivityDisplaySnapshot?
    private(set) var mapping: LiveActivityMapping?
    private var handoffConfirmed = false
    private var submitted: Set<String> = []
    private var task: Task<Void, Never>?
    private var retirementTask: Task<Void, Never>?
    private var epoch = 0
    private let now: () -> Date
    private let privacyDefaults: UserDefaults
    private let defaults: UserDefaults
    private var ledger: [String: LedgerEntry]
    private var removedThisSession: Set<String> = []

    init(now: @escaping () -> Date = { .now }, privacyDefaults: UserDefaults = .standard) {
        self.privacyDefaults = privacyDefaults
        self.now = now
        defaults = UserDefaults(suiteName: NextWidgetConfiguration.appGroup) ?? .standard
        ledger = defaults.data(forKey: Self.ledgerKey).flatMap { try? JSONDecoder().decode([String: LedgerEntry].self, from: $0) } ?? [:]
        if !isEnabled { status = .disabled }
    }
    var isEnabled: Bool { PrivacyPolicy.liveAllowed(privacyDefaults) && (defaults.object(forKey: Self.enabledKey) as? Bool ?? true) }
    var leadMinutes: Int {
        let value = defaults.integer(forKey: Self.leadMinutesKey)
        return Self.leadMinuteOptions.contains(value) ? value : Self.defaultLeadMinutes
    }
    var leadTime: TimeInterval { Double(leadMinutes * 60) }
    var perPeriod: Bool { defaults.bool(forKey: Self.perPeriodKey) }

    func setEnabled(_ requested: Bool) {
        let value = requested && PrivacyPolicy.liveAllowed(privacyDefaults)
        defaults.set(value, forKey: Self.enabledKey)
        if value { rebuild() } else { end(); status = .disabled }
        #if os(iOS)
        if #available(iOS 17.2, *) { LiveActivityPushService.shared.enabledDidChange(value) }
        #endif
    }
    func setLeadMinutes(_ value: Int) {
        defaults.set(Self.leadMinuteOptions.contains(value) ? value : Self.defaultLeadMinutes, forKey: Self.leadMinutesKey)
        rebuild()
    }
    func setPerPeriod(_ value: Bool) { defaults.set(value, forKey: Self.perPeriodKey); rebuild() }
    func selectedSource(for conflict: LiveActivityTimeline.Conflict) -> String {
        guard let scope = currentScheduleMetadata?.scheduleScope else { return "" }
        return (defaults.dictionary(forKey: "naptable.liveActivity.conflicts." + scope) as? [String: String])?[conflict.id] ?? ""
    }
    func selectSource(_ source: String, for conflict: LiveActivityTimeline.Conflict) {
        guard let scope = currentScheduleMetadata?.scheduleScope else { return }
        let key = "naptable.liveActivity.conflicts." + scope
        var selections = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        selections[conflict.id] = source
        defaults.set(selections, forKey: key)
        rebuild()
    }
    func accept(_ snapshot: NativeScheduleSnapshot) {
        guard !snapshot.cancelled else { return }
        if let previousScope = currentScheduleMetadata?.scheduleScope, previousScope != snapshot.scheduleScope {
            #if os(iOS)
            if #available(iOS 17.2, *) { LiveActivityPushService.shared.invalidatePlan() }
            #endif
        }
        if currentScheduleMetadata?.scheduleScope != snapshot.scheduleScope {
            mapping = nil
            handoffConfirmed = false
            end()
        } else if currentScheduleMetadata?.periods != snapshot.periods || currentScheduleMetadata?.timeZone != snapshot.timeZone || currentScheduleMetadata?.schoolID != snapshot.schoolID {
            mapping = nil
            handoffConfirmed = false
            #if os(iOS)
            if #available(iOS 17.2, *) { LiveActivityPushService.shared.invalidatePlan() }
            #endif
            if #available(iOS 26.0, *) {
                let pending = Activity<ScheduleLiveActivityAttributes>.activities.filter { $0.activityState == .pending }
                for activity in pending { if let id = activity.attributes.occurrenceId { ledger[id] = nil } }
                saveLedger()
                retirementTask = Task { for activity in pending { await activity.end(nil, dismissalPolicy: .immediate) } }
            }
        }
        currentScheduleMetadata = snapshot
        rebuild()
    }
    private func rebuild() {
        guard let snapshot = currentScheduleMetadata, !isPreviewActive else { return }
        epoch += 1
        task?.cancel()
        guard isEnabled else { status = .disabled; return }
        guard let scope = snapshot.scheduleScope else { status = .unavailable("课表缺少稳定身份，请重新打开课表。"); return }
        let built = LiveActivityTimeline.build(snapshot, scope: scope, now: now(), lead: leadMinutes, perPeriod: perPeriod, defaults: defaults)
        conflicts = built.conflicts
        omitted = built.omitted
        let value = LiveActivityDisplaySnapshot(scope: scope, scheduleVersion: mapping?.scheduleVersion ?? "local", occurrences: built.occurrences)
        do { try value.save(); display = value }
        catch { status = .failed(error.localizedDescription); return }
        planDidChange?()
        let generation = epoch
        task = Task { [weak self] in
            guard let self else { return }
            await self.retirementTask?.value
            await self.reconcile(generation: generation)
            if #available(iOS 18.0, *) { return }
            while self.valid(generation) {
                let current = self.now().timeIntervalSince1970
                guard let boundary = self.display?.occurrences.flatMap({ [$0.reminder, $0.start, $0.end] }).filter({ $0 > current }).min() else { return }
                do { try await Task.sleep(for: .seconds(max(1, boundary - current))) } catch { return }
                await self.reconcile(generation: generation)
            }
        }
    }
    func applyMapping(_ value: LiveActivityMapping, localHandoff: Bool, submitted: Set<String>) {
        guard let snapshot = currentScheduleMetadata, snapshot.schoolID == value.schoolID,
              snapshot.periods.map({ LiveActivityMapping.Period(number: $0.number, start: $0.startTime, end: $0.endTime) }) == value.periods,
              snapshot.timeZone == value.timeZone else {
            mapping = nil
            handoffConfirmed = false
            setServiceFailure("课表节次或时区与学校作息不一致，请同步学校配置。")
            return
        }
        let changed = mapping != value || handoffConfirmed != localHandoff || self.submitted != submitted
        mapping = value
        handoffConfirmed = localHandoff
        self.submitted = submitted
        if changed { rebuild() }
    }
    func setServiceFailure(_ reason: String) { status = .unavailable(reason) }
    func foreground() {
        removedThisSession.removeAll()
        if !isPreviewActive { rebuild() }
    }
    func refreshForThemeChange() { rebuild() }
    func reset() {
        currentScheduleMetadata = nil
        display = nil
        mapping = nil
        defaults.removeObject(forKey: LiveActivityDisplaySnapshot.key)
        end()
        #if os(iOS)
        if #available(iOS 17.2, *) { LiveActivityPushService.shared.revoke() }
        #endif
    }
    func replanForPush() { planDidChange?() }

    private func saveLedger() {
        if let data = try? JSONEncoder().encode(ledger) { defaults.set(data, forKey: Self.ledgerKey) }
    }
    private func valid(_ generation: Int) -> Bool { generation == epoch && !Task.isCancelled && isEnabled && !isPreviewActive }
    private func attributes(_ occurrence: LiveActivityOccurrence, display: LiveActivityDisplaySnapshot) -> ScheduleLiveActivityAttributes {
        .init(semester: currentScheduleMetadata?.data?.currentSemester ?? "", dateKey: occurrence.item.dateKey,
              protocolVersion: 2, scheduleScope: display.scope, occurrenceId: occurrence.item.occurrenceId, scheduleVersion: display.scheduleVersion,
              reservationStart: Date(timeIntervalSince1970: occurrence.start), reservationEnd: Date(timeIntervalSince1970: occurrence.end),
              broadcastChannel: mapping?.channels[String(occurrence.item.endPeriod)], reminderDate: Date(timeIntervalSince1970: occurrence.reminder))
    }
    private func reconcile(generation: Int) async {
        guard valid(generation), let display else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { status = .unavailable("请在系统设置中允许实时活动。"); return }
        let current = now().timeIntervalSince1970
        let live = Activity<ScheduleLiveActivityAttributes>.activities.filter { $0.activityState != .ended && $0.activityState != .dismissed }
        for activity in live {
            guard valid(generation) else { return }
            // One-time retirement is also safe after an interrupted upgrade.
            if (activity.attributes.reservationEnd ?? activity.content.state.endDate) <= now() ||
                activity.attributes.protocolVersion != 2 || activity.attributes.scheduleScope != display.scope ||
                !display.occurrences.contains(where: { $0.item.occurrenceId == activity.attributes.occurrenceId }) {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        if #available(iOS 18.0, *) {
            guard let mapping else { status = .unavailable("等待学校作息映射；纯本地课表可使用前台预览。"); return }
            if #available(iOS 26.0, *) {
                guard handoffConfirmed else { status = .unavailable("等待完成远程模式交接，联网后重试。"); return }
                await reserve(display, mapping: mapping, generation: generation)
            } else {
                coverage = "远程启动：服务端滚动安排未来 48 小时"
                for activity in live where activity.attributes.scheduleScope == display.scope {
                    if let state = display.resolve(attributes: activity.attributes, at: now()) {
                        await activity.update(ActivityContent(state: state, staleDate: state.endDate))
                    }
                }
                status = live.isEmpty ? .waiting : .active
            }
        } else {
            coverage = "iOS 17 仅支持前台本地提醒"
            guard let occurrence = display.occurrences.first(where: { $0.reminder <= current && current < $0.end }), let state = occurrence.state(at: now()) else { status = .waiting; return }
            if let activity = live.first(where: { $0.attributes.occurrenceId == occurrence.item.occurrenceId }) {
                await activity.update(ActivityContent(state: state, staleDate: state.endDate))
            } else {
                do { _ = try Activity<ScheduleLiveActivityAttributes>.request(attributes: attributes(occurrence, display: display), content: ActivityContent(state: state, staleDate: state.endDate), pushType: nil) }
                catch { status = .failed(error.localizedDescription); return }
            }
            status = .active
            scheduleBackgroundWakeup?(Date(timeIntervalSince1970: occurrence.end))
        }
    }
    @available(iOS 26.0, *)
    private func reserve(_ display: LiveActivityDisplaySnapshot, mapping: LiveActivityMapping, generation: Int) async {
        let current = now().timeIntervalSince1970
        let desired = display.occurrences.filter { $0.end > current && $0.reminder < current + 168 * 3600 }.sorted { $0.reminder < $1.reminder }
        var accepted = 0
        var quotaReached = false
        var failure: String?
        for occurrence in desired {
            guard valid(generation) else { return }
            let id = occurrence.item.occurrenceId
            let attributes = attributes(occurrence, display: display)
            let all = Activity<ScheduleLiveActivityAttributes>.activities
            if let activity = all.first(where: { $0.attributes == attributes && $0.activityState != .ended && $0.activityState != .dismissed }) {
                ledger[id] = .init(activityID: activity.id, state: "scheduled", end: occurrence.end)
                if activity.activityState == .active || activity.activityState == .stale,
                   let state = display.resolve(attributes: activity.attributes, at: now()) {
                    await activity.update(ActivityContent(state: state, staleDate: Date(timeIntervalSince1970: occurrence.end)))
                }
                accepted += 1
                continue
            }
            // Changed configuration cancels only pending reservations; active instances keep their broadcast commitment.
            if let previous = all.first(where: { $0.attributes.occurrenceId == id && $0.activityState != .ended && $0.activityState != .dismissed }) {
                if previous.activityState == .active || previous.activityState == .stale { accepted += 1; continue }
                await previous.end(nil, dismissalPolicy: .immediate)
                ledger[id] = nil
            } else if ledger[id]?.state == "scheduled" {
                ledger[id]?.state = "removed"
                removedThisSession.insert(id)
            }
            guard !removedThisSession.contains(id), !submitted.contains(id),
                  occurrence.item.supersedes.allSatisfy({ !submitted.contains($0) }) else { continue }
            guard current < mapping.createBefore, occurrence.reminder < mapping.createBefore,
                  occurrence.end <= mapping.broadcastUntil, let channel = mapping.channels[String(occurrence.item.endPeriod)] else {
                failure = "部分频道缺失或映射已过期，联网后补充。"
                continue
            }
            guard !quotaReached else { continue }
            let plannedStart = max(current + 1, occurrence.reminder)
            guard plannedStart < occurrence.end, let state = occurrence.state(at: Date(timeIntervalSince1970: max(plannedStart, occurrence.reminder))) else { continue }
            ledger[id] = .init(activityID: nil, state: "requesting", end: occurrence.end)
            saveLedger()
            func request() throws -> Activity<ScheduleLiveActivityAttributes> {
                try Activity<ScheduleLiveActivityAttributes>.request(attributes: attributes, content: ActivityContent(state: state, staleDate: Date(timeIntervalSince1970: occurrence.end)), pushType: .channel(channel), style: .standard,
                    alertConfiguration: AlertConfiguration(title: "课程提醒", body: "即将上课", sound: .default), start: Date(timeIntervalSince1970: plannedStart))
            }
            do {
                let activity: Activity<ScheduleLiveActivityAttributes>
                do { activity = try request() }
                catch {
                    // Only a quota error can justify displacing a later pending slot.
                    guard Self.isCapacityError(error) else { throw error }
                    guard let victim = all.filter({ $0.activityState == .pending && ($0.attributes.reminderDate?.timeIntervalSince1970 ?? 0) > plannedStart }).max(by: { ($0.attributes.reminderDate ?? .distantPast) < ($1.attributes.reminderDate ?? .distantPast) }) else { throw error }
                    await victim.end(nil, dismissalPolicy: .immediate)
                    if let victimID = victim.attributes.occurrenceId { ledger[victimID] = nil }
                    guard valid(generation) else { return }
                    activity = try request()
                }
                ledger[id] = .init(activityID: activity.id, state: "scheduled", end: occurrence.end)
                accepted += 1
            } catch {
                if Self.isCapacityError(error) {
                    ledger[id]?.state = "waitingForCapacity"
                    quotaReached = true
                } else {
                    ledger[id]?.state = "failed"
                    failure = error.localizedDescription
                }
            }
            saveLedger()
        }
        ledger = ledger.filter { $0.value.end > current }
        saveLedger()
        coverage = "未来 168 小时已安排 \(accepted)/\(desired.count) 门课程" + (omitted > 0 ? "；\(omitted) 项无可靠时间，未安排" : "")
        if let failure { status = .unavailable(failure); return }
        if quotaReached {
            status = .limited(accepted > 0
                ? "已保留 \(accepted) 门课程的预约，其余课程因系统名额限制暂未安排。下次回到 App 时会尝试补充。"
                : "系统暂无可用的实时活动名额。下次回到 App 时会重新尝试安排。")
            return
        }
        status = (Activity<ScheduleLiveActivityAttributes>.activities.contains { $0.activityState == .active || $0.activityState == .stale } ? .active : .waiting)
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
        for activity in activities {
            if let id = activity.attributes.occurrenceId { ledger[id] = nil }
        }
        saveLedger()
        retirementTask = Task { for activity in activities { await activity.end(nil, dismissalPolicy: .immediate) } }
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
    func endPreview() { end(); rebuild() }
    func reconcileInBackground() async {
        guard !isPreviewActive else { return }
        let current = now()
        for activity in Activity<ScheduleLiveActivityAttributes>.activities {
            if !isEnabled || (activity.attributes.reservationEnd ?? activity.content.state.endDate) <= current {
                await activity.end(nil, dismissalPolicy: .immediate)
            } else if let state = LiveActivityDisplaySnapshot.resolveStored(attributes: activity.attributes, at: current) {
                await activity.update(ActivityContent(state: state, staleDate: state.endDate))
            }
        }
    }
}
#endif
