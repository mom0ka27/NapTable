import SwiftUI
import WidgetKit

/// The widget bundle: the three schedule widgets plus the Live Activity.
/// Ported from `../CPU-Web/ios_next` (CpuTime) `CPUWebWidgets/ScheduleWidgets.swift`.
/// CpuTime's timeline fetched a Web endpoint; this one reads the payload the app
/// writes into the shared App Group, so it works with no network at all.
#if os(iOS)
// 预览画廊把这份文件编进自己的 App，那边有自己的入口。
#if !WIDGET_GALLERY
@main
#endif
struct NapTableWidgetBundle: WidgetBundle {
    var body: some Widget {
        UpcomingScheduleWidget()
        TodayScheduleWidget()
        TwoDayScheduleWidget()
        liveActivity
    }

    private var liveActivity: some Widget {
        // WidgetBundleBuilder supports availability without an else branch.
        // Its public availability wrapper keeps one activity configuration
        // registered on both iOS 17 and versions with Watch family support.
        if #available(iOS 18.0, *) {
            return WidgetBundleBuilder.buildOptional(
                WidgetBundleBuilder.buildLimitedAvailability(ScheduleLiveActivityModernWidget())
            )
        }
        return WidgetBundleBuilder.buildOptional(
            WidgetBundleBuilder.buildLimitedAvailability(ScheduleLiveActivityWidget())
        )
    }
}

@available(iOS 18.0, *)
private struct ScheduleLiveActivityModernWidget: Widget {
    var body: some WidgetConfiguration {
        ScheduleLiveActivityWidget().body
            .supplementalActivityFamilies([.small, .medium])
    }
}

@available(iOS 16.1, *)
private struct ScheduleLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ScheduleLiveActivityAttributes.self) { context in
            ScheduleLiveActivityLockScreenContent(display: Self.display(context))
        } dynamicIsland: { context in
            let display = Self.display(context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading, priority: 1) {
                    ScheduleLiveActivityIslandLeading(display: display)
                }
                DynamicIslandExpandedRegion(.trailing, priority: 1) {
                    ScheduleLiveActivityIslandTrailing(display: display)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ScheduleLiveActivityIslandBottom(display: display)
                }
            } compactLeading: {
                ScheduleLiveActivityLogo(size: 21)
                    .accessibilityLabel("药大拾间课表")
            } compactTrailing: {
                ScheduleLiveActivityIslandCompactTrailing(display: display)
            } minimal: {
                ScheduleLiveActivityLogo(size: 21)
                    .accessibilityLabel("药大拾间课表")
            }
            // 左右和底部交给系统：`contentMargins(_:_:for: .expanded)` 是覆盖而不是
            // 叠加，之前把三边一起写死（18/8/10）比系统默认值窄，左上角的图标和右上角
            // 的「距上课」才会被胶囊圆角切掉。顶部归零：上边不是被圆角切到的那一侧，
            // 系统默认的上边距只会把内容白白往下压。
            .contentMargins(.top, 0, for: .expanded)
            .widgetURL(context.attributes.deepLinkURL)
            .keylineTint(ScheduleLiveActivityPalette.brand)
        }
    }

    private static func display(_ context: ActivityViewContext<ScheduleLiveActivityAttributes>) -> ScheduleLiveActivityDisplay {
        ScheduleLiveActivityDisplay(state: context.state, isStale: context.isStale, attributes: context.attributes)
    }
}

// 锁屏和灵动岛各块内容拆成独立视图：`ActivityConfiguration` 和预览画廊用的是同一份。

/// 锁屏（以及 iOS 18 起手表智能叠放）上的整张卡片。
@available(iOS 16.1, *)
private struct ScheduleLiveActivityLockScreenContent: View {
    let display: ScheduleLiveActivityDisplay

    var body: some View {
        // Past the content's stale date this course is over. The system
        // re-renders at that moment, which is the only callback available
        // to the extension: switch to the next class of the day, or to a
        // closing card until the app dismisses the activity.
        Group {
            if let state = display.state {
                if #available(iOS 18.0, *) {
                    ScheduleLiveActivityAdaptiveContent(state: state)
                } else {
                    ScheduleLiveActivityLockScreen(state: state)
                }
            } else if #available(iOS 18.0, *) {
                ScheduleLiveActivityAdaptiveFinished(title: display.closingTitle)
            } else {
                ScheduleLiveActivityFinishedCard(title: display.closingTitle)
            }
        }
    }
}

// The camera owns the centre of the expanded island. Put the
// title in the full-width bottom region rather than squeezing
// it between the logo, camera and a growing timer.
@available(iOS 16.1, *)
private struct ScheduleLiveActivityIslandLeading: View {
    let display: ScheduleLiveActivityDisplay

    var body: some View {
        HStack(spacing: 5) {
            ScheduleLiveActivityLogo(size: 24)
            Text(display.islandTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ScheduleLiveActivityPalette.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .topLeading)
        // `contentMargins(.top, 0)` 之外系统还给展开区留了一段固定上边距，
        // 只能用负 padding 顶回去。上沿不是被胶囊圆角切的那一侧，但也别
        // 再往上加了，否则会贴到灵动岛的黑边。
        .padding(.top, -8)
        // 放不下就整块挪到下面那一行，而不是被摄像头和圆角切掉。
        .dynamicIsland(verticalPlacement: .belowIfTooWide)
    }
}

@available(iOS 16.1, *)
private struct ScheduleLiveActivityIslandTrailing: View {
    let display: ScheduleLiveActivityDisplay

    var body: some View {
        // Merged rows carry one timer each; a third one up here
        // would only repeat the share's.
        if let state = display.state, state.companion == nil {
            ScheduleLiveActivityCountdown(state: state, compact: true, centered: true)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .topTrailing)
                .padding(.top, -8)
                .dynamicIsland(verticalPlacement: .belowIfTooWide)
        }
    }
}

@available(iOS 16.1, *)
private struct ScheduleLiveActivityIslandBottom: View {
    let display: ScheduleLiveActivityDisplay

    var body: some View {
        Group {
            if let state = display.state, state.companion != nil {
                ScheduleLiveActivityPairRows(state: state)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
            } else if let state = display.state {
                ScheduleLiveActivityExpandedDetails(state: state)
            } else {
                ScheduleLiveActivityFinishedRow(title: display.closingTitle)
            }
        }
        .padding(.top, 1)
    }
}

@available(iOS 16.1, *)
private struct ScheduleLiveActivityIslandCompactTrailing: View {
    let display: ScheduleLiveActivityDisplay

    var body: some View {
        Group {
            if let state = display.state {
                ScheduleLiveActivityTimer(state: state)
            } else {
                Text("已下课")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
        .foregroundStyle(ScheduleLiveActivityPalette.accent)
        .frame(width: 46, alignment: .trailing)
    }
}

/// Resolves what the activity should draw for a given render.
///
/// `context.isStale` is the only signal the widget extension gets when a
/// deadline passes: there is no timeline and no callback into the app, so the
/// stale render is where a finished class turns into the next countdown.
@available(iOS 16.1, *)
private struct ScheduleLiveActivityDisplay {
    /// `nil` once today has no course left to count down to.
    let state: ScheduleLiveActivityAttributes.ContentState?
    /// 今天是否还有下一节课。`afterEndState` 只认同一天的课，跨天就是 `nil`。
    private let hasMoreToday: Bool

    init(state: ScheduleLiveActivityAttributes.ContentState, isStale: Bool, attributes: ScheduleLiveActivityAttributes) {
        if attributes.protocolVersion == 2 {
            self.state = LiveActivityDisplaySnapshot.resolveStored(attributes: attributes, at: WidgetClock.now)
            self.hasMoreToday = false
            return
        }
        // A broadcast is only a clock marker, never displayable course content.
        // No local match means today's classes are over (or unavailable).
        guard let localState = state.broadcastDateKey == nil ? state : state.resolvedFromLocalSchedule(attributes: attributes) else {
            self.state = nil
            self.hasMoreToday = false
            return
        }
        let isStale = isStale || localState.endDate <= WidgetClock.now
        // Only a persistent activity carries on to the next class; otherwise
        // it is on its way out and should simply say the class is over.
        self.state = isStale && NextWidgetConfiguration.liveActivityIsPersistent
            ? localState.afterEndState
            : (isStale ? nil : localState)
        self.hasMoreToday = localState.afterEndState != nil
    }

    var islandTitle: String { state?.islandTitle ?? closingTitle }

    /// 今天还有课但这一节已经结束（非常驻马上就收起）时说「已下课」；今天没课了
    /// 就说「今日无课」，而不是预告明天的课。
    var closingTitle: String { hasMoreToday ? "已下课" : "今日无课" }
}

private extension ScheduleLiveActivityAttributes.ContentState {
    /// Broadcast pushes deliberately contain no course content. Resolve the
    /// boundary against the timetable written by the app into the App Group.
    func resolvedFromLocalSchedule(attributes: ScheduleLiveActivityAttributes) -> Self? {
        guard let dateKey = broadcastDateKey,
              let broadcastTimestamp,
              let payload = ScheduleWidgetStore.load(),
              let day = payload.knownDay(for: dateKey) else { return nil }
        let timestamp = max(broadcastTimestamp, WidgetClock.now)
        guard dateKey == attributes.dateKey else { return nil }
        if let end = attributes.reservationEnd, timestamp >= end { return nil }

        let datedCourses = day.courseList.compactMap { course -> (WidgetCourse, Date, Date)? in
            guard let start = Self.date(dateKey, time: course.startTime),
                  let end = Self.date(dateKey, time: course.endTime), end > start else { return nil }
            if let reserved = attributes.reservationStart, start != reserved { return nil }
            return (course, start, end)
        }.sorted { $0.1 < $1.1 }
        guard !datedCourses.isEmpty else { return nil }

        let currentIndex = datedCourses.firstIndex { $0.1 <= timestamp && timestamp < $0.2 }
        let selectedIndex = currentIndex ?? datedCourses.firstIndex { $0.1 > timestamp }
        guard let index = selectedIndex else { return nil }
        let selected = datedCourses[index]
        let next = datedCourses.dropFirst(index + 1).first
        let inProgress = currentIndex != nil
        let period = selected.0.startSlot.flatMap { start in
            selected.0.endSlot.map { end in
                start == end ? "第 \(start) 节" : "第 \(start)-\(end) 节"
            }
        }
        return Self(
            phase: inProgress ? .inProgress : .upcoming,
            courseName: selected.0.displayName,
            teacher: selected.0.normalizedTeacher ?? "",
            location: selected.0.normalizedLocation ?? "",
            periodLabel: period,
            dateLabel: day.displayLabel,
            weekRangeLabel: weekRangeLabel,
            startDate: selected.1,
            endDate: selected.2,
            nextCourseName: next?.0.displayName,
            nextCoursePeriod: next.flatMap { value in
                guard let start = value.0.startSlot, let end = value.0.endSlot else { return nil }
                return start == end ? "第 \(start) 节" : "第 \(start)-\(end) 节"
            },
            nextCourseDateLabel: day.displayLabel,
            nextCourseWeekRangeLabel: next?.0.slotNote,
            nextCourseTeacher: next?.0.normalizedTeacher,
            nextCourseLocation: next?.0.normalizedLocation,
            nextCourseStart: next?.1,
            nextCourseEnd: next?.2,
            sourceLabel: sourceLabel,
            adjustmentNote: day.normalizedNote,
            updatedAt: inProgress ? selected.1 : timestamp,
            broadcastDateKey: dateKey,
            broadcastPeriod: broadcastPeriod,
            broadcastPhase: broadcastPhase,
            broadcastTimestamp: timestamp
        )
    }

    private static func date(_ date: String, time: String?) -> Date? {
        guard let time, !time.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: "\(date) \(time.prefix(5))")
    }
}

@available(iOS 18.0, *)
private struct ScheduleLiveActivityAdaptiveFinished: View {
    @Environment(\.activityFamily) private var family

    let title: String

    var body: some View {
        ScheduleLiveActivityFinishedCard(title: title, compact: family == .small)
    }
}

@available(iOS 16.1, *)
private struct ScheduleLiveActivityFinishedCard: View {
    let title: String
    var compact = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = LiveActivityContentPalette(colorScheme: compact ? .dark : colorScheme)
        HStack(spacing: compact ? 8 : 12) {
            ScheduleLiveActivityLogo(size: compact ? 20 : 32)
            Text(title)
                .font(.system(size: compact ? 14 : 17, weight: .bold))
                .foregroundStyle(palette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, compact ? 12 : 21)
        .padding(.vertical, compact ? 10 : 16)
        .environment(\.liveActivityPalette, palette)
        .activityBackgroundTint(compact ? ScheduleLiveActivityPalette.surface : nil)
        .activitySystemActionForegroundColor(compact ? .white : .primary)
    }
}

/// The expanded island's bottom region once the day is over.
@available(iOS 16.1, *)
private struct ScheduleLiveActivityFinishedRow: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(ScheduleLiveActivityPalette.primaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
    }
}

@available(iOS 18.0, *)
private struct ScheduleLiveActivityAdaptiveContent: View {
    let state: ScheduleLiveActivityAttributes.ContentState
    @Environment(\.activityFamily) private var family

    var body: some View {
        switch family {
        case .small:
            ScheduleLiveActivityWatchCard(state: state)
        case .medium:
            ScheduleLiveActivityLockScreen(state: state)
        @unknown default:
            ScheduleLiveActivityLockScreen(state: state)
        }
    }
}

@available(iOS 16.1, *)
private struct ScheduleLiveActivityLockScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    let state: ScheduleLiveActivityAttributes.ContentState

    private var palette: LiveActivityContentPalette {
        LiveActivityContentPalette(colorScheme: colorScheme)
    }

    var body: some View {
        Group {
            if state.companion != nil { merged } else { content }
        }
        .environment(\.liveActivityPalette, palette)
        .activityBackgroundTint(nil)
        .activitySystemActionForegroundColor(.primary)
    }

    /// Both people in class: a slim header, then one row per timetable.
    /// The next-course line is dropped so the card stays within the Lock
    /// Screen's height budget.
    private var merged: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                ScheduleLiveActivityLogo(size: 24)
                Text(state.islandTitle)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let note = state.normalizedAdjustmentNote {
                    ScheduleLiveActivityAdjustmentChip(note: note)
                }
            }
            ScheduleLiveActivityPairRows(state: state, showsProgress: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 21)
        .padding(.vertical, 12)
        .background(gradient)
    }

    private var gradient: some View {
        LinearGradient(
            colors: [ScheduleLiveActivityPalette.brand.opacity(colorScheme == .dark ? 0.12 : 0.06), .clear],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                ScheduleLiveActivityLogo(size: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.courseName)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(ScheduleLiveActivityFormatting.timeRange(start: state.startDate, end: state.endDate))
                        .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(palette.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ScheduleLiveActivityCountdown(state: state)
            }

            ScheduleLiveActivityChips(state: state)
            ScheduleLiveActivityCourseDetails(state: state)
            ScheduleLiveActivityProgress(state: state)

            if state.hasNextCourse {
                ScheduleLiveActivityNextCourse(state: state)
                    .padding(.top, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // ActivityKit supplies the rounded background, not content insets.
        // Keep every baseline clear of its corners, including the next row.
        .padding(.horizontal, 21)
        .padding(.vertical, 14)
        .background(gradient)
    }
}

@available(iOS 16.1, *)
private struct ScheduleLiveActivityExpandedDetails: View {
    let state: ScheduleLiveActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(state.courseName)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(ScheduleLiveActivityPalette.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(ScheduleLiveActivityFormatting.timeRange(start: state.startDate, end: state.endDate))
                    .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(ScheduleLiveActivityPalette.secondaryText)
                    .fixedSize()
            }
            ScheduleLiveActivityChips(state: state)
            ScheduleLiveActivityCourseDetails(state: state)
            ScheduleLiveActivityProgress(state: state)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The bottom region is clipped by Dynamic Island's own capsule. Keep
        // the progress track and the metadata away from its lower corners.
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
    }
}

/// 共享课表的名字和调休说明排成一行。两者都没有时什么也不画。
@available(iOS 16.1, *)
private struct ScheduleLiveActivityChips: View {
    let state: ScheduleLiveActivityAttributes.ContentState

    var body: some View {
        let source = state.normalizedSourceLabel
        let note = state.normalizedAdjustmentNote
        if source != nil || note != nil {
            HStack(spacing: 6) {
                if let source { ScheduleLiveActivitySourceChip(name: source) }
                if let note { ScheduleLiveActivityAdjustmentChip(note: note) }
            }
        }
    }
}

/// 显示的是别人的课表时，标出是谁的。
@available(iOS 16.1, *)
private struct ScheduleLiveActivitySourceChip: View {
    @Environment(\.liveActivityPalette) private var palette
    let name: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "person.fill")
                .font(.system(size: 9, weight: .semibold))
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(palette.accent)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(palette.accent.opacity(0.16), in: Capsule())
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
        .accessibilityLabel("\(name)的课表")
    }
}

/// One line per timetable when the reader and the followed share are in
/// class at the same time: the share first (the activity follows it), the
/// reader's own course below. Course names share one leading edge; the
/// small tag on the second line says whose each one is.
@available(iOS 16.1, *)
private struct ScheduleLiveActivityPairRows: View {
    let state: ScheduleLiveActivityAttributes.ContentState
    var showsProgress = false
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            ScheduleLiveActivityPairRow(entry: .share(state), showsProgress: showsProgress, compact: compact)
            if let companion = state.companion {
                ScheduleLiveActivityPairRow(entry: .own(companion), showsProgress: showsProgress, compact: compact)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ScheduleLiveActivityPairEntry {
    let tag: String
    let isOwn: Bool
    let courseName: String
    let detail: String
    let inProgress: Bool
    let timer: ClosedRange<Date>
    let showsHours: Bool
    let progress: ClosedRange<Date>?

    static func share(_ state: ScheduleLiveActivityAttributes.ContentState) -> Self {
        Self(tag: state.normalizedSourceLabel ?? "共享", isOwn: false, courseName: state.courseName,
             detail: detail(location: state.location, teacher: state.teacher, period: state.periodLabel),
             inProgress: state.phase == .inProgress, timer: state.countdownInterval,
             showsHours: state.countdownShowsHours,
             progress: state.phase == .inProgress && state.endDate > state.startDate ? state.startDate...state.endDate : nil)
    }

    static func own(_ companion: ScheduleLiveActivityAttributes.ContentState.Companion) -> Self {
        let interval = companion.countdownInterval
        let inProgress = companion.phase == .inProgress
        return Self(tag: "我", isOwn: true, courseName: companion.courseName,
                    detail: detail(location: companion.location, teacher: companion.teacher, period: companion.periodLabel),
                    inProgress: inProgress, timer: interval,
                    showsHours: interval.upperBound.timeIntervalSince(interval.lowerBound) >= 3600,
                    progress: inProgress && companion.endDate > companion.startDate ? companion.startDate...companion.endDate : nil)
    }

    private static func detail(location: String, teacher: String, period: String?) -> String {
        [location.isEmpty ? teacher : location, period ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

@available(iOS 16.1, *)
private struct ScheduleLiveActivityPairRow: View {
    @Environment(\.liveActivityPalette) private var palette
    let entry: ScheduleLiveActivityPairEntry
    var showsProgress = false
    var compact = false

    /// The share takes the brand accent, the reader's own row a neutral tone,
    /// so the two can be told apart before either tag is read.
    private var tint: Color { entry.isOwn ? palette.primaryText.opacity(0.78) : palette.accent }

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 6 : 8) {
            Capsule()
                .fill(tint)
                .frame(width: 3)
                .padding(.vertical, 1)
            VStack(alignment: .leading, spacing: compact ? 1 : 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.courseName)
                        .font(.system(size: compact ? 13 : 15, weight: .bold))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ScheduleLiveActivityTimerText(interval: entry.timer, showsHours: entry.showsHours)
                        .font(.system(size: compact ? 12 : 15, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.trailing)
                        .frame(width: entry.showsHours ? 64 : 48, alignment: .trailing)
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(entry.tag)
                        .font(.system(size: compact ? 9 : 10, weight: .bold))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(tint.opacity(0.18), in: Capsule())
                        .frame(maxWidth: compact ? 44 : 72, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                    if !entry.detail.isEmpty {
                        Text(entry.detail)
                            .font(.system(size: compact ? 10 : 11, weight: .medium))
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    if !compact {
                        Text(entry.inProgress ? "距下课" : "距上课")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(palette.tertiaryText)
                            .fixedSize()
                    }
                }
                if showsProgress, let progress = entry.progress {
                    ScheduleLiveActivityTimerProgress(interval: progress)
                    .tint(tint)
                    .frame(height: 4)
                    .padding(.top, 1)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.isOwn ? "我" : entry.tag)：\(entry.courseName)，\(entry.inProgress ? "正在上课" : "即将上课")")
    }
}

/// 调休那天锁屏上多一行说明。补课日显示的是另一天的课，不说清楚就是一节
/// 看起来不该存在的课。
@available(iOS 16.1, *)
private struct ScheduleLiveActivityAdjustmentChip: View {
    @Environment(\.liveActivityPalette) private var palette
    let note: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 10, weight: .semibold))
            Text(note)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(ScheduleLiveActivityPalette.brand)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(ScheduleLiveActivityPalette.brand.opacity(0.12), in: Capsule())
    }
}

@available(iOS 16.1, *)
private struct ScheduleLiveActivityCourseDetails: View {
    @Environment(\.liveActivityPalette) private var palette
    let state: ScheduleLiveActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 10) {
            if !state.location.isEmpty {
                Text(state.location)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.78)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                if !state.teacher.isEmpty {
                    Text(state.teacher)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.72)
                }
                if let period = state.periodLabel, !period.isEmpty {
                    Text(period)
                        .fixedSize()
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(palette.secondaryText)
            .frame(maxWidth: .infinity, alignment: state.location.isEmpty ? .leading : .trailing)
        }
    }
}

@available(iOS 16.1, *)
private struct ScheduleLiveActivityCountdown: View {
    @Environment(\.liveActivityPalette) private var palette
    let state: ScheduleLiveActivityAttributes.ContentState
    var compact = false
    var centered = false

    var body: some View {
        VStack(alignment: centered ? .center : .trailing, spacing: compact ? 1 : 3) {
            Text(state.phase == .inProgress ? "距下课" : "距上课")
                .font(.system(size: compact ? 10 : 11, weight: .medium))
                .foregroundStyle(palette.accent)
            ScheduleLiveActivityTimer(state: state, alignment: centered ? .center : .trailing)
                .font(.system(size: compact ? 19 : 25, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(palette.accent)
        }
        // A timer Text intentionally consumes flexible width. Constraining
        // its column prevents it from stealing the title's width or centring
        // the digits in an unrelated part of the activity.
        .multilineTextAlignment(centered ? .center : .trailing)
        .frame(width: compact ? nil : 88, alignment: centered ? .center : .trailing)
        .frame(maxWidth: compact ? 69 : nil, alignment: centered ? .center : .trailing)
        .accessibilityElement(children: .combine)
    }
}

@available(iOS 16.1, *)
private struct ScheduleLiveActivityNextCourse: View {
    @Environment(\.liveActivityPalette) private var palette
    let state: ScheduleLiveActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
                .overlay(palette.divider)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("下一节")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.tertiaryText)
                    .fixedSize()
                Text([state.nextCourseName, state.nextCourseContext].compactMap { $0 }.joined(separator: "  "))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let start = state.nextCourseStart {
                    Text(ScheduleLiveActivityFormatting.timeRange(start: start, end: state.nextCourseEnd))
                        .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(palette.tertiaryText)
                        .lineLimit(1)
                        .frame(width: 80, alignment: .trailing)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 1)
    }
}

@available(iOS 16.1, *)
private struct ScheduleLiveActivityWatchCard: View {
    let state: ScheduleLiveActivityAttributes.ContentState

    var body: some View {
        // Smart Stack's mirrored small activity has a much shorter proposal
        // than the phone lock screen. Fit within it instead of overflowing a
        // six-row stack and losing the logo/top baseline to the system clip.
        ViewThatFits(in: .vertical) {
            if state.companion != nil {
                merged(showsHeader: true)
                merged(showsHeader: false)
            } else {
                content(showsTimeRange: true)
                content(showsTimeRange: false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .activityBackgroundTint(ScheduleLiveActivityPalette.surface)
        .activitySystemActionForegroundColor(.white)
    }

    private func merged(showsHeader: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if showsHeader {
                HStack(spacing: 5) {
                    ScheduleLiveActivityLogo(size: 16)
                    Text(state.islandTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ScheduleLiveActivityPalette.accent)
                        .lineLimit(1)
                }
            }
            ScheduleLiveActivityPairRows(state: state, compact: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func content(showsTimeRange: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                ScheduleLiveActivityLogo(size: 16)
                Text(state.courseName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(ScheduleLiveActivityPalette.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 4) {
                Text(state.phaseTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ScheduleLiveActivityPalette.accent)
                    .lineLimit(1)
                Spacer(minLength: 2)
                ScheduleLiveActivityTimer(state: state)
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(ScheduleLiveActivityPalette.primaryText)
                    .frame(width: 46, alignment: .trailing)
            }
            Text([state.normalizedSourceLabel ?? "", state.location.isEmpty ? state.teacher : state.location, state.periodLabel ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ScheduleLiveActivityPalette.secondaryText)
                .lineLimit(1)
            if showsTimeRange {
                Text(ScheduleLiveActivityFormatting.timeRange(start: state.startDate, end: state.endDate))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(ScheduleLiveActivityPalette.secondaryText)
                    .lineLimit(1)
            }
            ScheduleLiveActivityProgress(state: state)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

@available(iOS 16.1, *)
private struct ScheduleLiveActivityLogo: View {
    let size: CGFloat

    var body: some View {
        Image("CPUActivityLogo")
            .resizable()
            .renderingMode(.original)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 18 / 84, style: .continuous))
            .accessibilityHidden(true)
    }
}

@available(iOS 16.1, *)
private struct ScheduleLiveActivityProgress: View {
    @Environment(\.liveActivityPalette) private var palette
    let state: ScheduleLiveActivityAttributes.ContentState

    var body: some View {
        if state.phase == .inProgress, state.endDate > state.startDate {
            ScheduleLiveActivityTimerProgress(interval: state.startDate...state.endDate)
            .tint(palette.accent)
            .frame(height: 4)
            .accessibilityLabel("本节课程进度")
        }
    }
}

@available(iOS 16.1, *)
private struct ScheduleLiveActivityTimer: View {
    let state: ScheduleLiveActivityAttributes.ContentState
    var alignment: TextAlignment = .trailing

    var body: some View {
        let end = state.phase == .inProgress ? state.endDate : state.startDate
        // Use the content's stable origin, not Date.now. A stale render must
        // never create a reversed ClosedRange after the deadline has passed.
        ScheduleLiveActivityTimerText(
            interval: min(state.updatedAt, end)...end,
            showsHours: state.countdownShowsHours
        )
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .multilineTextAlignment(alignment)
    }
}

/// 系统按真实时间自己走的倒计时。预览画廊把时钟钉住时，换成那一刻的静态读数，
/// 否则出图时显示的是电脑当下的时间。
@available(iOS 16.1, *)
private struct ScheduleLiveActivityTimerText: View {
    let interval: ClosedRange<Date>
    let showsHours: Bool

    var body: some View {
        #if WIDGET_GALLERY
        if let now = WidgetClock.override {
            Text(Self.frozenLabel(interval: interval, showsHours: showsHours, now: now))
        } else {
            Text(timerInterval: interval, countsDown: true, showsHours: showsHours)
        }
        #else
        Text(timerInterval: interval, countsDown: true, showsHours: showsHours)
        #endif
    }

    #if WIDGET_GALLERY
    /// 和 `Text(timerInterval:)` 一样的写法：「4:59」「1:04:59」，不带小时时分钟可以超过 60。
    static func frozenLabel(interval: ClosedRange<Date>, showsHours: Bool, now: Date) -> String {
        let clamped = min(max(now, interval.lowerBound), interval.upperBound)
        let seconds = Int(interval.upperBound.timeIntervalSince(clamped).rounded(.down))
        if showsHours, seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    #endif
}

/// 本节课的进度条。画廊钉住时钟时同样换成静态进度。
@available(iOS 16.1, *)
private struct ScheduleLiveActivityTimerProgress: View {
    let interval: ClosedRange<Date>

    var body: some View {
        Group {
            #if WIDGET_GALLERY
            if let now = WidgetClock.override {
                // ProgressView 是 UIKit 画的，ImageRenderer 渲染不出来，照着线性样式自己画。
                let total = interval.upperBound.timeIntervalSince(interval.lowerBound)
                let fraction = total > 0 ? min(max(now.timeIntervalSince(interval.lowerBound) / total, 0), 1) : 0
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.3))
                        Capsule().fill(.tint).frame(width: proxy.size.width * fraction)
                    }
                }
                .frame(height: 4)
            } else {
                live
            }
            #else
            live
            #endif
        }
    }

    private var live: some View {
        ProgressView(timerInterval: interval, countsDown: false) {
            EmptyView()
        } currentValueLabel: {
            // The default timer progress label draws another clock below
            // the track even when its frame is only a few points tall.
            EmptyView()
        }
        .progressViewStyle(.linear)
    }
}

/// Defaults to dark for the black Dynamic Island and mirrored Watch card.
/// The Lock Screen supplies its system appearance to all shared content rows.
private struct LiveActivityContentPalette {
    var colorScheme: ColorScheme = .dark

    var primaryText: Color { colorScheme == .dark ? ScheduleLiveActivityPalette.primaryText : .primary }
    var secondaryText: Color { colorScheme == .dark ? ScheduleLiveActivityPalette.secondaryText : .secondary }
    var tertiaryText: Color { colorScheme == .dark ? ScheduleLiveActivityPalette.tertiaryText : .secondary }
    var divider: Color { colorScheme == .dark ? ScheduleLiveActivityPalette.divider : Color.primary.opacity(0.12) }
    var accent: Color {
        colorScheme == .dark ? ScheduleLiveActivityPalette.accent : ScheduleLiveActivityPalette.lightAccent
    }
}

private struct LiveActivityPaletteKey: EnvironmentKey {
    static let defaultValue = LiveActivityContentPalette()
}

private extension EnvironmentValues {
    var liveActivityPalette: LiveActivityContentPalette {
        get { self[LiveActivityPaletteKey.self] }
        set { self[LiveActivityPaletteKey.self] = newValue }
    }
}

private enum ScheduleLiveActivityPalette {
    private static var base: ScheduleLiveActivityRGB {
        let theme = NextWidgetConfiguration.globalTheme
        return theme == .custom ? NextWidgetConfiguration.globalCustomColor : theme.brandColor
    }

    static var brand: Color { color(from: base) }

    static var accent: Color {
        let value = base
        return Color(
            red: value.red + (1 - value.red) * 0.55,
            green: value.green + (1 - value.green) * 0.55,
            blue: value.blue + (1 - value.blue) * 0.55
        )
    }

    // Darken even very pale custom colors so countdown text stays legible
    // against the system's light Lock Screen material.
    static var lightAccent: Color {
        let value = base
        return Color(red: value.red * 0.48, green: value.green * 0.48, blue: value.blue * 0.48)
    }

    static var surface: Color {
        let value = base
        return Color(
            red: max(0.012, value.red * 0.12),
            green: max(0.016, value.green * 0.12),
            blue: max(0.018, value.blue * 0.12)
        )
    }

    static let primaryText = Color.white
    static let secondaryText = Color(red: 171 / 255, green: 183 / 255, blue: 184 / 255)
    static let tertiaryText = Color(red: 128 / 255, green: 143 / 255, blue: 144 / 255)
    static let divider = Color.white.opacity(0.16)

    private static func color(from value: ScheduleLiveActivityRGB) -> Color {
        Color(red: value.red, green: value.green, blue: value.blue)
    }
}

private enum ScheduleLiveActivityFormatting {
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    static func timeRange(start: Date, end: Date?) -> String {
        guard let end else { return clock.string(from: start) }
        return "\(clock.string(from: start))–\(clock.string(from: end))"
    }

    static func dayContext(for date: Date, relativeTo reference: Date) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: reference), to: calendar.startOfDay(for: date)).day
        if days == 0 { return nil }
        if days == 1 { return "明天" }
        return day.string(from: date)
    }
}

private extension ScheduleLiveActivityAttributes.ContentState {
    var phaseTitle: String { phase == .inProgress ? "正在上课" : "即将上课" }

    /// 自己也在上课时，标题说两边的关系；否则就是这节课的状态。
    /// 两边都在上课才说「同时在上课」；有一边在课间或还没开始，就报对方这节课的状态。
    var islandTitle: String {
        guard let companion else { return phaseTitle }
        if phase == .inProgress && companion.phase == .inProgress { return "同时在上课" }
        return "\(normalizedSourceLabel ?? "对方")\(phaseTitle)"
    }

    var hasNextCourse: Bool {
        !(nextCourseName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && nextCourseStart != nil
    }

    var nextCourseContext: String? {
        guard let start = nextCourseStart else { return nil }
        let value = [
            ScheduleLiveActivityFormatting.dayContext(for: start, relativeTo: startDate),
            nextCourseLocation,
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return value.isEmpty ? nil : value
    }
}

#endif

private struct UpcomingScheduleWidget: Widget {
    let kind = "me.mom0ka27.naptable.widget.upcoming"

    var body: some WidgetConfiguration {
        // 沿用原来的 kind：换成可编辑的配置后，已经放在桌面上的小组件照样在，取默认值。
        AppIntentConfiguration(
            kind: kind,
            intent: UpcomingScheduleWidgetIntent.self,
            provider: ScheduleIntentTimelineProvider<UpcomingScheduleWidgetIntent>()
        ) { entry in
            ScheduleWidgetRoot(entry: entry) { payload in
                UpcomingScheduleView(payload: payload)
            }
        }
        .configurationDisplayName("临近课程")
        .description("在桌面或锁屏显示当前与下一节课程。")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryInline,
            .accessoryCircular,
            .accessoryRectangular,
        ])
    }
}

private struct TodayScheduleWidget: Widget {
    let kind = "me.mom0ka27.naptable.widget.today"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: TodayScheduleWidgetIntent.self,
            provider: ScheduleIntentTimelineProvider<TodayScheduleWidgetIntent>()
        ) { entry in
            ScheduleWidgetRoot(entry: entry) { payload in
                TodayScheduleView(payload: payload)
            }
        }
        .configurationDisplayName("今日课表")
        .description("显示今日的完整课程安排。")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

private struct TwoDayScheduleWidget: Widget {
    let kind = "me.mom0ka27.naptable.widget.twoday"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: TwoDayScheduleWidgetIntent.self,
            provider: ScheduleIntentTimelineProvider<TwoDayScheduleWidgetIntent>()
        ) { entry in
            ScheduleWidgetRoot(entry: entry) { payload in
                TwoDayScheduleView(payload: payload)
            }
        }
        .configurationDisplayName("两日课表")
        .description("并排显示两日的课程安排。")
        .supportedFamilies([.systemLarge])
    }
}

private struct ScheduleWidgetColorfulCoursesKey: EnvironmentKey {
    static let defaultValue = true
}

private struct ScheduleWidgetThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = ScheduleWidgetTheme.colorGlass
}

private struct ScheduleWidgetDisplayOptionsEnvironmentKey: EnvironmentKey {
    static let defaultValue = ScheduleWidgetDisplayOptions.default
}

private struct ScheduleWidgetFamilyEnvironmentKey: EnvironmentKey {
    static let defaultValue = WidgetFamily.systemSmall
}

private extension EnvironmentValues {
    /// 关掉「纯色模式」时为 `true`：课程按课名分色，和 App 课表一致。
    var scheduleWidgetColorfulCourses: Bool {
        get { self[ScheduleWidgetColorfulCoursesKey.self] }
        set { self[ScheduleWidgetColorfulCoursesKey.self] = newValue }
    }

    var scheduleWidgetTheme: ScheduleWidgetTheme {
        get { self[ScheduleWidgetThemeEnvironmentKey.self] }
        set { self[ScheduleWidgetThemeEnvironmentKey.self] = newValue }
    }

    var scheduleWidgetDisplayOptions: ScheduleWidgetDisplayOptions {
        get { self[ScheduleWidgetDisplayOptionsEnvironmentKey.self] }
        set { self[ScheduleWidgetDisplayOptionsEnvironmentKey.self] = newValue }
    }

    /// 小组件尺寸。系统的 `widgetFamily` 只读，`ScheduleWidgetRoot` 把它转存到这里，
    /// 预览画廊才能在 App 里按指定尺寸渲染。下面的视图一律读这个。
    var scheduleWidgetFamily: WidgetFamily {
        get { self[ScheduleWidgetFamilyEnvironmentKey.self] }
        set { self[ScheduleWidgetFamilyEnvironmentKey.self] = newValue }
    }
}

private struct ScheduleWidgetRoot<Content: View>: View {
    let entry: ScheduleEntry
    /// 只有预览画廊会传：App 里没有系统给的 `widgetFamily`。
    var familyOverride: WidgetFamily? = nil
    @ViewBuilder let content: (WidgetSchedulePayload) -> Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetFamily) private var systemFamily

    private var family: WidgetFamily { familyOverride ?? systemFamily }

    var body: some View {
        let theme = NextWidgetConfiguration.scheduleTheme
        let displayOptions = NextWidgetConfiguration.displayOptions
        return Group {
            switch entry.state {
            case .loaded(let payload):
                content(payload)
                    .overlayPreferenceValue(FireworksOriginKey.self) { anchor in
                        if let anchor {
                            GeometryReader { proxy in
                                // 按下那一刻身份不能变：整层换身份时是整块替进来，碎片的出场动画不放。
                                // 收起时反过来要换，见 `ScheduleEntry.fireworksRound`。
                                FireworksOverlay(active: entry.celebrating, origin: proxy[anchor])
                                    .id(entry.fireworksRound)
                            }
                            .allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if let source = payload.sourceLabel, !source.isEmpty {
                            Text("关注：\(source)")
                                .font(.system(size: 9, weight: .semibold))
                                .lineLimit(1)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.thinMaterial, in: Capsule())
                                .padding(5)
                        }
                    }
            case .unconfigured:
                WidgetMessageView(
                    symbol: "rectangle.stack.badge.plus",
                    title: "等待课表同步",
                    detail: "请打开 App，在课表右上角菜单进入“课表与设备设置”"
                )
            case .failed(let message):
                WidgetMessageView(
                    symbol: "exclamationmark.arrow.triangle.2.circlepath",
                    title: "课表读取失败",
                    detail: message
                )
            }
        }
        .environment(\.scheduleWidgetTheme, theme)
        .environment(\.scheduleWidgetColorfulCourses, !NextWidgetConfiguration.solidCourseColors)
        .environment(\.scheduleWidgetDisplayOptions, displayOptions)
        .environment(\.scheduleWidgetConfiguration, entry.configuration)
        .environment(\.scheduleWidgetCelebrating, entry.celebrating)
        .environment(\.scheduleWidgetFamily, family)
        .widgetURL(entry.appURL)
        .containerBackground(for: .widget) {
            if family.isAccessory {
                Color.clear
            } else {
                WidgetPalette.background(for: colorScheme)
            }
        }
    }
}

private extension WidgetFamily {
    var isAccessory: Bool {
        self == .accessoryInline || self == .accessoryCircular || self == .accessoryRectangular
    }
}

private struct WidgetMessageView: View {
    let symbol: String
    let title: String
    let detail: String
    @Environment(\.scheduleWidgetTheme) private var theme
    @Environment(\.scheduleWidgetFamily) private var family

    @ViewBuilder
    var body: some View {
        switch family {
        case .accessoryInline:
            Label(title, systemImage: symbol)
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .widgetAccentable()
            }
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .semibold))
                    .widgetAccentable()
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .bold))
                    Text(detail)
                        .font(.system(size: 10))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(WidgetPalette.accent(for: theme))
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(WidgetPalette.primary)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(WidgetPalette.secondary)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(2)
        }
    }
}

private struct UpcomingScheduleView: View {
    let payload: WidgetSchedulePayload
    @Environment(\.scheduleWidgetFamily) private var family
    @Environment(\.scheduleWidgetConfiguration) private var configuration

    @ViewBuilder
    var body: some View {
        let selection = payload.upcoming(afterClass: configuration.afterClass)
        // 「接着显示下一次课」把今天换成了别的日子：课程正上方挂一条「明天 周二」。
        // 课程照常上色，压暗是「已经上完」的意思，拿来表示明天的课会被看成上过了。
        let otherDay = OtherDay.offset(of: selection.0) == nil ? nil : selection.0
        if family.isAccessory {
            LockScreenScheduleView(day: selection.0, courses: selection.1)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                // 换到别的日子时日期栏照旧是今天，靠课程上方的标注说明下面是哪天的课。
                WidgetDateHeader(
                    day: otherDay == nil ? selection.0 : payload.currentDay(),
                    tableName: payload.title
                )
                Spacer(minLength: 8)

                if selection.1.isEmpty {
                    RestStateView(hadCourses: !payload.currentDay().courseList.isEmpty)
                } else if family == .systemMedium {
                    let labels = Self.columnLabels(first: selection.1[0], otherDay: otherDay != nil)
                    // 两栏一起用大一号的字，课名折行、屏幕又小时一起退回原来的字号，两边不会一大一小。
                    // 两节都是别的日子的：标注横跨两栏占一行，两栏不再各自写标题。只挂在左栏的话，
                    // 和右栏的「接下来」并排，像是左边明天、右边接下来。
                    ViewThatFits(in: .vertical) {
                        ForEach([CourseSummary.Size.large, .regular], id: \.self) { size in
                            VStack(alignment: .leading, spacing: 7) {
                                if let otherDay {
                                    OtherDayBanner(day: otherDay)
                                }
                                HStack(alignment: .top, spacing: 14) {
                                    UpcomingColumn(
                                        label: otherDay == nil ? labels.first : nil,
                                        course: selection.1.first,
                                        size: size
                                    )
                                    Divider()
                                    UpcomingColumn(
                                        label: otherDay == nil ? labels.second : nil,
                                        course: selection.1.count > 1 ? selection.1[1] : nil,
                                        size: size
                                    )
                                }
                            }
                        }
                    }
                    .layoutPriority(1)
                } else if let course = selection.1.first {
                    // 默认只放一节：当前这节，没在上课就是接下来那节。「编辑小组件」里可以改成两节。
                    if configuration.upcomingCourseCount > 1 && selection.1.count > 1 {
                        // 两节挤在小号里：第一节课名只占一行，第二节不再另起标题。
                        if let otherDay {
                            OtherDayBanner(day: otherDay)
                                .padding(.bottom, 6)
                        }
                        CourseSummary(course: course, size: .regular, titleLines: 1)
                        Spacer(minLength: 6)
                        CompactNextCourse(course: selection.1[1])
                    } else {
                        // 只放一节时中间空着一大块：像中号一样标上「当前」「下一节」，字也大一号。
                        // 课名折成两行、屏幕又小时放不下，先去标题，再退回原来的字号；
                        // 别的日子的标注不能去，只退字号。
                        // 大屏上多出来的高度全压在日期和课程之间会显得空：放得下时底下也垫一点，
                        // 空白分到上下两边；小屏照旧贴底。
                        let label = Self.columnLabels(first: course, otherDay: otherDay != nil).first
                        ViewThatFits(in: .vertical) {
                            ForEach([14, 8, 0] as [CGFloat], id: \.self) { bottom in
                                UpcomingColumn(label: label, course: course, size: .large, otherDay: otherDay)
                                    .padding(.bottom, bottom)
                            }
                            if otherDay != nil {
                                UpcomingColumn(label: label, course: course, size: .regular, otherDay: otherDay)
                            } else {
                                CourseSummary(course: course, size: .large)
                                CourseSummary(course: course, size: .regular)
                            }
                        }
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        // 先把高度让给它，上面的 Spacer 只留最小的 8，ViewThatFits 才量得准。
                        .layoutPriority(1)
                    }
                }
            }
        }
    }

    /// 中号两栏（小号一节）的标题。第一节还没开始时叫「当前」就错了：那是下一节。
    /// 别的日子的课换成「明天 周二」标注，用不到这里的字。
    private static func columnLabels(first: WidgetCourse, otherDay: Bool) -> (first: String, second: String) {
        if otherDay { return ("第一节", "接下来") }
        if first.isInProgress(at: WidgetSchedulePayload.minutesSinceMidnight(WidgetClock.now)) { return ("当前", "接下来") }
        return ("下一节", "之后")
    }
}

private struct LockScreenScheduleView: View {
    let day: WidgetDay
    let courses: [WidgetCourse]
    @Environment(\.scheduleWidgetFamily) private var family
    @Environment(\.scheduleWidgetDisplayOptions) private var options

    @ViewBuilder
    var body: some View {
        switch family {
        case .accessoryInline:
            inlineView
        case .accessoryCircular:
            circularView
        default:
            rectangularView
        }
    }

    private var inlineView: some View {
        Label {
            if let course = courses.first {
                Text(inlineText(course))
            } else {
                Text(inlineEmptyText)
            }
        } icon: {
            Image(systemName: courses.isEmpty ? "calendar.badge.checkmark" : "book.closed.fill")
        }
        .lineLimit(1)
    }

    /// 单行锁屏只有一句话的位置：祝福 → 假期倒计时 → 「今日无课」。
    private var inlineEmptyText: String {
        RestState.inlineText(options: options)
    }

    private var circularView: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let course = courses.first {
                VStack(spacing: 0) {
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .widgetAccentable()
                    if options.showTime {
                        Text(course.startLabel)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .minimumScaleFactor(0.72)
                    }
                    if let primary = options.primaryValue(for: course), primary != course.timeRange {
                        Text(primary)
                            .font(.system(size: 8, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                    }
                }
                .padding(5)
            } else {
                VStack(spacing: 1) {
                    Image(systemName: "calendar.badge.checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .widgetAccentable()
                    Text("无课")
                        .font(.system(size: 9, weight: .bold))
                }
            }
        }
    }

    private var rectangularView: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: courses.isEmpty ? "calendar.badge.checkmark" : "book.closed.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .widgetAccentable()
                // 换到了别的日子时带上「明天」，锁屏上只有这一行说明是哪天。
                Text([OtherDay.label(for: day) ?? "", day.compactDate, day.displayLabel].filter { !$0.isEmpty }.joined(separator: " "))
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 2)
                if courses.count > 1 {
                    Text("下一节 \(courses[1].startLabel)")
                        .font(.system(size: 9, weight: .medium))
                        .lineLimit(1)
                }
            }
            if let course = courses.first {
                if let primary = options.primaryValue(for: course) {
                    Text(primary)
                        .font(.system(size: 14, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                if let metadata = options.metadata(for: course) {
                    Text(metadata)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                if options.showTime {
                    Text(course.timeRange)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            } else {
                let lines = emptyLines
                Text(lines.primary)
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                if let secondary = lines.secondary {
                    Text(secondary)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// 休息状态：有假期就大字写假期、小字写「4 天后 · 10.1 - 10.7 · 休 7 天」，没有才说「今日无课」。
    private var emptyLines: (primary: String, secondary: String?) {
        guard let holiday = RestState.holiday(options: options) else {
            return ("今日无课", "打开课表查看本周安排")
        }
        return (holiday.title, "\(holiday.caption) · \(holiday.detail)")
    }

    private func inlineText(_ course: WidgetCourse) -> String {
        [
            OtherDay.label(for: day) ?? day.shortLabel,
            options.showTime ? course.startLabel : nil,
            options.primaryValue(for: course),
            options.metadata(for: course)
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }
}

private struct UpcomingColumn: View {
    /// 没有就不留标题行（中号标注已经横跨两栏写在上面）。
    let label: String?
    let course: WidgetCourse?
    var size: CourseSummary.Size = .regular
    /// 课是别的日子的：标题换成「明天 周二」「3 天后 10.1 周四」。
    var otherDay: WidgetDay? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // 标注带胶囊底色，比纯文字的标题高：两种都占一样高，换不换日子课的位置都不跳。
            if let otherDay {
                OtherDayBanner(day: otherDay)
            } else if let label {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WidgetPalette.secondary)
                    .frame(height: OtherDayBanner.height, alignment: .leading)
            }
            if let course {
                CourseSummary(course: course, size: size)
            } else {
                Text("暂无课程")
                    .font(.system(size: 11))
                    .foregroundStyle(WidgetPalette.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CourseSummary: View {
    enum Size {
        /// 小号放两节时的第一节，和中号两栏。
        case regular
        /// 小号只放一节。
        case large

        var title: CGFloat { self == .large ? 17 : 15 }
        var metadata: CGFloat { self == .large ? 11 : 10 }
        var time: CGFloat { self == .large ? 12 : 11 }
    }

    let course: WidgetCourse
    var size: Size = .regular
    var titleLines = 2
    @Environment(\.scheduleWidgetTheme) private var theme
    @Environment(\.scheduleWidgetColorfulCourses) private var colorfulCourses
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scheduleWidgetDisplayOptions) private var options

    var body: some View {
        // 色条跟着文字一样高，不拉到底。
        HStack(alignment: .top, spacing: 9) {
            RoundedRectangle(cornerRadius: 3)
                .fill(WidgetPalette.accent(for: course, theme: theme, colorful: colorfulCourses, colorScheme: colorScheme))
                .frame(width: 5)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 3) {
                if let primary = options.primaryValue(for: course) {
                    Text(primary)
                        .font(.system(size: size.title, weight: .bold))
                        .foregroundStyle(WidgetPalette.primary)
                        .lineLimit(titleLines)
                        .minimumScaleFactor(0.76)
                }
                if let metadata = options.metadata(for: course) {
                    Text(metadata)
                        .font(.system(size: size.metadata))
                        .foregroundStyle(WidgetPalette.secondary)
                        .lineLimit(1)
                }
                if options.showTime {
                    Text(course.timeRange)
                        .font(.system(size: size.time, weight: .semibold))
                        .foregroundStyle(WidgetPalette.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CompactNextCourse: View {
    let course: WidgetCourse
    @Environment(\.scheduleWidgetTheme) private var theme
    @Environment(\.scheduleWidgetColorfulCourses) private var colorfulCourses
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scheduleWidgetDisplayOptions) private var options

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(WidgetPalette.accent(for: course, theme: theme, colorful: colorfulCourses, colorScheme: colorScheme))
                .frame(width: 5, height: 27)
            VStack(alignment: .leading, spacing: 1) {
                if let primary = options.primaryValue(for: course) {
                    Text(primary)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(WidgetPalette.primary)
                        .lineLimit(1)
                }
                if options.showTime {
                    Text(course.timeRange)
                        .font(.system(size: 9))
                        .foregroundStyle(WidgetPalette.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

private struct TodayScheduleView: View {
    let payload: WidgetSchedulePayload
    @Environment(\.scheduleWidgetFamily) private var family
    @Environment(\.scheduleWidgetConfiguration) private var configuration

    var body: some View {
        let now = WidgetClock.now
        let today = payload.currentDay(now: now)
        let nowMinutes = today.date == WidgetSchedulePayload.dateString(now)
            ? WidgetSchedulePayload.minutesSinceMidnight(now)
            : nil
        let finished = payload.remainingCourses(in: today, now: now).isEmpty
        // 今天上完了（或本来没课）：「接着显示下一次课」换成那一天的课，日期栏照旧是今天、课程上方标出是哪天；
        // 「只看今天」把上完的课灰着留在原处。都没有可列的课才显示休息状态。
        let next = finished && configuration.afterClass == .nextCourseDay
            ? payload.nextCourseDay(after: now)
            : nil
        let rests = today.courseList.isEmpty || (finished && configuration.afterClass == .nextCourseDay)
        Group {
            if let next {
                courseList(day: next.day, nowMinutes: nil, otherDay: true, headerDay: today)
            } else if rests {
                // 休息状态不参与下面按行数挑排法；假期和临近课程一样贴着底边放。
                VStack(alignment: .leading, spacing: 0) {
                    WidgetDateHeader(day: today, tableName: payload.title)
                    // 大号放假当天和两日课表一样：图标、祝福和假期进度占住中间，不再只有底下一小段。
                    if family == .systemLarge, today.courseList.isEmpty,
                       let greeting = ChineseCalendarInfo.restGreeting(for: now) {
                        HolidayGreetingView(greeting: greeting)
                    } else {
                        Spacer(minLength: 8)
                        RestStateView(hadCourses: !today.courseList.isEmpty)
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                courseList(day: today, nowMinutes: nowMinutes)
            }
        }
        // 大号的课排不满时，系统默认把整块内容竖着居中，日期栏就飘在半空；贴顶放。
        .frame(maxHeight: family == .systemLarge ? .infinity : nil, alignment: .top)
    }

    private var spacing: CGFloat { family == .systemLarge ? 8 : 7 }
    /// 时间线只在大号上有：中号只放两门课，排不出时间线。
    private var usesTimeline: Bool { family == .systemLarge && configuration.layout == .timeline }

    /// `otherDay`：换到了最近有课的另一天，日期栏照旧是今天（`headerDay`），课程上方挂「明天 周二」。课程不压暗：压暗是「已经上完」。
    @ViewBuilder
    private func courseList(
        day: WidgetDay,
        nowMinutes: Int?,
        otherDay: Bool = false,
        headerDay: WidgetDay? = nil
    ) -> some View {
        let maxLimit = family == .systemLarge ? 7 : 2
        if family == .systemLarge {
            // 大号写死 7 行放不下，多出来的课会被悄悄截掉。从多到少试，挑第一个放得下的，
            // 这样「后面还有几门」才数得准。
            ViewThatFits(in: .vertical) {
                ForEach(Array(stride(from: maxLimit, through: 1, by: -1)), id: \.self) { limit in
                    courses(today: day, nowMinutes: nowMinutes, limit: limit, otherDay: otherDay, headerDay: headerDay)
                }
            }
        } else {
            // 中号固定两门，提示跟在下面。两门课加日期栏已经快把高度用满了：放不下时
            // 先收日期栏和第一门课之间的距离（最宽 12，不低于 5），再把两门课之间的间隔
            // 一档档收，但不低于 4，再挤就粘在一起了；提示和上面那门课之间的距离不动。
            // 还放不下（小屏手机）才把提示贴到右下角，往下探进系统留的边距里。
            // 别的日子多一条标注：标注和课是一组，贴着课（4～6），日期栏离标注至少和
            // 课与课之间一样远，不然标注像是日期栏的附注。
            let window = day.courseWindow(limit: maxLimit, nowMinutes: nowMinutes)
            let gaps: [(header: CGFloat, banner: CGFloat, row: CGFloat)] = otherDay
                ? [(12, 6, 7), (10, 6, 7), (9, 5, 6), (8, 4, 6), (7, 4, 5), (6, 4, 4)]
                : [(12, 0, 7), (10, 0, 7), (8, 0, 7), (5, 0, 7), (5, 0, 6), (5, 0, 5), (5, 0, 4)]
            let tightest = gaps[gaps.count - 1]
            ViewThatFits(in: .vertical) {
                ForEach(Array(gaps.enumerated()), id: \.offset) { _, gap in
                    courses(
                        today: day, nowMinutes: nowMinutes, limit: maxLimit,
                        headerGap: gap.header, bannerGap: gap.banner, rowSpacing: gap.row,
                        otherDay: otherDay, headerDay: headerDay
                    )
                }
                courses(
                    today: day, nowMinutes: nowMinutes, limit: maxLimit,
                    headerGap: tightest.header, bannerGap: tightest.banner, rowSpacing: max(tightest.row, 5),
                    showsRemaining: false, otherDay: otherDay, headerDay: headerDay
                )
                    .frame(maxHeight: .infinity, alignment: .top)
                    .overlay(alignment: .bottomTrailing) {
                        if window.remainingCount > 0 {
                            remainingText(window.remainingCount)
                                .offset(y: 8)
                        }
                    }
            }
        }
    }

    private func courses(
        today: WidgetDay,
        nowMinutes: Int?,
        limit: Int,
        headerGap: CGFloat = 14,
        bannerGap: CGFloat = 8,
        rowSpacing: CGFloat? = nil,
        showsRemaining: Bool = true,
        otherDay: Bool = false,
        headerDay: WidgetDay? = nil
    ) -> some View {
        let window = today.courseWindow(limit: limit, nowMinutes: nowMinutes)
        return VStack(alignment: .leading, spacing: 0) {
            // 日期栏和第一门课拉开得比课与课之间松，不然日期像是第一门课的标题。
            WidgetDateHeader(day: headerDay ?? today, tableName: payload.title)
                // 大号的日期栏字大，本身就压得住，和第一门课之间不用拉那么开，省下的高度多放一门课。
                .padding(.bottom, family == .systemLarge ? headerGap - 3 : headerGap)
            if otherDay {
                OtherDayBanner(day: today)
                    .padding(.bottom, bannerGap)
            }
            if usesTimeline {
                DayTimeline(courses: window.courses, nowMinutes: nowMinutes)
            } else {
                VStack(alignment: .leading, spacing: rowSpacing ?? spacing) {
                    ForEach(Array(window.courses.enumerated()), id: \.offset) { _, course in
                        TodayCourseRow(
                            course: course,
                            large: family == .systemLarge,
                            timeOnSeparateLine: false,
                            completed: nowMinutes.map { course.hasEnded(at: $0) } ?? false,
                            verticalPadding: family == .systemLarge ? nil : 3
                        )
                    }
                }
            }
            if showsRemaining && window.remainingCount > 0 {
                // 和上面那门课拉开一点，不然像是那门课的附注。
                remainingText(window.remainingCount)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, family == .systemLarge ? 10 : 8)
            }
        }
        // 时间线要把剩下的高度吃满，不能按理想高度钉死；ViewThatFits 量的仍是理想高度，挑行数不受影响。
        .fixedSize(horizontal: false, vertical: !usesTimeline)
    }

    /// 没显示的都排在最后一行之后（已经上完的才会被省在前面），所以说「后面」。
    private func remainingText(_ count: Int) -> some View {
        Text("后面还有 \(count) 门课")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(WidgetPalette.muted)
            .lineLimit(1)
    }
}

private struct TodayCourseRow: View {
    let course: WidgetCourse
    let large: Bool
    let timeOnSeparateLine: Bool
    let completed: Bool
    /// 色块上下的留白；中号今日课表要挤出两门课之间的间隔，会传得小一点。
    var verticalPadding: CGFloat? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scheduleWidgetTheme) private var theme
    @Environment(\.scheduleWidgetColorfulCourses) private var colorfulCourses
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.scheduleWidgetDisplayOptions) private var options

    var body: some View {
        HStack(spacing: large ? 9 : 6) {
            RoundedRectangle(cornerRadius: 3)
                .fill(WidgetPalette.accent(for: course, theme: theme, colorful: colorfulCourses, colorScheme: colorScheme))
                .frame(width: 5, height: large ? 40 : (timeOnSeparateLine ? 39 : 29))
            VStack(alignment: .leading, spacing: 2) {
                if let primary = options.primaryValue(for: course) {
                    Text(primary)
                        .font(.system(size: large ? 14 : 12, weight: .bold))
                        .foregroundStyle(WidgetPalette.primary)
                        .lineLimit(1)
                }
                if let metadata = options.metadata(for: course) {
                    Text(metadata)
                        .font(.system(size: large ? 10 : 9, weight: .medium))
                        .foregroundStyle(WidgetPalette.secondary)
                        .lineLimit(1)
                }
                if timeOnSeparateLine && options.showTime {
                    timeLabel
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !timeOnSeparateLine && options.showTime {
                Spacer(minLength: 5)
                timeLabel
            }
        }
        .padding(.horizontal, large ? 9 : 7)
        .padding(.vertical, verticalPadding ?? (large ? 6 : 4))
        .background {
            RoundedRectangle(cornerRadius: large ? 11 : 8)
                .fill(
                    renderingMode == .fullColor
                        ? WidgetPalette.tint(for: course, colorScheme: colorScheme, theme: theme, colorful: colorfulCourses)
                        : Color.white
                )
                // Clear and tinted Home Screen appearances render widgets in
                // accented mode and remap opaque colors to solid white.
                .opacity(renderingMode == .fullColor ? 1 : 0.14)
        }
        .saturation(completed ? 0 : 1)
        .opacity(completed ? 0.56 : 1)
    }

    private var timeLabel: some View {
        Text(course.timeRange)
            .font(.system(size: large ? 10 : 9, weight: .semibold))
            .foregroundStyle(WidgetPalette.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
    }
}

/// 时间线：左边一列起止时间，课程卡片和课间按时长分高度，把给它的高度用满。
/// 课少的日子不再是三张卡片堆在顶上、下面空一半；课多时退回每门课最矮的样子，照旧一门挨一门。
/// 大号今日课表用整宽的；两日课表每列只有半宽，用 `compact` 的小一号。
private struct DayTimeline: View {
    let courses: [WidgetCourse]
    let nowMinutes: Int?
    var compact = false
    @Environment(\.scheduleWidgetDisplayOptions) private var options

    /// 课间短于这个就只留一道缝，不写「休息」。
    private static let labeledGap = 30

    var body: some View {
        let metrics = TimelineMetrics(compact: compact)
        ProportionalStack {
            ForEach(Array(courses.enumerated()), id: \.offset) { index, course in
                if index > 0 {
                    let gap = Self.gapMinutes(from: courses[index - 1], to: course)
                    TimelineGap(
                        minutes: gap,
                        labeled: gap >= Self.labeledGap,
                        showsTimeColumn: options.showTime,
                        isNow: nowMinutes.map { courses[index - 1].hasEnded(at: $0) && !course.hasEnded(at: $0) && !course.isInProgress(at: $0) } ?? false,
                        metrics: metrics
                    )
                    // 课间按一半的比例长高：午休两个多小时不该比一门课还高。
                    .layoutValue(key: ProportionalWeight.self, value: CGFloat(gap) * 0.5)
                    .layoutValue(key: ProportionalMaxHeight.self, value: gap >= Self.labeledGap ? metrics.labeledGapCap : 12)
                }
                TimelineCourseRow(
                    course: course,
                    completed: nowMinutes.map { course.hasEnded(at: $0) } ?? false,
                    inProgress: nowMinutes.map { course.isInProgress(at: $0) } ?? false,
                    metrics: metrics
                )
                .layoutValue(key: ProportionalWeight.self, value: CGFloat(Self.duration(of: course)))
                // 一天只有一两门课时卡片别撑成一整面墙。
                .layoutValue(key: ProportionalMaxHeight.self, value: metrics.cardCap)
            }
        }
    }

    private static func duration(of course: WidgetCourse) -> Int {
        guard let start = course.startMinutes else { return 45 }
        return max(course.endMinutes - start, 20)
    }

    private static func gapMinutes(from previous: WidgetCourse, to next: WidgetCourse) -> Int {
        guard let start = next.startMinutes, previous.endMinutes > 0 else { return 0 }
        return max(start - previous.endMinutes, 0)
    }
}

private struct ProportionalWeight: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}

private struct ProportionalMaxHeight: LayoutValueKey {
    static let defaultValue: CGFloat = .infinity
}

/// 竖着排：先给每个子视图它的理想高度，多出来的高度按权重分，谁都不超过自己的上限。
/// 没给高度（ViewThatFits 量尺寸时）就按理想高度排，所以「放不放得下」照旧按最紧的样子算。
private struct ProportionalStack: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let heights = heights(width: width, height: proposal.height, subviews: subviews)
        return CGSize(width: width, height: heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let heights = heights(width: bounds.width, height: bounds.height, subviews: subviews)
        var y = bounds.minY
        for (subview, height) in zip(subviews, heights) {
            subview.place(
                at: CGPoint(x: bounds.minX, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: height)
            )
            y += height
        }
    }

    private func heights(width: CGFloat, height: CGFloat?, subviews: Subviews) -> [CGFloat] {
        let ideal = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        guard let height, height > ideal.reduce(0, +) else { return ideal }
        let caps = zip(subviews, ideal).map { cap, ideal in
            let limit = cap[ProportionalMaxHeight.self]
            return limit.isFinite ? max(limit, ideal) : ideal
        }
        // VStack 拿无限高来探能长多高：照实报上限，它才知道这块能伸，把剩下的高度分过来。
        guard height.isFinite else { return caps }
        let weights = subviews.map { $0[ProportionalWeight.self] }
        func layout(_ scale: CGFloat) -> [CGFloat] {
            (0..<subviews.count).map { min(max(weights[$0] * scale, ideal[$0]), caps[$0]) }
        }
        // 找一个每分钟多少点的比例，让总高刚好填满；全顶到上限还填不满就停在上限，剩下的空在底下。
        var low: CGFloat = 0
        var high: CGFloat = 1
        while layout(high).reduce(0, +) < height && high < 64 { high *= 2 }
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if layout(mid).reduce(0, +) < height { low = mid } else { high = mid }
        }
        return layout(low)
    }
}

/// 竖着挑第一个放得下的子视图，和 `ViewThatFits(in: .vertical)` 一样，只是量理想高度（没给高度）时
/// 报最后一个、也就是最矮的那个。`ViewThatFits` 这时报的是第一个，时间线就会以为每张卡片最矮也要三行，
/// 课多的日子少放一门。没选中的挪到画面外，不显示。
private struct FirstThatFitsVertically: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let last = subviews.last else { return .zero }
        let width = proposal.width
        guard let height = proposal.height, height.isFinite else {
            return last.sizeThatFits(ProposedViewSize(width: width, height: nil))
        }
        let index = chosen(width: width, height: height, subviews: subviews)
        let ideal = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width ?? ideal.width, height: max(height, ideal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let index = chosen(width: bounds.width, height: bounds.height, subviews: subviews)
        for (offset, subview) in subviews.enumerated() {
            if offset == index {
                subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
            } else {
                subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY - 10_000), anchor: .topLeading, proposal: .unspecified)
            }
        }
    }

    private func chosen(width: CGFloat?, height: CGFloat, subviews: Subviews) -> Int {
        subviews.indices.first { subviews[$0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height <= height + 0.5 }
            ?? subviews.count - 1
    }
}

/// 时间线的尺寸。`compact` 是两日课表半宽的列：时间列、字号、边距都收一号，课名才留得下地方。
private struct TimelineMetrics {
    let timeColumn: CGFloat
    let columnSpacing: CGFloat
    let cardPadding: CGFloat
    let barSpacing: CGFloat
    let startFont: CGFloat
    let endFont: CGFloat
    let titleFont: CGFloat
    let metaFont: CGFloat
    let gapFont: CGFloat
    let cornerRadius: CGFloat
    let cardCap: CGFloat
    let labeledGapCap: CGFloat

    init(compact: Bool) {
        timeColumn = compact ? 31 : 38
        columnSpacing = compact ? 5 : 8
        cardPadding = compact ? 7 : 9
        barSpacing = compact ? 6 : 9
        startFont = compact ? 11 : 12
        endFont = compact ? 9 : 10
        titleFont = compact ? 12 : 14
        metaFont = compact ? 9 : 10
        gapFont = compact ? 9 : 10
        cornerRadius = compact ? 9 : 11
        cardCap = compact ? 96 : 108
        labeledGapCap = compact ? 36 : 44
    }

    /// 卡片左边色条中线离卡片左边的距离，课间的虚线对着它。
    var barCenter: CGFloat { cardPadding + 2.5 }
}

private struct TimelineCourseRow: View {
    let course: WidgetCourse
    let completed: Bool
    let inProgress: Bool
    let metrics: TimelineMetrics
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scheduleWidgetTheme) private var theme
    @Environment(\.scheduleWidgetColorfulCourses) private var colorfulCourses
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.scheduleWidgetDisplayOptions) private var options

    var body: some View {
        let accent = WidgetPalette.accent(for: course, theme: theme, colorful: colorfulCourses, colorScheme: colorScheme)
        HStack(alignment: .top, spacing: metrics.columnSpacing) {
            if options.showTime {
                // 开始时间对着卡片顶，结束时间对着卡片底：卡片被拉高时，一眼看得出这门课有多长。
                VStack(alignment: .trailing, spacing: 0) {
                    Text(course.startLabel)
                        .font(.system(size: metrics.startFont, weight: .bold))
                        .foregroundStyle(inProgress ? accent : WidgetPalette.primary)
                    Spacer(minLength: 2)
                    if let end = endLabel {
                        Text(end)
                            .font(.system(size: metrics.endFont, weight: .medium))
                            .foregroundStyle(WidgetPalette.secondary)
                    }
                }
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.vertical, 2)
                .frame(width: metrics.timeColumn, alignment: .trailing)
                .frame(maxHeight: .infinity)
            }
            HStack(alignment: .top, spacing: metrics.barSpacing) {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(accent)
                    .frame(width: 5)
                    .frame(maxHeight: .infinity)
                // 教室贴着卡片底边（和左边的下课时间对齐），课名、老师照旧在上面，卡片拉高时中间空出来。
                // 课多挤成最矮、放不下三行时退回原来的两行：课名，下面「教室 · 老师」。
                FirstThatFitsVertically {
                    if let room {
                        VStack(alignment: .leading, spacing: 2) {
                            titleText
                            if let teacher { metaText(teacher) }
                            Spacer(minLength: 2)
                            metaText(room)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        titleText
                        if let metadata = options.metadata(for: course) { metaText(metadata) }
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, metrics.cardPadding)
            .padding(.vertical, 5)
            .frame(maxHeight: .infinity, alignment: .top)
            .background {
                RoundedRectangle(cornerRadius: metrics.cornerRadius)
                    .fill(
                        renderingMode == .fullColor
                            ? WidgetPalette.tint(for: course, colorScheme: colorScheme, theme: theme, colorful: colorfulCourses)
                            : Color.white
                    )
                    .opacity(renderingMode == .fullColor ? 1 : 0.14)
            }
        }
        .saturation(completed ? 0 : 1)
        .opacity(completed ? 0.56 : 1)
    }

    @ViewBuilder
    private var titleText: some View {
        if let primary = options.primaryValue(for: course) {
            Text(primary)
                .font(.system(size: metrics.titleFont, weight: .bold))
                .foregroundStyle(WidgetPalette.primary)
        }
    }

    private func metaText(_ value: String) -> some View {
        Text(value)
            .font(.system(size: metrics.metaFont, weight: .medium))
            .foregroundStyle(WidgetPalette.secondary)
    }

    /// 放在左下角的教室。关了课程名时教室已经顶上去当标题了，不再写一遍。
    private var room: String? {
        options.showCourseName && options.showRoom ? course.normalizedLocation : nil
    }

    /// 课名下面的老师。课程名、教室都关了时老师自己就是标题。
    private var teacher: String? {
        options.showTeacher && (options.showCourseName || options.showRoom) ? course.normalizedTeacher : nil
    }

    private var endLabel: String? {
        guard course.startMinutes != nil, course.timeRange.contains(" - ") else { return nil }
        return course.timeRange.components(separatedBy: " - ").last
    }
}

/// 两门课之间：一道对着色条的虚线，长的课间在旁边写上歇多久。
private struct TimelineGap: View {
    let minutes: Int
    let labeled: Bool
    let showsTimeColumn: Bool
    /// 现在正好在这段课间里。
    let isNow: Bool
    let metrics: TimelineMetrics
    @Environment(\.scheduleWidgetTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            if showsTimeColumn {
                Color.clear.frame(width: metrics.timeColumn + metrics.columnSpacing)
            }
            if labeled {
                HStack(spacing: metrics.barSpacing - 1) {
                    DashedLine()
                        .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [0.1, 4]))
                        .foregroundStyle(WidgetPalette.muted)
                        .frame(width: 2)
                        .padding(.leading, metrics.barCenter - 1)
                    Text(isNow ? "休息中 · \(Self.duration(minutes))" : "休息 \(Self.duration(minutes))")
                        .font(.system(size: metrics.gapFont, weight: .semibold))
                        .foregroundStyle(isNow ? WidgetPalette.accent(for: theme) : WidgetPalette.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.vertical, 5)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 6, maxHeight: .infinity, alignment: .leading)
    }

    static func duration(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest) 分钟" }
        return rest == 0 ? "\(hours) 小时" : "\(hours) 小时 \(rest) 分"
    }
}

private struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY + 3))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - 3))
        }
    }
}

private struct TwoDayScheduleView: View {
    let payload: WidgetSchedulePayload
    @Environment(\.scheduleWidgetConfiguration) private var configuration

    var body: some View {
        let now = WidgetClock.now
        let today = payload.currentDay(now: now)
        let tomorrowDate = WidgetSchedulePayload.dateString(
            Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now
        )
        // 左边固定是今天（没课就说没课、道祝福），右边是今天之后最近有课的一天，跳过周末和
        // 放假；三周内都没课时照旧是明天。
        let next = payload.nextCourseDay(after: now)
        let right = next?.day ?? payload.fullDay(for: tomorrowDate, fallbackOffset: 1)

        // 右边不是明天时标上「后天的课」「10/2 的课」。左边占着同样一行但不显示，两列的课才对得齐。
        let rightHint = (next?.offset ?? 1) > 1 ? OtherDay.hint(for: right) : nil
        // 两天同一周，「第 N 周」只在右边写一次：靠着组件右上角，读起来是整块的标题。
        let sameWeek = today.week != nil && today.week == right.week
        let leftHeader = WidgetDateHeader(
            day: today, compact: true, tableName: payload.title, dayHint: rightHint, hidesDayHint: true,
            hidesWeek: sameWeek
        )
        let rightHeader = WidgetDateHeader(
            day: right, compact: true, tableName: payload.title, hidesTableName: true, dayHint: rightHint
        )
        HStack(alignment: .top, spacing: 13) {
            DayColumn(
                day: today,
                nowMinutes: WidgetSchedulePayload.minutesSinceMidnight(now),
                isToday: true,
                timeline: configuration.layout == .timeline,
                header: leftHeader,
                companionHeader: rightHeader
            )
            Divider()
            DayColumn(
                day: right,
                nowMinutes: nil,
                timeline: configuration.layout == .timeline,
                header: rightHeader,
                companionHeader: leftHeader
            )
        }
    }
}

private struct DayColumn: View {
    let day: WidgetDay
    let nowMinutes: Int?
    /// 明天那一列没课就照常说「没有课程」，祝福只属于今天。
    var isToday = false
    /// 用半宽的时间线排课，不然是一门课一张卡片的列表。
    var timeline = false
    let header: WidgetDateHeader
    /// 旁边那一列的日期栏，藏在自己的下面占位：只有一边有调休、节日时两边一样高，
    /// 两列的第一节课才对得齐。
    let companionHeader: WidgetDateHeader

    var body: some View {
        let window = day.courseWindow(limit: 5, nowMinutes: nowMinutes)
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topLeading) {
                companionHeader.hidden()
                header
            }
                // 日期栏和下面的课拉开到 18（加上外面 VStack 的 7），比课与课之间松。
                .padding(.bottom, 11)
            if day.courseList.isEmpty {
                // 这一支本来就是「这天没有课」，所以今天那列固定说「今日无课」；
                // 今天是法定假日就换成带图标和假期进度的祝福，整列不再只有一行灰字。
                if isToday, let greeting = ChineseCalendarInfo.restGreeting(for: WidgetClock.now) {
                    HolidayGreetingView(greeting: greeting)
                } else {
                    EmptyCoursesView(
                        message: isToday ? RestState.message() : "没有课程"
                    )
                }
            } else if timeline {
                DayTimeline(courses: window.courses, nowMinutes: nowMinutes, compact: true)
            } else {
                ForEach(Array(window.courses.enumerated()), id: \.offset) { _, course in
                    TodayCourseRow(
                        course: course,
                        large: false,
                        timeOnSeparateLine: true,
                        completed: nowMinutes.map { course.hasEnded(at: $0) } ?? false
                    )
                }
            }
        }
        // 时间线要往下铺满整列；列表照旧按内容高度贴顶。
        .frame(maxWidth: .infinity, maxHeight: timeline ? .infinity : nil, alignment: .topLeading)
    }
}

private struct WidgetDateHeader: View {
    let day: WidgetDay
    /// 两日课表的列只有半个组件宽：右侧的节日徽标在那里放不下。
    var compact = false
    /// 当前课表名，放在第二行最左边。两日课表只在今天那一列写一次。
    var tableName: String? = nil
    /// 课表名只占位不显示（两日课表明天那一列）。
    var hidesTableName = false
    /// 显示的不是今天的课时，第二行右边的标注：「明天的课」「10/2 的课」。
    var dayHint: String? = nil
    /// 标注只占位不显示（两日课表今天那一列，和旁边一列对齐）。
    var hidesDayHint = false
    /// 不写「第 N 周」：两日课表两天同一周时，只在右边那列写一次。
    var hidesWeek = false
    @Environment(\.scheduleWidgetTheme) private var theme
    @Environment(\.scheduleWidgetDisplayOptions) private var options
    @Environment(\.scheduleWidgetFamily) private var family

    /// 大号整块都是今天的课，日期栏是全场的标题，字放大一号；两日课表虽然也是大号，
    /// 但每列只有半宽（`compact`），照旧用小字。
    private var isLarge: Bool { family == .systemLarge && !compact }
    /// 在默认字号上加多少。
    private var sizeBoost: CGFloat { isLarge ? 3 : 0 }
    /// 竖线和竖排字的高度，也就是左边日期数字的高度。
    private var columnHeight: CGFloat { isLarge ? 32 : 24 }

    var body: some View {
        // 「周五」「初八」各自竖排成一列，日期、星期、农历之间各一条竖线。
        let isCompact = compact || family == .systemSmall
        // 两行之间几乎不留空：竖线本身比字高，行距再拉开就散了。
        VStack(alignment: .leading, spacing: 0) {
            header(isCompact: isCompact)
            secondaryLine
                // 竖线比字高，靠负边距把这行收回去，贴着上一行的文字底部。「明天的课」带着
                // 胶囊底色，比字高，再往上收就压住上一行的「第 N 周」，反过来留一点空。
                .padding(.top, dayHint == nil ? -2 : 4)
        }
    }

    /// 第二行：左边课表名、调休，右边「明天的课」。挤不下时先去课表名，「明天的课」
    /// 要一直在，调休一句话自己都放不下时交给它自己的缩字。
    @ViewBuilder
    private var secondaryLine: some View {
        let note = day.normalizedNote.flatMap { repeatsBadge($0) ? nil : $0 }
        let trimmedName = tableName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 只占位的课表名碰上调休：这一行已经有调休撑着了，别把它往右推。
        let name: String? = trimmedName.isEmpty || (hidesTableName && note != nil) ? nil : trimmedName
        if note != nil || name != nil || dayHint != nil {
            ViewThatFits(in: .horizontal) {
                secondaryRow(name: name, note: note)
                secondaryRow(name: nil, note: note)
                if dayHint != nil {
                    secondaryRow(name: nil, note: nil)
                }
                if let note {
                    AdjustmentNoteChip(note: note)
                }
            }
        }
    }

    private func secondaryRow(name: String?, note: String?) -> some View {
        HStack(spacing: 6) {
            if let name {
                Text(name)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(WidgetPalette.muted)
                    .lineLimit(1)
                    .fixedSize()
                    .opacity(hidesTableName ? 0 : 1)
            }
            if let note {
                AdjustmentNoteChip(note: note)
                    .fixedSize()
            }
            Spacer(minLength: 4)
            if let dayHint {
                OtherDayChip(title: dayHint)
                    .fixedSize()
                    .opacity(hidesDayHint ? 0 : 1)
            }
        }
    }

    private func header(isCompact: Bool) -> some View {
        let weekday = day.displayLabel.isEmpty ? nil : day.displayLabel
        // 小号一行要塞下日期、星期、农历和「第 N 周」，各列之间收紧一点。
        return HStack(spacing: isCompact ? 4 : (isLarge ? 8 : 6)) {
            // 小号里一行很挤，日期绝不能被压得折行，宁可让右边的周数让位。
            Text(day.compactDate)
                .font(.system(size: isLarge ? 26 : 19, weight: .bold, design: .rounded))
                .foregroundStyle(WidgetPalette.primary)
                .lineLimit(1)
                .fixedSize()

            columnDivider

            if let weekday {
                verticalText(
                    weekday,
                    weight: .bold,
                    color: weekday == "周六" || weekday == "周日"
                        ? Color.pink
                        : WidgetPalette.accent(for: theme)
                )
            }

            if weekday != nil, stackedDetail != nil {
                columnDivider
            }

            if let detail = stackedDetail {
                verticalText(detail, weight: .medium, color: detailColor)
            }

            Spacer(minLength: 4)

            if !isCompact, let badge = badgeText {
                HolidayBadge(title: badge, highlighted: calendarDay?.isStatutoryHoliday ?? false)
            }

            if !hidesWeek, let week = day.week, week > 0 {
                // 放不下「第 N 周」先去掉空格、再缩字，都放不下才不显示；「第」不省，
                // 单写「5周」像是说五个星期。也别去挤左边的日期。
                ViewThatFits(in: .horizontal) {
                    weekLabel("第 \(week) 周")
                    weekLabel("第\(week)周")
                    // 大号放大了字，挤不下先退回原来的字号，再往下缩。
                    if sizeBoost > 0 {
                        weekLabel("第 \(week) 周", size: 10)
                        weekLabel("第\(week)周", size: 10)
                    }
                    weekLabel("第\(week)周", size: 9)
                    weekLabel("第\(week)周", size: 8)
                    Color.clear.frame(width: 0, height: 0)
                }
            }
        }
    }

    /// 不给字号就是这个尺寸的默认字号（大号放大过）。
    private func weekLabel(_ text: String, size: CGFloat? = nil) -> some View {
        Text(text)
            .font(.system(size: size ?? 10 + min(sizeBoost, 2), weight: .semibold))
            .foregroundStyle(WidgetPalette.secondary)
            .lineLimit(1)
            .fixedSize()
    }

    private var columnDivider: some View {
        Rectangle()
            .fill(WidgetPalette.muted.opacity(0.45))
            .frame(width: 1, height: columnHeight)
    }

    /// 一个字一行的竖排。两个字排完正好和左边的日期一样高；三个字的节日名
    /// （中秋节、国庆节）收一号字，免得把日期栏撑高。
    private func verticalText(_ value: String, weight: Font.Weight, color: Color) -> some View {
        let characters = Array(value)
        let size: CGFloat = (characters.count > 2 ? 8 : 10) + sizeBoost
        return VStack(spacing: characters.count > 2 ? -1 : 0) {
            ForEach(Array(characters.enumerated()), id: \.offset) { _, character in
                Text(String(character))
                    .font(.system(size: size, weight: weight))
                    .foregroundStyle(color)
            }
        }
        .fixedSize()
        // 三个字收了字号也还比两个字高一点：按竖线的高度占位，多出来的上下各探出一点，
        // 日期栏不会因为今天是国庆节就比旁边高。
        .frame(height: columnHeight)
    }

    private var calendarDay: ChineseCalendarDay? {
        guard let date = day.date else { return nil }
        return ChineseCalendarInfo.info(forDate: date)
    }

    private var badgeText: String? {
        guard options.showHoliday else { return nil }
        return calendarDay?.badge
    }

    /// 服务端自动生成的放假说明就是假期名本身（「中秋节」），而节日名已经在右侧徽标
    /// （窄组件是星期旁那一列）里了，再在下面写一遍就重复了。
    private func repeatsBadge(_ note: String) -> Bool {
        guard let badgeText else { return false }
        return note == badgeText || note == badgeText + "放假" || badgeText.hasPrefix(note)
    }

    private var lunarText: String? {
        guard options.showLunarDate, let calendarDay else { return nil }
        return calendarDay.lunar.shortLabel
    }

    /// 星期旁边那一列：宽组件放农历（节日已经有右侧徽标了），窄组件没有徽标，
    /// 所以节日优先顶上来。
    private var stackedDetail: String? {
        let isCompact = compact || family == .systemSmall
        if isCompact, let badgeText { return badgeText }
        return lunarText
    }

    private var detailColor: Color {
        let isCompact = compact || family == .systemSmall
        guard isCompact, badgeText != nil else { return WidgetPalette.secondary }
        return calendarDay?.isStatutoryHoliday == true ? .pink : WidgetPalette.accent(for: theme)
    }
}

/// 选了「接着显示下一次课」、小组件换到别的日子时，日期栏上的标注：「明天的课」「10/2 的课」。
private struct OtherDayChip: View {
    let title: String
    @Environment(\.scheduleWidgetTheme) private var theme
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let tint = WidgetPalette.accent(for: theme)
        Text(title)
            .font(.system(size: 9, weight: .bold))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background {
                Capsule().fill(renderingMode == .fullColor ? tint.opacity(0.16) : Color.white.opacity(0.14))
            }
            .foregroundStyle(renderingMode == .fullColor ? tint : WidgetPalette.primary)
    }
}

/// 某一天离今天几天，用来说「明天」「后天」「3 天后」。今天及以前返回 `nil`。
private enum OtherDay {
    static func offset(of day: WidgetDay, now: Date = WidgetClock.now) -> Int? {
        guard let date = day.date, let target = ChineseCalendarInfo.date(fromDate: date) else { return nil }
        let calendar = ChineseCalendarInfo.gregorian
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: target)).day ?? 0
        return days > 0 ? days : nil
    }

    /// 「明天」「后天」「3 天后」。
    static func label(for day: WidgetDay, now: Date = WidgetClock.now) -> String? {
        guard let days = offset(of: day, now: now) else { return nil }
        switch days {
        case 1: return "明天"
        case 2: return "后天"
        default: return "\(days) 天后"
        }
    }

    /// 日期栏上的「明天的课」「后天的课」；再往后直接写日期：「10/2 的课」。
    static func hint(for day: WidgetDay, now: Date = WidgetClock.now) -> String? {
        guard let days = offset(of: day, now: now) else { return nil }
        switch days {
        case 1: return "明天的课"
        case 2: return "后天的课"
        default: return "\(day.compactDate.replacingOccurrences(of: ".", with: "/")) 的课"
        }
    }
}


/// 课程换成了别的日子（「接着显示下一次课」）时，挂在课程正上方的标注：实心的「明天」加上
/// 那天的日期和星期。日期栏上的小胶囊不够显眼，紧贴着课放才看得出下面不是今天的课。
private struct OtherDayBanner: View {
    /// 胶囊的高度。临近课程的纯文字标题也占这么高，换不换日子课的位置都不跳。
    static let height: CGFloat = 16

    let day: WidgetDay
    @Environment(\.scheduleWidgetTheme) private var theme
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let tint = WidgetPalette.accent(for: theme)
        let fullColor = renderingMode == .fullColor
        // 醒目只交给胶囊一处，后面的星期用灰字：再用强调色写一遍日期，就和上面日期栏的
        // 今天叠成两行日期，分不清哪个是课的日子。明天、后天不写日期，胶囊已经说了。
        let near = (OtherDay.offset(of: day) ?? 1) <= 2
        let detail = (near ? [day.displayLabel] : [day.compactDate, day.displayLabel])
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        HStack(spacing: 5) {
            Text(OtherDay.label(for: day) ?? "")
                .font(.system(size: 10, weight: .heavy))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background {
                    Capsule().fill(fullColor ? tint : Color.white.opacity(0.28))
                }
                .foregroundStyle(fullColor ? Color.white : WidgetPalette.primary)
                .widgetAccentable()
            Text(detail)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WidgetPalette.secondary)
        }
        .lineLimit(1)
        .fixedSize()
        .frame(height: Self.height)
    }
}

/// 日期栏下面那行调休提示：「上 10.9 周四的课」「国庆节放假」。
private struct AdjustmentNoteChip: View {
    let note: String
    @Environment(\.scheduleWidgetTheme) private var theme
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 8, weight: .bold))
            Text(note)
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(renderingMode == .fullColor ? WidgetPalette.accent(for: theme) : WidgetPalette.primary)
    }
}

/// 节日/法定假期徽标。法定假期用粉色，普通节日和节气跟随主题色。
private struct HolidayBadge: View {
    let title: String
    let highlighted: Bool
    @Environment(\.scheduleWidgetTheme) private var theme
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let tint = highlighted ? Color.pink : WidgetPalette.accent(for: theme)
        Text(title)
            .font(.system(size: 9, weight: .bold))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background {
                Capsule().fill(renderingMode == .fullColor ? tint.opacity(0.16) : Color.white.opacity(0.14))
            }
            .foregroundStyle(renderingMode == .fullColor ? tint : WidgetPalette.primary)
    }
}

/// 休息状态：今天是法定假日就道贺（「中秋快乐」），
/// 其余一律「今日无课」；下面一行小字是最近的一段法定假期。
private enum RestState {
    static func message(now: Date = WidgetClock.now) -> String {
        ChineseCalendarInfo.restGreeting(for: now) ?? "今日无课"
    }

    static func countdown(options: ScheduleWidgetDisplayOptions, now: Date = WidgetClock.now) -> ChineseHolidayCountdown? {
        guard options.showHoliday else { return nil }
        return ChineseCalendarInfo.countdown(from: now, withinDays: 120)
    }

    /// 休息时顶上来的那段假期，排成和「临近课程」一样的三行：小标签「4 天后」、
    /// 标题「国庆节」、说明「10.1 - 10.7 · 休 7 天」。已经在放假就是「放假中」「国庆快乐」。
    /// 关掉节假日提示或 120 天内没有假期时为 `nil`。
    static func holiday(
        options: ScheduleWidgetDisplayOptions,
        now: Date = WidgetClock.now
    ) -> (caption: String, title: String, detail: String)? {
        guard let countdown = countdown(options: options, now: now) else { return nil }
        let name = countdown.window.name
        switch countdown.daysAway {
        case 0:
            return ("放假中", ChineseCalendarInfo.restGreeting(for: now) ?? name, countdown.dateLabel)
        case 1:
            return ("明天", name, countdown.dateLabel)
        case let days:
            return ("\(days) 天后", name, countdown.dateLabel)
        }
    }

    /// 锁屏单行只放一句：祝福 → 「距国庆节还有 5 天」→「今日无课」。
    static func inlineText(options: ScheduleWidgetDisplayOptions, now: Date = WidgetClock.now) -> String {
        if let greeting = ChineseCalendarInfo.restGreeting(for: now) { return greeting }
        if let countdown = countdown(options: options, now: now), countdown.daysAway > 0 {
            return countdown.phrase
        }
        return "今日无课"
    }
}

private struct EmptyCoursesView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(WidgetPalette.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

/// 两日课表放假当天今天那一列：图标、祝福，下面是这段假期的日期和进度（一天一个点，过去的和今天实心）。
/// 半个组件宽、一整列高，只写一行「国庆快乐」太空。关掉节假日提示时只留图标和祝福。
private struct HolidayGreetingView: View {
    let greeting: String
    @Environment(\.scheduleWidgetDisplayOptions) private var options
    @Environment(\.scheduleWidgetCelebrating) private var celebrating
    @Environment(\.scheduleWidgetFireworksPreviewTime) private var previewTime

    var body: some View {
        let countdown = RestState.countdown(options: options).flatMap { $0.daysAway == 0 ? $0 : nil }
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                icon
                VStack(spacing: 4) {
                    Text(greeting)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(WidgetPalette.primary)
                    if let countdown {
                        Text(Self.dateText(for: countdown))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(WidgetPalette.secondary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                if let countdown, let progress = Self.progress(of: countdown.window) {
                    VStack(spacing: 6) {
                        HStack(spacing: 4) {
                            ForEach(1...progress.total, id: \.self) { index in
                                Circle()
                                    .fill(index <= progress.day ? Color.pink : WidgetPalette.muted.opacity(0.3))
                                    .frame(width: 6, height: 6)
                                    .widgetAccentable(index <= progress.day)
                            }
                        }
                        Text(progress.day == progress.total ? "假期最后一天" : "第 \(progress.day) 天 · 还剩 \(progress.total - progress.day) 天")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(WidgetPalette.muted)
                            .lineLimit(1)
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            // 下面多留一点：整组稍微偏上，看起来才是居中的。
            Spacer(minLength: 0).frame(maxHeight: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 清明道安康，放彩炮不合适，换成叶子，也不放烟花。
    private var isSolemn: Bool { greeting.hasPrefix("清明") }

    @ViewBuilder
    private var icon: some View {
        let image = Image(systemName: isSolemn ? "leaf.fill" : "party.popper.fill")
            .font(.system(size: 30, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(Color.pink)
            .widgetAccentable()
        if isSolemn {
            image
        } else {
            // 彩炮是个按钮：按一下整个小组件放烟花，几秒后收起。按的时候彩炮往上一扬。
            Button(intent: CelebrateHolidayIntent()) {
                let lift = previewTime.map { FireworksTiming.tilt(at: $0) } ?? (celebrating ? 1 : 0)
                image
                    .rotationEffect(.degrees(-14 * lift))
                    .scaleEffect(1 + 0.18 * lift)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .animation(.spring(duration: 0.9, bounce: 0.35), value: celebrating)
            .padding(-8)
            // 烟花由最外层铺满整个小组件放，从这里（彩炮口）飞出去。
            .anchorPreference(key: FireworksOriginKey.self, value: .center) { $0 }
        }
    }

    /// 画了进度点就只写起止日期：「休 7 天」和下面的「还剩 5 天」重复。没画点时照旧用完整的说明。
    private static func dateText(for countdown: ChineseHolidayCountdown) -> String {
        let window = countdown.window
        guard progress(of: window) != nil else { return countdown.dateLabel }
        return "\(ChineseCalendarInfo.monthDayLabel(window.start)) - \(ChineseCalendarInfo.monthDayLabel(window.end))"
    }

    /// 今天是这段假期的第几天、一共几天。只有一天的假期不画点。
    private static func progress(of window: ChineseHolidayWindow) -> (day: Int, total: Int)? {
        let total = window.dayCount
        let today = ChineseCalendarInfo.dateString(WidgetClock.now)
        guard total > 1, total <= 12, let gap = ChineseCalendarInfo.dayGap(from: window.start, to: today) else { return nil }
        return (min(max(gap + 1, 1), total), total)
    }
}

/// 烟花的节奏，按下那一条时间线里一口气放完：碎片从各簇中心往外炸（先快后慢），同时往下坠
///（先慢后快，两者叠出一道下垂的弧线），一下亮起、再慢慢暗到看不见。星芒一闪就没，光束先散，
/// 亮点次之，外圈的闪光飘得最久、坠得最远。画廊逐帧出动画时按这里算。
///
/// 小组件在真机上是把前后两条时间线的画面各存一份，由系统在两份之间插值，所以：
/// - 只有两份里都有的视图才会动（彩炮能扬起就是这样）。新插进来的视图直接按后一份画，
///   过渡、父视图的动画都不管用。所以碎片平时就在，按下只改状态。
/// - 存下来的是合并后的画面：叠在一起的几个缩放合成一个变换，几个透明度乘成一个值。
///   所以不能靠「先放大再缩小」两个效果相乘做出中间亮一下，前后乘积一样就什么都不动。
/// - 一个视图上的几样变化只会共用一条动画（实测整段都按最快的那条一下放完），各挂各的 `.animation` 不管用。
///   要不同快慢就得放在不同的视图上，中间隔一层 `compositingGroup`，免得又被合并。
/// - 只用系统自带的曲线，自定义贝塞尔不一定认。
/// - 完全透明的视图很可能存档时就被丢掉了，两份里都没有也就不会动。所以碎片的透明度从不降到 0：
///   平时和散完都只是暗到 `hiddenLevel`，看不见但还在。
/// - 验证真机效果用 Xcode 里这份文件末尾的 `#Preview`：它和桌面一样按两条时间线插值。
/// - 每段动画最长只放 2 秒左右，超过的部分直接跳到终点。
/// - 不认 `.delay`。
/// - 下一条时间线什么时候换上不由我们定，不指望它接着放第二段。
enum FireworksTiming {
    /// 按下后一组碎片一下亮起用的时间。
    static let flashDuration = 0.15
    /// 散完时碎片暗到多暗：看不见，但不是 0，免得存档时被丢掉。
    static let hiddenLevel = 0.02
    /// 碎片刚炸开时多大，飞出去的路上长到原大。平时靠整组暗到 `hiddenLevel` 藏住（见 `FireworksOverlay`）。
    static let collapsedScale = 0.4

    /// 每一层飞多久、散完要多久（两个一样长），一路坠下多少（占小组件短边的比例）。
    static func layer(_ kind: FireworksLayer) -> (life: Double, drop: CGFloat) {
        switch kind {
        case .core: return (0.8, 0.04)
        case .streak: return (1.1, 0.09)
        case .dot: return (1.5, 0.14)
        case .glitter: return (1.8, 0.2)
        }
    }

    /// 按下到最后一点闪光散完（最长那一层的寿命）。
    static let total = 1.8

    static func outward(_ progress: Double) -> Double { UnitCurve.easeOut.value(at: progress) }

    /// 下坠和变暗：先慢后快，一出来不至于就显得灰，也像被重力拽下去。只用系统自带的曲线，自定义贝塞尔在小组件里不一定认。
    static func fade(_ progress: Double) -> Double { UnitCurve.easeIn.value(at: progress) }

    /// 彩炮扬起多少：带一点回弹地扬起，烟花散完、下一条时间线来了再放回去。
    static func tilt(at time: Double) -> Double {
        guard time > 0 else { return 0 }
        let rise = min(time / 0.5, 1)
        let spring = 1 - pow(1 - rise, 3) + sin(rise * .pi) * 0.25
        let settle = min(max((time - (total + 0.3)) / 0.9, 0), 1)
        return spring * (1 - UnitCurve.easeInOut.value(at: settle))
    }
}

/// 烟花碎片的几种：星芒、光束、亮点、闪光，散得快慢、坠得远近不同。
enum FireworksLayer: CaseIterable {
    case core, streak, dot, glitter
}

private struct FireworksPreviewTimeKey: EnvironmentKey {
    static let defaultValue: Double? = nil
}

extension EnvironmentValues {
    /// 只有预览画廊会设：画烟花动画第几秒的样子。
    var scheduleWidgetFireworksPreviewTime: Double? {
        get { self[FireworksPreviewTimeKey.self] }
        set { self[FireworksPreviewTimeKey.self] = newValue }
    }
}

/// 彩炮在小组件里的位置。只有放假祝福里的彩炮会报，报了最外层才铺烟花。
private struct FireworksOriginKey: PreferenceKey {
    static let defaultValue: Anchor<CGPoint>? = nil

    static func reduce(value: inout Anchor<CGPoint>?, nextValue: () -> Anchor<CGPoint>?) {
        value = value ?? nextValue()
    }
}

/// 铺满整个小组件的烟花。一簇一个色系，从中心往外辐射成菊花形：每根射线外头一道拖着尾巴的光，
/// 中间一颗亮点，隔一根在最外面再缀一点闪光，中心一颗星芒。一簇大的在彩炮正上方（像是它打上去的），
/// 另外几簇大小不一，散在小组件各处。
///
/// 小组件里没法跑逐帧动画，碎片平时就缩成一个点停在各簇中心，按下时几样状态各带各的曲线同时起跑
///（见 `FireworksTiming`）。位置按小组件大小的比例算好，不用随机数。
private struct FireworksOverlay: View {
    let active: Bool
    /// 彩炮口，在这一层的坐标里。
    let origin: CGPoint
    @Environment(\.scheduleWidgetFireworksPreviewTime) private var previewTime

    private struct Burst {
        let center: CGPoint
        let radius: CGFloat
        let rays: Int
        let colors: (Color, Color)
    }

    private struct Particle: Identifiable {
        let id: Int
        /// 哪一簇的哪一种碎片：同一组一起变暗。
        let group: Int
        let kind: FireworksLayer
        let burstCenter: CGPoint
        /// 炸开到哪（相对这一簇的中心）。
        let travel: CGSize
        let angle: Double
        let size: CGFloat
        let color: Color
    }

    /// 一簇一个色系，按放下的先后分：第一簇（彩炮上方）是金色。
    private static let palettes: [(Color, Color)] = [
        (.yellow, .orange),
        (.pink, Color(red: 1, green: 0.45, blue: 0.62)),
        (.cyan, .blue),
        (.purple, .pink),
        (.mint, .green),
    ]

    /// 其余几簇的候选位置（占宽高的比例）和半径（占短边的比例），按顺序挑，和已经放下的叠得太多就跳过。
    /// 彩炮在不同小组件里位置不一样（两日课表在左列，今日课表在正中），这样哪种都不会挤成一团。
    private static let candidates: [(x: CGFloat, y: CGFloat, radius: CGFloat)] = [
        (0.80, 0.22, 0.18),
        (0.20, 0.24, 0.16),
        (0.86, 0.54, 0.14),
        (0.14, 0.54, 0.13),
        (0.80, 0.85, 0.14),
        (0.20, 0.85, 0.12),
        (0.50, 0.90, 0.12),
    ]

    private static func bursts(in size: CGSize, origin: CGPoint) -> [Burst] {
        let side = min(size.width, size.height)
        // 第一簇在彩炮正上方，像是它打上去的。
        var placed: [(center: CGPoint, radius: CGFloat)] = [
            (CGPoint(x: origin.x, y: origin.y - side * 0.25), side * 0.19),
        ]
        // 彩炮和它下面的祝福也要让开，只占位不放烟花。
        let keepOut = [(center: CGPoint(x: origin.x, y: origin.y + side * 0.1), radius: side * 0.2)]
        for candidate in candidates where placed.count < palettes.count {
            let center = CGPoint(x: candidate.x * size.width, y: candidate.y * size.height)
            let radius = candidate.radius * side
            let clear = (placed + keepOut).allSatisfy { other in
                hypot(center.x - other.center.x, center.y - other.center.y) > (radius + other.radius) * 0.8
            }
            if clear { placed.append((center, radius)) }
        }
        return placed.enumerated().map { index, burst in
            Burst(
                center: burst.center,
                radius: burst.radius,
                rays: max(10, Int(burst.radius / 4.2)),
                colors: palettes[index]
            )
        }
    }

    private static func particles(in size: CGSize, origin: CGPoint) -> [Particle] {
        var result: [Particle] = []
        func add(_ kind: FireworksLayer, _ burst: Burst, burstIndex: Int, angle: Double, distance: CGFloat, size: CGFloat, color: Color) {
            let kindIndex = FireworksLayer.allCases.firstIndex(of: kind) ?? 0
            result.append(Particle(
                id: result.count, group: burstIndex * FireworksLayer.allCases.count + kindIndex,
                kind: kind, burstCenter: burst.center,
                travel: CGSize(width: CGFloat(cos(angle)) * distance, height: CGFloat(sin(angle)) * distance),
                angle: angle, size: size, color: color
            ))
        }
        for (index, burst) in bursts(in: size, origin: origin).enumerated() {
            let big = burst.radius > 40
            for ray in 0..<burst.rays {
                let angle = Double(ray) / Double(burst.rays) * 2 * .pi + Double(index) * 0.37
                let tint = ray.isMultiple(of: 2) ? burst.colors.0 : burst.colors.1
                let length = burst.radius * 0.34
                // 光束的中心往里收半个身长，尖端正好冲到半径上。
                add(.streak, burst, burstIndex: index, angle: angle, distance: burst.radius - length / 2, size: length, color: tint)
                add(.dot, burst, burstIndex: index, angle: angle + 0.12, distance: burst.radius * 0.62, size: big ? 3.4 : 2.8,
                    color: burst.colors.1)
                if ray.isMultiple(of: 2) {
                    add(.glitter, burst, burstIndex: index, angle: angle + 0.18, distance: burst.radius * 1.18, size: big ? 2.6 : 2.2,
                        color: burst.colors.0)
                }
            }
            add(.core, burst, burstIndex: index, angle: 0, distance: 0, size: big ? 13 : 10, color: burst.colors.0)
        }
        return result
    }

    var body: some View {
        GeometryReader { proxy in
            let particles = Self.particles(in: proxy.size, origin: origin)
            let side = min(proxy.size.width, proxy.size.height)
            let hidden = FireworksTiming.hiddenLevel
            let collapsed = FireworksTiming.collapsedScale
            let groups = Dictionary(grouping: particles) { $0.group }.sorted { $0.key < $1.key }
            ZStack {
                ForEach(groups, id: \.key) { _, members in
                    let layer = FireworksTiming.layer(members[0].kind)
                    let drop = layer.drop * side
                    // 同一个视图上的几样变化在小组件里只会共用一条动画，要各走各的就得是不同的视图，分三层：
                    // 碎片自己长到原大、往外飞，越飞越慢，一直飞到散没；同一簇同一种碎片合成一组，先一下亮起，
                    // 隔一层 `compositingGroup` 再整组越落越快、边落边暗（同一条先慢后快的曲线，像被重力拽下去）。
                    let fall = previewTime.map { $0 > 0 ? FireworksTiming.fade(min($0 / layer.life, 1)) : 0 }
                        ?? (active ? 1 : 0)
                    ZStack {
                        ForEach(members) { particle in
                            let landing = CGPoint(
                                x: particle.burstCenter.x + particle.travel.width,
                                y: particle.burstCenter.y + particle.travel.height
                            )
                            if let previewTime {
                                // 画廊逐帧出动画用：按和下面一样的曲线，自己算出第 previewTime 秒的样子。
                                let burst = previewTime > 0
                                    ? FireworksTiming.outward(min(previewTime / layer.life, 1)) : 0
                                shape(particle)
                                    .scaleEffect(collapsed + (1 - collapsed) * burst)
                                    .position(
                                        x: particle.burstCenter.x + (landing.x - particle.burstCenter.x) * burst,
                                        y: particle.burstCenter.y + (landing.y - particle.burstCenter.y) * burst
                                    )
                            } else {
                                // 平时缩小停在簇中心；按下时一边往外飞一边长到原大，飞到散没为止，不会半路停住。
                                shape(particle)
                                    .scaleEffect(active ? 1 : collapsed)
                                    .position(active ? landing : particle.burstCenter)
                                    .animation(active ? .easeOut(duration: layer.life) : nil, value: active)
                            }
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    // 平时整组暗到 hiddenLevel 藏住。先合成再调暗，叠在簇中心的一堆碎片才不会一层层透出来。
                    .compositingGroup()
                    .opacity(hidden + (1 - hidden) * (previewTime.map { $0 > 0 ? FireworksTiming.outward(min($0 / FireworksTiming.flashDuration, 1)) : 0 }
                        ?? (active ? 1 : 0)))
                    .animation(active && previewTime == nil ? .easeOut(duration: FireworksTiming.flashDuration) : nil, value: active)
                    .compositingGroup()
                    // 散完只暗到 hiddenLevel，不到 0。收起不靠这里：下一条换了 `.id`，整层按平时的样子重新放进来。
                    .offset(y: drop * fall)
                    .opacity(1 - (1 - hidden) * fall)
                    .animation(active && previewTime == nil ? .easeIn(duration: layer.life) : nil, value: active)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    @ViewBuilder
    private func shape(_ particle: Particle) -> some View {
        let color = particle.color
        switch particle.kind {
        case .streak:
            // 朝外的一道光，靠中心那头渐隐，像拖着尾巴飞出去。
            Capsule()
                .fill(LinearGradient(
                    colors: [particle.color.opacity(0), color],
                    startPoint: .leading, endPoint: .trailing
                ))
                .frame(width: particle.size, height: 2.4)
                .rotationEffect(.radians(particle.angle))
        case .dot, .glitter:
            Circle()
                .fill(color)
                .frame(width: particle.size, height: particle.size)
        case .core:
            Image(systemName: "sparkle")
                .font(.system(size: particle.size, weight: .bold))
                .foregroundStyle(color)
        }
    }
}

/// 今天没有要列的课时的主视图。上面一行小字交代今天：「今日课程已结束」或「今日无课」；
/// 最近的一段假期和「临近课程」里的一节课一个排法（小标签、标题、一行说明），贴着底边。
/// 放假当天不写上面那行，「放假中 / 国庆快乐」已经说明了。没有假期可说时只居中说今天。
private struct RestStateView: View {
    /// 今天排过课（已经上完）还是本来就没课。
    let hadCourses: Bool
    @Environment(\.scheduleWidgetDisplayOptions) private var options

    private var todayStatus: String { hadCourses ? "今日课程已结束" : "今日无课" }

    var body: some View {
        if let holiday = RestState.holiday(options: options) {
            VStack(alignment: .leading, spacing: 0) {
                if RestState.countdown(options: options)?.daysAway != 0 {
                    statusLine
                }
                Spacer(minLength: 6)
                holidayBlock(holiday)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            EmptyCoursesView(message: todayStatus)
        }
    }

    private var statusLine: some View {
        Label {
            Text(todayStatus)
        } icon: {
            Image(systemName: hadCourses ? "checkmark.circle.fill" : "moon.zzz.fill")
        }
        .labelStyle(StatusLabelStyle())
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(WidgetPalette.muted)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private func holidayBlock(_ holiday: (caption: String, title: String, detail: String)) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(holiday.caption)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WidgetPalette.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(holiday.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(WidgetPalette.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                Text(holiday.detail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(WidgetPalette.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }
}

/// 图标和字挨近一点，默认的 Label 间距在小组件里显得散。
private struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
                .font(.system(size: 10, weight: .semibold))
            configuration.title
        }
    }
}

private enum WidgetPalette {
    static let primary = Color.primary
    static let secondary = Color.secondary
    static let muted = Color.secondary.opacity(0.72)
    static func accent(for theme: ScheduleWidgetTheme) -> Color {
        switch theme {
        case .bunny:
            return Color(red: 226 / 255, green: 111 / 255, blue: 99 / 255)
        case .green:
            return Color(red: 15 / 255, green: 143 / 255, blue: 127 / 255)
        case .blue:
            return Color(red: 37 / 255, green: 99 / 255, blue: 235 / 255)
        case .teal:
            return Color(red: 8 / 255, green: 145 / 255, blue: 178 / 255)
        case .indigo:
            return Color(red: 79 / 255, green: 70 / 255, blue: 229 / 255)
        case .violet:
            return Color(red: 124 / 255, green: 58 / 255, blue: 237 / 255)
        case .orange:
            return Color(red: 234 / 255, green: 88 / 255, blue: 12 / 255)
        case .rose:
            return Color(red: 225 / 255, green: 29 / 255, blue: 72 / 255)
        case .slate:
            return Color(red: 71 / 255, green: 85 / 255, blue: 105 / 255)
        case .custom:
            let value = NextWidgetConfiguration.globalCustomColor
            return Color(red: value.red, green: value.green, blue: value.blue)
        case .colorGlass:
            return Color(red: 15 / 255, green: 143 / 255, blue: 127 / 255)
        }
    }

    /// 彩色模式下和 App 课表共用 `ScheduleCourseTint`，同一门课两边同色；纯色模式
    /// 沿用主题色。
    static func accent(
        for course: WidgetCourse,
        theme: ScheduleWidgetTheme,
        colorful: Bool,
        colorScheme: ColorScheme
    ) -> Color {
        colorful
            ? ScheduleCourseTint.accent(for: course.displayName, scheme: colorScheme)
            : accent(for: theme)
    }

    static func background(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 14 / 255, green: 20 / 255, blue: 32 / 255)
            : Color(red: 248 / 255, green: 251 / 255, blue: 1)
    }

    static func tint(
        for course: WidgetCourse,
        colorScheme: ColorScheme,
        theme: ScheduleWidgetTheme,
        colorful: Bool
    ) -> Color {
        if colorScheme == .dark {
            return accent(for: course, theme: theme, colorful: colorful, colorScheme: colorScheme).opacity(0.18)
        }
        if colorful {
            return ScheduleCourseTint.swatch(for: course.displayName).lightBackground
        }
        switch theme {
        case .bunny:
            return Color(red: 1, green: 244 / 255, blue: 241 / 255)
        case .green:
            return Color(red: 244 / 255, green: 251 / 255, blue: 248 / 255)
        case .blue:
            return Color(red: 243 / 255, green: 248 / 255, blue: 1)
        case .teal:
            return Color(red: 240 / 255, green: 251 / 255, blue: 1)
        case .indigo:
            return Color(red: 1, green: 245 / 255, blue: 250 / 255)
        case .violet:
            return Color(red: 250 / 255, green: 247 / 255, blue: 1)
        case .orange:
            return Color(red: 1, green: 247 / 255, blue: 241 / 255)
        case .rose:
            return Color(red: 1, green: 245 / 255, blue: 247 / 255)
        case .slate:
            return Color(red: 248 / 255, green: 250 / 255, blue: 252 / 255)
        case .custom:
            let value = NextWidgetConfiguration.globalCustomColor
            return Color(
                red: value.red + (1 - value.red) * 0.82,
                green: value.green + (1 - value.green) * 0.82,
                blue: value.blue + (1 - value.blue) * 0.82
            )
        case .colorGlass:
            return Color(red: 244 / 255, green: 251 / 255, blue: 248 / 255)
        }
    }
}

struct ScheduleEntry: TimelineEntry {
    let date: Date
    let state: ScheduleEntryState
    var configuration = ScheduleWidgetConfiguration()
    /// 刚按了放假祝福上的彩炮：这一条放烟花。
    var celebrating = false
    /// 烟花层的身份，每按一次彩炮换一个。放烟花那一条沿用按之前的，碎片才会从平时的样子动起来；
    /// 收起的那一条换成新的，整层按平时的样子重新放进来，不会倒着把烟花再放一遍。
    var fireworksRound: Double = 0

    var appURL: URL {
        guard case .loaded(let payload) = state else { return NextWidgetConfiguration.appURL }
        return NextWidgetConfiguration.appURL(
            semester: payload.semester,
            currentWeek: payload.currentWeek
        )
    }

    static let placeholder = ScheduleEntry(
        date: .now,
        state: .loaded(
            WidgetSchedulePayload(
                title: "我上早八",
                sourceLabel: nil,
                generatedAt: nil,
                semester: "2026-2027-1",
                currentWeek: 1,
                today: WidgetDay(
                    day: 1,
                    label: "周一",
                    date: "2026-08-31",
                    week: 1,
                    isToday: true,
                    courses: [
                        WidgetCourse(
                            name: "药物设计学", teacher: "邹老师", location: "D301",
                            note: nil, slotNote: nil, startTime: "08:00", endTime: "09:40", startSlot: 1, endSlot: 2
                        ),
                        WidgetCourse(
                            name: "药剂学", teacher: "苏老师", location: "C204",
                            note: nil, slotNote: nil, startTime: "09:55", endTime: "11:35", startSlot: 3, endSlot: 4
                        ),
                    ]
                ),
                days: nil,
                weekDays: nil,
                nextWeekDays: nil
            )
        )
    )
}

enum ScheduleEntryState {
    case loaded(WidgetSchedulePayload)
    case unconfigured
    case failed(String)
}

/// 从 App Group 里读课表生成时间线；各个小组件的配置由 `ScheduleIntentTimelineProvider` 再套上。
enum ScheduleTimeline {
    static func make(now: Date) -> Timeline<ScheduleEntry> {
        let entry: ScheduleEntry
        let payload = ScheduleWidgetStore.load()
        ChineseCalendarInfo.usePublishedHolidays(payload?.holidays ?? [])
        if let payload {
            entry = ScheduleEntry(date: now, state: .loaded(payload))
        } else {
            entry = ScheduleEntry(date: now, state: .unconfigured)
        }
        let periodic = Calendar.current.date(byAdding: .minute, value: 30, to: now) ?? now.addingTimeInterval(1800)
        // 下课那一刻就该换内容（划掉已结束的课、放学后切到明天），别等下一个半小时。
        let refresh = payload.flatMap { Self.nextBoundary(in: $0, now: now) }.map { min($0, periodic) } ?? periodic
        // 刚按了彩炮：这一条放烟花，散完后再来一条把彩炮放回去。
        let rounds = CelebrateHolidayIntent.rounds()
        var calm = entry
        calm.fireworksRound = rounds.latest
        guard CelebrateHolidayIntent.justFired(now: now) else {
            return Timeline(entries: [calm], policy: .after(refresh))
        }
        var celebrating = entry
        celebrating.celebrating = true
        celebrating.fireworksRound = rounds.previous
        // 烟花在上面那一条里就放完、散没了；这一条只是把彩炮放回去、换掉看不见的碎片，来晚了也不碍事。
        calm = ScheduleEntry(date: now.addingTimeInterval(FireworksTiming.total + 0.3), state: entry.state, fireworksRound: rounds.latest)
        return Timeline(entries: [celebrating, calm], policy: .after(refresh))
    }

    /// 今天剩下的课程边界里最近的一个（开始或结束）；都过了就是午夜换日那一刻。
    private static func nextBoundary(in payload: WidgetSchedulePayload, now: Date) -> Date? {
        let today = payload.currentDay(now: now)
        let nowMinutes = WidgetSchedulePayload.minutesSinceMidnight(now)
        let startOfDay = ChineseCalendarInfo.gregorian.startOfDay(for: now)
        let minutes = today.courseList
            .flatMap { [Self.minutes($0.startTime), $0.endMinutes > 0 ? $0.endMinutes : nil] }
            .compactMap { $0 }
            .filter { $0 > nowMinutes }
            .min()
        // 过了零点日期栏和课都要换成新的一天，不能等兜底的半小时。
        guard let minutes else { return startOfDay.addingTimeInterval(TimeInterval((24 * 60 + 1) * 60)) }
        // 边界后一分钟再刷新，免得刚好卡在同一分钟上还算成「没结束」。
        return startOfDay.addingTimeInterval(TimeInterval((minutes + 1) * 60))
    }

    private static func minutes(_ value: String?) -> Int? {
        guard let value, value.count >= 5 else { return nil }
        let pieces = value.prefix(5).split(separator: ":")
        guard pieces.count == 2, let hour = Int(pieces[0]), let minute = Int(pieces[1]) else { return nil }
        return hour * 60 + minute
    }
}

#if WIDGET_GALLERY
/// 预览画廊（`scripts/widget-gallery.sh`）的入口。小组件和实时活动的视图都是 private，
/// 画廊只能从这份文件里拿，拿到的和桌面、锁屏上跑的是同一份代码。
enum WidgetGalleryViews {
    enum Kind: String, CaseIterable {
        case upcoming, today, twoday
    }

    /// 实时活动里可以单独渲染的几块。灵动岛的外形由画廊自己画。
    enum ActivityPart: String {
        case lockScreen, watch, islandLeading, islandTrailing, islandBottom, compactLeading, compactTrailing, minimal
    }

    static func widget(kind: Kind, family: WidgetFamily, entry: ScheduleEntry) -> AnyView {
        switch kind {
        case .upcoming:
            return AnyView(ScheduleWidgetRoot(entry: entry, familyOverride: family) { UpcomingScheduleView(payload: $0) })
        case .today:
            return AnyView(ScheduleWidgetRoot(entry: entry, familyOverride: family) { TodayScheduleView(payload: $0) })
        case .twoday:
            return AnyView(ScheduleWidgetRoot(entry: entry, familyOverride: family) { TwoDayScheduleView(payload: $0) })
        }
    }

    static func widgetBackground(for colorScheme: ColorScheme) -> Color {
        WidgetPalette.background(for: colorScheme)
    }

    static func liveActivity(
        _ part: ActivityPart,
        state: ScheduleLiveActivityAttributes.ContentState,
        attributes: ScheduleLiveActivityAttributes,
        isStale: Bool
    ) -> AnyView {
        let display = ScheduleLiveActivityDisplay(state: state, isStale: isStale, attributes: attributes)
        switch part {
        case .lockScreen:
            return AnyView(ScheduleLiveActivityLockScreenContent(display: display).environment(\.activityFamily, .medium))
        case .watch:
            return AnyView(ScheduleLiveActivityLockScreenContent(display: display).environment(\.activityFamily, .small))
        case .islandLeading:
            return AnyView(ScheduleLiveActivityIslandLeading(display: display))
        case .islandTrailing:
            return AnyView(ScheduleLiveActivityIslandTrailing(display: display))
        case .islandBottom:
            return AnyView(ScheduleLiveActivityIslandBottom(display: display))
        case .compactLeading, .minimal:
            return AnyView(ScheduleLiveActivityLogo(size: 21))
        case .compactTrailing:
            return AnyView(ScheduleLiveActivityIslandCompactTrailing(display: display))
        }
    }

    /// 手表智能叠放和收尾卡片用的深色底（`activityBackgroundTint`）。
    static var activitySurface: Color { ScheduleLiveActivityPalette.surface }
}
#endif

#if DEBUG && !WIDGET_GALLERY
/// 在 Xcode 里看放假彩炮的真机效果：画布下方依次点三条时间线（平时 → 按下 → 平时），
/// 系统会和桌面上一样在两条之间插值播动画。日期钉在国庆第二天。
private enum FireworksPreview {
    static func entry(
        celebrating: Bool,
        round: Double,
        afterClass: ScheduleWidgetAfterClassStyle = .nextCourseDay
    ) -> ScheduleEntry {
        var components = DateComponents()
        (components.year, components.month, components.day, components.hour) = (2026, 10, 2, 10)
        WidgetClock.override = ChineseCalendarInfo.gregorian.date(from: components)
        // 示例课表的「今天」是开学那天、有课；这里换成国庆第二天没课，下一次课在假期后。
        guard case .loaded(let sample) = ScheduleEntry.placeholder.state else { return .placeholder }
        let payload = WidgetSchedulePayload(
            title: sample.title,
            sourceLabel: nil,
            generatedAt: nil,
            semester: sample.semester,
            currentWeek: 5,
            today: WidgetDay(day: 5, label: "周五", date: "2026-10-02", week: 5, isToday: true, courses: []),
            days: [
                WidgetDay(day: 4, label: "周四", date: "2026-10-08", week: 6, isToday: false,
                          courses: sample.today?.courses ?? []),
            ],
            weekDays: nil,
            nextWeekDays: nil
        )
        return ScheduleEntry(
            date: .now,
            state: .loaded(payload),
            configuration: ScheduleWidgetConfiguration(afterClass: afterClass),
            celebrating: celebrating,
            fireworksRound: round
        )
    }
}

#Preview("两日课表 · 放礼花", as: .systemLarge) {
    TwoDayScheduleWidget()
} timeline: {
    FireworksPreview.entry(celebrating: false, round: 0)
    FireworksPreview.entry(celebrating: true, round: 0)
    FireworksPreview.entry(celebrating: false, round: 1)
}

#Preview("今日课表 · 放礼花", as: .systemLarge) {
    TodayScheduleWidget()
} timeline: {
    FireworksPreview.entry(celebrating: false, round: 0, afterClass: .todayOnly)
    FireworksPreview.entry(celebrating: true, round: 0, afterClass: .todayOnly)
    FireworksPreview.entry(celebrating: false, round: 1, afterClass: .todayOnly)
}
#endif
