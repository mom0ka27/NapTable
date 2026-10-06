import SwiftUI
import WidgetKit

/// The widget bundle: the two schedule widgets plus the Live Activity.
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
                .scheduleWidgetStyle(ScheduleStyle.load(from: UserDefaults(suiteName: NextWidgetConfiguration.appGroup)))
        } dynamicIsland: { context in
            let display = Self.display(context)
            let style = ScheduleStyle.load(from: UserDefaults(suiteName: NextWidgetConfiguration.appGroup))
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading, priority: 1) {
                    ScheduleLiveActivityIslandLeading(display: display)
                        .scheduleWidgetStyle(style)
                        .environment(\.liveActivityPalette, LiveActivityContentPalette(style: style))
                }
                DynamicIslandExpandedRegion(.trailing, priority: 1) {
                    ScheduleLiveActivityIslandTrailing(display: display)
                        .scheduleWidgetStyle(style)
                        .environment(\.liveActivityPalette, LiveActivityContentPalette(style: style))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ScheduleLiveActivityIslandBottom(display: display)
                        .scheduleWidgetStyle(style)
                        .environment(\.liveActivityPalette, LiveActivityContentPalette(style: style))
                }
            } compactLeading: {
                ScheduleLiveActivityLogo(size: 21)
                    .accessibilityLabel(AppBrand.name)
                    .scheduleWidgetStyle(style)
                        .environment(\.liveActivityPalette, LiveActivityContentPalette(style: style))
            } compactTrailing: {
                ScheduleLiveActivityIslandCompactTrailing(display: display)
                    .scheduleWidgetStyle(style)
                        .environment(\.liveActivityPalette, LiveActivityContentPalette(style: style))
            } minimal: {
                ScheduleLiveActivityLogo(size: 21)
                    .accessibilityLabel(AppBrand.name)
                    .scheduleWidgetStyle(style)
                        .environment(\.liveActivityPalette, LiveActivityContentPalette(style: style))
            }
            // 左右和底部交给系统：`contentMargins(_:_:for: .expanded)` 是覆盖而不是
            // 叠加，之前把三边一起写死（18/8/10）比系统默认值窄，左上角的图标和右上角
            // 的「距上课」才会被胶囊圆角切掉。顶部归零：上边不是被圆角切到的那一侧，
            // 系统默认的上边距只会把内容白白往下压。
            .contentMargins(.top, 0, for: .expanded)
            .widgetURL(context.attributes.deepLinkURL)
            .keylineTint(style == .minimal ? ScheduleLiveActivityPalette.brand : LiveActivityContentPalette(style: style).accent)
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
    @Environment(\.liveActivityPalette) private var palette
    @Environment(\.scheduleStyle) private var style
    let display: ScheduleLiveActivityDisplay

    var body: some View {
        HStack(spacing: 5) {
            ScheduleLiveActivityLogo(size: 24)
            Text(display.islandTitle)
                .font(style.widgetFont(size: 12, weight: .semibold))
                .foregroundStyle(palette.accent)
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
    @Environment(\.liveActivityPalette) private var palette
    @Environment(\.scheduleStyle) private var style
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
        .font(style.widgetFont(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
        .foregroundStyle(palette.accent)
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
    @Environment(\.scheduleStyle) private var style
    let title: String
    var compact = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = LiveActivityContentPalette(colorScheme: compact ? .dark : colorScheme, style: style)
        HStack(spacing: compact ? 8 : 12) {
            ScheduleLiveActivityLogo(size: compact ? 20 : 32)
            Text(title)
                .font(style.widgetFont(size: compact ? 14 : 17, weight: .bold))
                .foregroundStyle(palette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, compact ? 12 : 21)
        .padding(.vertical, compact ? 10 : 16)
        .environment(\.liveActivityPalette, palette)
        .activityBackgroundTint(style.canvasColor(dark: compact || colorScheme == .dark) ?? (compact ? ScheduleLiveActivityPalette.surface : nil))
        .activitySystemActionForegroundColor(compact ? .white : .primary)
    }
}

/// The expanded island's bottom region once the day is over.
@available(iOS 16.1, *)
private struct ScheduleLiveActivityFinishedRow: View {
    @Environment(\.liveActivityPalette) private var palette
    @Environment(\.scheduleStyle) private var style
    let title: String

    var body: some View {
        Text(title)
            .font(style.widgetFont(size: 15, weight: .semibold))
            .foregroundStyle(palette.primaryText)
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
    @Environment(\.scheduleStyle) private var style
    @Environment(\.colorScheme) private var colorScheme
    let state: ScheduleLiveActivityAttributes.ContentState

    private var palette: LiveActivityContentPalette {
        LiveActivityContentPalette(colorScheme: colorScheme, style: style)
    }

    var body: some View {
        Group {
            if state.companion != nil { merged } else { content }
        }
        .environment(\.liveActivityPalette, palette)
        .activityBackgroundTint(style.canvasColor(dark: colorScheme == .dark))
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
                    .font(style.widgetFont(size: 15, weight: .bold))
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
        .overlay { WidgetCourseRule(color: palette.accent).padding(.vertical, -3) }
        .padding(.horizontal, 21)
        .padding(.vertical, 12)
        .background(gradient)
    }

    @ViewBuilder
    private var gradient: some View {
        if style == .minimal {
        LinearGradient(
            colors: [ScheduleLiveActivityPalette.brand.opacity(colorScheme == .dark ? 0.12 : 0.06), .clear],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        } else {
            style.canvasColor(dark: colorScheme == .dark) ?? Color.clear
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                ScheduleLiveActivityLogo(size: 34)
                VStack(alignment: .leading, spacing: 4) {
                    if style == .board {
                    Text(ScheduleLiveActivityFormatting.timeRange(start: state.startDate, end: state.endDate))
                        .font(style.widgetFont(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(palette.secondaryText)
                    }
                    Text(state.courseName)
                        .font(style.widgetFont(size: 19, weight: .bold))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if style != .board {
                    Text(ScheduleLiveActivityFormatting.timeRange(start: state.startDate, end: state.endDate))
                        .font(style.widgetFont(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(palette.secondaryText)
                    }
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
        .overlay { WidgetCourseRule(color: palette.accent).padding(.vertical, -3) }
        .padding(.horizontal, 21)
        .padding(.vertical, 14)
        .background(gradient)
    }
}

@available(iOS 16.1, *)
private struct ScheduleLiveActivityExpandedDetails: View {
    @Environment(\.liveActivityPalette) private var palette
    @Environment(\.scheduleStyle) private var style
    let state: ScheduleLiveActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(state.courseName)
                    .font(style.widgetFont(size: 19, weight: .bold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(ScheduleLiveActivityFormatting.timeRange(start: state.startDate, end: state.endDate))
                    .font(style.widgetFont(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize()
            }
            ScheduleLiveActivityChips(state: state)
            ScheduleLiveActivityCourseDetails(state: state)
            ScheduleLiveActivityProgress(state: state)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The bottom region is clipped by Dynamic Island's own capsule. Keep
        // the progress track and the metadata away from its lower corners.
        .overlay { WidgetCourseRule(color: palette.accent) }
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
    @Environment(\.scheduleStyle) private var style
    @Environment(\.liveActivityPalette) private var palette
    let name: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "person.fill")
                .font(style.widgetFont(size: 9, weight: .semibold))
            Text(name)
                .font(style.widgetFont(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(palette.accent)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(palette.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: style == .minimal ? 100 : style.layout.cornerRadius))
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
    @Environment(\.scheduleStyle) private var style
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
                        .font(style.widgetFont(size: compact ? 13 : 15, weight: .bold))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ScheduleLiveActivityTimerText(interval: entry.timer, showsHours: entry.showsHours)
                        .font(style.widgetFont(size: compact ? 12 : 15, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.trailing)
                        .frame(width: entry.showsHours ? 64 : 48, alignment: .trailing)
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(entry.tag)
                        .font(style.widgetFont(size: compact ? 9 : 10, weight: .bold))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: style == .minimal ? 100 : style.layout.cornerRadius))
                        .frame(maxWidth: compact ? 44 : 72, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                    if !entry.detail.isEmpty {
                        Text(entry.detail)
                            .font(style.widgetFont(size: compact ? 10 : 11, weight: .medium))
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    if !compact {
                        Text(entry.inProgress ? "距下课" : "距上课")
                            .font(style.widgetFont(size: 10, weight: .medium))
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
        .overlay { WidgetCourseRule(color: tint) }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.isOwn ? "我" : entry.tag)：\(entry.courseName)，\(entry.inProgress ? "正在上课" : "即将上课")")
    }
}

/// 调休那天锁屏上多一行说明。补课日显示的是另一天的课，不说清楚就是一节
/// 看起来不该存在的课。
@available(iOS 16.1, *)
private struct ScheduleLiveActivityAdjustmentChip: View {
    @Environment(\.scheduleStyle) private var style
    @Environment(\.liveActivityPalette) private var palette
    let note: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(style.widgetFont(size: 10, weight: .semibold))
            Text(note)
                .font(style.widgetFont(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(style == .minimal ? ScheduleLiveActivityPalette.brand : palette.accent)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background((style == .minimal ? ScheduleLiveActivityPalette.brand : palette.accent).opacity(0.12), in: RoundedRectangle(cornerRadius: style == .minimal ? 100 : style.layout.cornerRadius))
    }
}

@available(iOS 16.1, *)
private struct ScheduleLiveActivityCourseDetails: View {
    @Environment(\.scheduleStyle) private var style
    @Environment(\.liveActivityPalette) private var palette
    let state: ScheduleLiveActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 10) {
            if !state.location.isEmpty {
                Text(state.location)
                    .font(style.widgetFont(size: 13, weight: .semibold))
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
            .font(style.widgetFont(size: 12, weight: .medium))
            .foregroundStyle(palette.secondaryText)
            .frame(maxWidth: .infinity, alignment: state.location.isEmpty ? .leading : .trailing)
        }
    }
}

@available(iOS 16.1, *)
private struct ScheduleLiveActivityCountdown: View {
    @Environment(\.scheduleStyle) private var style
    @Environment(\.liveActivityPalette) private var palette
    let state: ScheduleLiveActivityAttributes.ContentState
    var compact = false
    var centered = false

    var body: some View {
        VStack(alignment: centered ? .center : .trailing, spacing: compact ? 1 : 3) {
            Text(state.phase == .inProgress ? "距下课" : "距上课")
                .font(style.widgetFont(size: compact ? 10 : 11, weight: .medium))
                .foregroundStyle(palette.accent)
            ScheduleLiveActivityTimer(state: state, alignment: centered ? .center : .trailing)
                .font(style.widgetFont(size: compact ? 19 : 25, weight: .semibold, design: .rounded).monospacedDigit())
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
    @Environment(\.scheduleStyle) private var style
    @Environment(\.liveActivityPalette) private var palette
    let state: ScheduleLiveActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
                .overlay(palette.divider)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("下一节")
                    .font(style.widgetFont(size: 10, weight: .medium))
                    .foregroundStyle(palette.tertiaryText)
                    .fixedSize()
                Text([state.nextCourseName, state.nextCourseContext].compactMap { $0 }.joined(separator: "  "))
                    .font(style.widgetFont(size: 11, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let start = state.nextCourseStart {
                    Text(ScheduleLiveActivityFormatting.timeRange(start: start, end: state.nextCourseEnd))
                        .font(style.widgetFont(size: 10, weight: .medium, design: .rounded).monospacedDigit())
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
    private var palette: LiveActivityContentPalette { LiveActivityContentPalette(style: style) }
    @Environment(\.scheduleStyle) private var style
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
        .environment(\.liveActivityPalette, LiveActivityContentPalette(style: style))
        .activityBackgroundTint(style.canvasColor(dark: true) ?? ScheduleLiveActivityPalette.surface)
        .activitySystemActionForegroundColor(.white)
    }

    private func merged(showsHeader: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if showsHeader {
                HStack(spacing: 5) {
                    ScheduleLiveActivityLogo(size: 16)
                    Text(state.islandTitle)
                        .font(style.widgetFont(size: 12, weight: .semibold))
                        .foregroundStyle(palette.accent)
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
                    .font(style.widgetFont(size: 14, weight: .bold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 4) {
                Text(state.phaseTitle)
                    .font(style.widgetFont(size: 11, weight: .medium))
                    .foregroundStyle(palette.accent)
                    .lineLimit(1)
                Spacer(minLength: 2)
                ScheduleLiveActivityTimer(state: state)
                    .font(style.widgetFont(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(palette.primaryText)
                    .frame(width: 46, alignment: .trailing)
            }
            Text([state.normalizedSourceLabel ?? "", state.location.isEmpty ? state.teacher : state.location, state.periodLabel ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " · "))
                .font(style.widgetFont(size: 11, weight: .medium))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)
            if showsTimeRange {
                Text(ScheduleLiveActivityFormatting.timeRange(start: state.startDate, end: state.endDate))
                    .font(style.widgetFont(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(palette.secondaryText)
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
            live
        }
        #else
        live
        #endif
    }

    /// 倒着数只看终点，起点只决定「还没到起点时停在满格」。预约好的实时活动系统在
    /// 登记时就先渲染一遍，那时起点（提醒时刻）还在将来；到点弹出来的就是这份停住的
    /// 画面，锁屏上一直不走，直到长按灵动岛或进 AoD 重新渲染。起点往前挪一天，
    /// 什么时候渲染都已经在走。
    private var live: Text {
        Text(timerInterval: interval.upperBound.addingTimeInterval(-86_400)...interval.upperBound,
             countsDown: true, showsHours: showsHours)
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
    var style: ScheduleStyle = .minimal

    var primaryText: Color {
        style == .minimal ? (colorScheme == .dark ? ScheduleLiveActivityPalette.primaryText : .primary)
            : (colorScheme == .dark && style.canvasColor(dark: true) == nil ? .white : style.inkColor(dark: colorScheme == .dark))
    }
    var secondaryText: Color {
        style == .minimal ? (colorScheme == .dark ? ScheduleLiveActivityPalette.secondaryText : .secondary)
            : primaryText.opacity(0.72)
    }
    var tertiaryText: Color {
        style == .minimal ? (colorScheme == .dark ? ScheduleLiveActivityPalette.tertiaryText : .secondary)
            : primaryText.opacity(0.7)
    }
    var divider: Color { style == .minimal ? (colorScheme == .dark ? ScheduleLiveActivityPalette.divider : Color.primary.opacity(0.12)) : primaryText.opacity(0.25) }
    var accent: Color {
        style.styleAccent(
            dark: colorScheme == .dark,
            fallback: colorScheme == .dark ? ScheduleLiveActivityPalette.accent : ScheduleLiveActivityPalette.lightAccent
        )
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

/// 小号、中号、锁屏是临近课程，大号是今日完整课表：同一个小组件的不同尺寸。
private struct UpcomingScheduleWidget: Widget {
    let kind = "com.niyiwei.naptable.widget.upcoming"

    var body: some WidgetConfiguration {
        // 沿用原来的 kind：换成可编辑的配置后，已经放在桌面上的小组件照样在，取默认值。
        AppIntentConfiguration(
            kind: kind,
            intent: UpcomingScheduleWidgetIntent.self,
            provider: ScheduleIntentTimelineProvider<UpcomingScheduleWidgetIntent>()
        ) { entry in
            ScheduleWidgetRoot(entry: entry) { payload in
                UpcomingOrTodayScheduleView(payload: payload)
            }
        }
        .configurationDisplayName("今日课程")
        .description("小号、中号和锁屏显示当前与下一节课程，大号显示今日的完整安排。")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge,
            .accessoryInline,
            .accessoryCircular,
            .accessoryRectangular,
        ])
    }
}

/// 大号放得下一整天，换成今日课表；其余尺寸是临近课程。
private struct UpcomingOrTodayScheduleView: View {
    let payload: WidgetSchedulePayload
    @Environment(\.scheduleWidgetFamily) private var family

    @ViewBuilder
    var body: some View {
        if family == .systemLarge {
            TodayScheduleView(payload: payload)
        } else {
            UpcomingScheduleView(payload: payload)
        }
    }
}

private struct TwoDayScheduleWidget: Widget {
    let kind = "com.niyiwei.naptable.widget.twoday"

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

private struct ScheduleWidgetNoticeEnvironmentKey: EnvironmentKey {
    static let defaultValue: WidgetScheduleNotice? = nil
}

private struct ScheduleWidgetNowEnvironmentKey: EnvironmentKey {
    /// 只有没经过 `ScheduleWidgetRoot` 的视图才会读到这个。
    static var defaultValue: Date { WidgetClock.now }
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

    /// 今天放假（寒暑假）或课表过期：休息状态换成「寒假ing」「打开 App 更新课表」。
    var scheduleWidgetNotice: WidgetScheduleNotice? {
        get { self[ScheduleWidgetNoticeEnvironmentKey.self] }
        set { self[ScheduleWidgetNoticeEnvironmentKey.self] = newValue }
    }

    /// 这一条时间线条目画的是哪一刻：`ScheduleWidgetRoot` 放进来的 `entry.date`。
    /// 一条时间线里排着一整天的条目，系统提前把每一条都画好，所以小组件的视图只能从这里
    /// 读「现在」，读真实时间（或全局变量）会让每一条都画成生成时间线的那一刻。
    /// 预览画廊把要钉的时刻当作条目的日期传进来，照样钉得住。
    var scheduleWidgetNow: Date {
        get { self[ScheduleWidgetNowEnvironmentKey.self] }
        set { self[ScheduleWidgetNowEnvironmentKey.self] = newValue }
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
        let style = ScheduleStyle.load(from: UserDefaults(suiteName: NextWidgetConfiguration.appGroup))
        let displayOptions = NextWidgetConfiguration.displayOptions
        return Group {
            switch entry.state {
            case .loaded(let payload):
                content(payload)
                    .environment(\.scheduleWidgetNotice, payload.notice(now: entry.date))
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
                                .font(style.widgetFont(size: 9, weight: .semibold))
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
                    detail: "请打开 App，导入一张课表"
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
        .scheduleWidgetStyle(style)
        .environment(\.scheduleWidgetColorfulCourses, !NextWidgetConfiguration.solidCourseColors)
        .environment(\.scheduleWidgetDisplayOptions, displayOptions)
        .environment(\.scheduleWidgetConfiguration, entry.configuration)
        .environment(\.scheduleWidgetCelebrating, entry.celebrating)
        .environment(\.scheduleWidgetFamily, family)
        .environment(\.scheduleWidgetNow, entry.date)
        .widgetURL(entry.appURL)
        .containerBackground(for: .widget) {
            if family.isAccessory {
                Color.clear
            } else {
                ScheduleWidgetImageBackground()
            }
        }
    }
}

/// A removable container background lets the system omit the photo for
/// lock-screen accessories, StandBy and tinted home-screen presentations.
private struct ScheduleWidgetImageBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let store = ScheduleWidgetBackgroundStore.shared
        let dark = colorScheme == .dark
        GeometryReader { geometry in
            ZStack {
                let style = ScheduleStyle.load(from: UserDefaults(suiteName: NextWidgetConfiguration.appGroup))
                style.canvasColor(dark: dark) ?? WidgetPalette.background(for: colorScheme)
                if let url = store.visibleImageURL(dark: dark), let image = backgroundImage(url) {
                    image.resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .opacity(store.settings.opacity(dark: dark))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
    }

    private func backgroundImage(_ url: URL) -> Image? {
        #if canImport(UIKit)
        return UIImage(contentsOfFile: url.path).map { Image(uiImage: $0) }
        #elseif canImport(AppKit)
        return NSImage(contentsOfFile: url.path).map { Image(nsImage: $0) }
        #else
        return nil
        #endif
    }
}

private extension WidgetFamily {
    var isAccessory: Bool {
        self == .accessoryInline || self == .accessoryCircular || self == .accessoryRectangular
    }
}

private struct WidgetMessageView: View {
    @Environment(\.scheduleStyle) private var style
    @WidgetStyleColors private var widgetColors
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
                    .font(style.widgetFont(size: 20, weight: .semibold))
                    .widgetAccentable()
            }
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(style.widgetFont(size: 19, weight: .semibold))
                    .widgetAccentable()
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(style.widgetFont(size: 13, weight: .bold))
                    Text(detail)
                        .font(style.widgetFont(size: 10))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol)
                    .font(style.widgetFont(size: 24, weight: .semibold))
                    .foregroundStyle(widgetColors.accent(for: theme))
                Text(title)
                    .font(style.widgetFont(size: 15, weight: .bold))
                    .foregroundStyle(widgetColors.primary)
                Text(detail)
                    .font(style.widgetFont(size: 11))
                    .foregroundStyle(widgetColors.secondary)
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
    @Environment(\.scheduleWidgetNotice) private var notice
    @Environment(\.scheduleWidgetNow) private var now

    @ViewBuilder
    var body: some View {
        let selection = payload.upcoming(now: now, afterClass: configuration.afterClass)
        // 「接着显示下一次课」把今天换成了别的日子：课程正上方挂一条「明天 周二」。
        // 课程照常上色，压暗是「已经上完」的意思，拿来表示明天的课会被看成上过了。
        let otherDay = OtherDay.offset(of: selection.0, now: now) == nil ? nil : selection.0
        if family.isAccessory {
            LockScreenScheduleView(day: selection.0, courses: selection.1)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                // 换到别的日子时日期栏照旧是今天，靠课程上方的标注说明下面是哪天的课。
                WidgetDateHeader(
                    day: otherDay == nil ? selection.0 : payload.currentDay(now: now),
                    // 休息状态自己会大字写这段假期。
                    hidesCountdown: selection.1.isEmpty && notice == nil,
                    tableName: payload.title
                )
                // 小号放两节时最挤，日期栏和课程之间只留最少的 3；放得下时照样由 Spacer 撑开。
                let twoInSmall = family == .systemSmall && configuration.upcomingCourseCount > 1 && selection.1.count > 1
                Spacer(minLength: twoInSmall ? 3 : 8)

                if selection.1.isEmpty {
                    RestStateView(hadCourses: !payload.currentDay(now: now).courseList.isEmpty)
                } else if family == .systemMedium {
                    let labels = Self.columnLabels(first: selection.1[0], otherDay: otherDay != nil, now: now)
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
                        // 两节挤在小号里：第一节课名只占一行，第二节不再另起标题。再挂上「明天 周三」
                        // 和日期栏的假期倒计时就放不下了：只收间距，教室一定要留着。
                        ViewThatFits(in: .vertical) {
                            twoCourses(first: course, second: selection.1[1], otherDay: otherDay, gap: 6)
                            twoCourses(first: course, second: selection.1[1], otherDay: otherDay, gap: 3)
                            twoCourses(first: course, second: selection.1[1], otherDay: otherDay, gap: 2, lineSpacing: 1)
                            // SE 这样的小屏。
                            twoCourses(first: course, second: selection.1[1], otherDay: otherDay, gap: 1, lineSpacing: 0)
                        }
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .layoutPriority(1)
                    } else {
                        // 只放一节时中间空着一大块：像中号一样标上「当前」「下一节」，字也大一号。
                        // 课名折成两行、屏幕又小时放不下，先去标题，再退回原来的字号；
                        // 别的日子的标注不能去，只退字号。
                        // 大屏上多出来的高度全压在日期和课程之间会显得空：放得下时底下也垫一点，
                        // 空白分到上下两边；小屏照旧贴底。
                        let label = Self.columnLabels(first: course, otherDay: otherDay != nil, now: now).first
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

    /// 小号放两节：「明天 周三」、第一节、第二节，彼此隔开 `gap`；第一节的三行之间隔 `lineSpacing`。
    private func twoCourses(
        first: WidgetCourse,
        second: WidgetCourse,
        otherDay: WidgetDay?,
        gap: CGFloat,
        lineSpacing: CGFloat = 3
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let otherDay {
                OtherDayBanner(day: otherDay)
                    .padding(.bottom, gap)
            }
            CourseSummary(course: first, size: .regular, titleLines: 1, lineSpacing: lineSpacing)
            Spacer(minLength: gap)
            CompactNextCourse(course: second)
        }
    }

    /// 中号两栏（小号一节）的标题。第一节还没开始时叫「当前」就错了：那是下一节。
    /// 别的日子的课换成「明天 周二」标注，用不到这里的字。
    private static func columnLabels(first: WidgetCourse, otherDay: Bool, now: Date) -> (first: String, second: String) {
        if otherDay { return ("第一节", "接下来") }
        if first.isInProgress(at: WidgetSchedulePayload.minutesSinceMidnight(now)) { return ("当前", "接下来") }
        return ("下一节", "之后")
    }
}

private struct LockScreenScheduleView: View {
    @Environment(\.scheduleStyle) private var style
    let day: WidgetDay
    let courses: [WidgetCourse]
    @Environment(\.scheduleWidgetFamily) private var family
    @Environment(\.scheduleWidgetDisplayOptions) private var options
    @Environment(\.scheduleWidgetNotice) private var notice
    @Environment(\.scheduleWidgetNow) private var now

    /// 没课时的图标：放假、过期各有各的。
    private var emptySymbol: String { notice?.symbol ?? "calendar.badge.checkmark" }

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
            Image(systemName: courses.isEmpty ? emptySymbol : "book.closed.fill")
        }
        .lineLimit(1)
    }

    /// 单行锁屏只有一句话的位置：祝福 → 假期倒计时 → 「今日无课」。
    private var inlineEmptyText: String {
        notice?.inlineText ?? RestState.inlineText(options: options, now: now)
    }

    private var circularView: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let course = courses.first {
                VStack(spacing: 0) {
                    Image(systemName: "book.closed.fill")
                        .font(style.widgetFont(size: 10, weight: .semibold))
                        .widgetAccentable()
                    if options.showTime {
                        Text(course.startLabel)
                            .font(style.widgetFont(size: 12, weight: .bold, design: .rounded))
                            .minimumScaleFactor(0.72)
                    }
                    if let primary = options.primaryValue(for: course), primary != course.timeRange {
                        Text(primary)
                            .font(style.widgetFont(size: 8, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                    }
                }
                .padding(5)
            } else {
                VStack(spacing: 1) {
                    Image(systemName: emptySymbol)
                        .font(style.widgetFont(size: 15, weight: .semibold))
                        .widgetAccentable()
                    Text(notice?.circularText ?? "无课")
                        .font(style.widgetFont(size: 9, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
    }

    private var rectangularView: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: courses.isEmpty ? emptySymbol : "book.closed.fill")
                    .font(style.widgetFont(size: 10, weight: .semibold))
                    .widgetAccentable()
                // 换到了别的日子时带上「明天」，锁屏上只有这一行说明是哪天。
                Text([OtherDay.label(for: day, now: now) ?? "", day.compactDate, day.displayLabel].filter { !$0.isEmpty }.joined(separator: " "))
                    .font(style.widgetFont(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 2)
                if courses.count > 1 {
                    Text("下一节 \(courses[1].startLabel)")
                        .font(style.widgetFont(size: 9, weight: .medium))
                        .lineLimit(1)
                }
            }
            if let course = courses.first {
                if let primary = options.primaryValue(for: course) {
                    Text(primary)
                        .font(style.widgetFont(size: 14, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                if let metadata = options.metadata(for: course) {
                    Text(metadata)
                        .font(style.widgetFont(size: 10, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                if options.showTime {
                    Text(course.timeRange)
                        .font(style.widgetFont(size: 10, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            } else {
                let lines = emptyLines
                Text(lines.primary)
                    .font(style.widgetFont(size: 14, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                if let secondary = lines.secondary {
                    Text(secondary)
                        .font(style.widgetFont(size: 10, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// 休息状态：有假期就大字写假期、小字写「4 天后 · 10.1 - 10.7 · 休 7 天」，没有才说「今日无课」。
    private var emptyLines: (primary: String, secondary: String?) {
        if let notice { return (notice.title, notice.detail(now: now)) }
        guard let holiday = RestState.holiday(options: options, now: now) else {
            return ("今日无课", "打开课表查看本周安排")
        }
        return (holiday.title, "\(holiday.caption) · \(holiday.detail)")
    }

    private func inlineText(_ course: WidgetCourse) -> String {
        [
            OtherDay.label(for: day, now: now) ?? day.shortLabel,
            options.showTime ? course.startLabel : nil,
            options.primaryValue(for: course),
            options.metadata(for: course)
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }
}

private struct UpcomingColumn: View {
    @Environment(\.scheduleStyle) private var style
    @WidgetStyleColors private var widgetColors
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
                    .font(style.widgetFont(size: 11, weight: .semibold))
                    .foregroundStyle(widgetColors.secondary)
                    .frame(height: OtherDayBanner.height, alignment: .leading)
            }
            if let course {
                CourseSummary(course: course, size: size)
            } else {
                Text("暂无课程")
                    .font(style.widgetFont(size: 11))
                    .foregroundStyle(widgetColors.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CourseSummary: View {
    @WidgetStyleColors private var widgetColors
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
    /// 课名、教室老师、时间三行之间的间距。小号放两节挤不下时收紧。
    var lineSpacing: CGFloat = 3
    @Environment(\.scheduleWidgetTheme) private var theme
    @Environment(\.scheduleWidgetColorfulCourses) private var colorfulCourses
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scheduleWidgetDisplayOptions) private var options
    @Environment(\.scheduleStyle) private var style

    var body: some View {
        let appearance = ScheduleWidgetStylePalette(style: style, dark: colorScheme == .dark, theme: ThemePalette.of(NextWidgetConfiguration.globalBrandColor))
        // 色条跟着文字一样高，不拉到底。
        HStack(alignment: .top, spacing: 9) {
            RoundedRectangle(cornerRadius: style == .minimal ? 3 : appearance.courseRadius)
                .fill(widgetColors.accent(for: course, theme: theme, colorful: colorfulCourses, colorScheme: colorScheme))
                .frame(width: 5)
                .frame(maxHeight: .infinity)
            VStack(alignment: style.layout.centered ? .center : .leading, spacing: lineSpacing) {
                if options.showTime && style == .board {
                    Text(course.timeRange)
                        .font(style.widgetFont(size: size.time, weight: .semibold))
                        .foregroundStyle(widgetColors.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                if let primary = options.primaryValue(for: course) {
                    Text(primary)
                        .font(style.widgetFont(size: size.title, weight: .bold))
                        .foregroundStyle(widgetColors.primary)
                        .lineLimit(titleLines)
                        .minimumScaleFactor(0.76)
                }
                if let metadata = options.metadata(for: course) {
                    Text(metadata)
                        .font(style.widgetFont(size: size.metadata))
                        .foregroundStyle(widgetColors.secondary)
                        .lineLimit(1)
                }
                if options.showTime && style != .board {
                    Text(course.timeRange)
                        .font(style.widgetFont(size: size.time, weight: .semibold))
                        .foregroundStyle(widgetColors.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
        .multilineTextAlignment(style.layout.centered ? .center : .leading)
        .padding(style == .grid ? 4 : 0)
        .overlay {
            WidgetCourseRule(color: style == .grid ? widgetColors.accent(for: course, theme: theme, colorful: colorfulCourses, colorScheme: colorScheme) : widgetColors.primary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CompactNextCourse: View {
    @WidgetStyleColors private var widgetColors
    let course: WidgetCourse
    @Environment(\.scheduleWidgetTheme) private var theme
    @Environment(\.scheduleWidgetColorfulCourses) private var colorfulCourses
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scheduleWidgetDisplayOptions) private var options
    @Environment(\.scheduleStyle) private var style

    var body: some View {
        let appearance = ScheduleWidgetStylePalette(style: style, dark: colorScheme == .dark, theme: ThemePalette.of(NextWidgetConfiguration.globalBrandColor))
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: style == .minimal ? 3 : appearance.courseRadius)
                .fill(widgetColors.accent(for: course, theme: theme, colorful: colorfulCourses, colorScheme: colorScheme))
                .frame(width: 5, height: 27)
            VStack(alignment: style.layout.centered ? .center : .leading, spacing: 1) {
                if let primary = options.primaryValue(for: course) {
                    Text(primary)
                        .font(style.widgetFont(size: 12, weight: .bold))
                        .foregroundStyle(widgetColors.primary)
                        .lineLimit(1)
                }
                if options.showTime {
                    Text(course.timeRange)
                        .font(style.widgetFont(size: 9))
                        .foregroundStyle(widgetColors.secondary)
                        .lineLimit(1)
                }
            }
        }
        .multilineTextAlignment(style.layout.centered ? .center : .leading)
        .padding(style == .grid ? 4 : 0)
        .overlay {
            WidgetCourseRule(color: style == .grid ? widgetColors.accent(for: course, theme: theme, colorful: colorfulCourses, colorScheme: colorScheme) : widgetColors.primary)
        }
    }
}

private struct TodayScheduleView: View {
    let payload: WidgetSchedulePayload
    @Environment(\.scheduleWidgetFamily) private var family
    @Environment(\.scheduleWidgetConfiguration) private var configuration
    @Environment(\.scheduleWidgetNotice) private var notice
    @Environment(\.scheduleWidgetNow) private var now

    var body: some View {
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
                    // 休息状态自己会大字写这段假期；寒暑假、课表过期时日期栏照旧带着倒计时。
                    WidgetDateHeader(day: today, hidesCountdown: notice == nil, tableName: payload.title)
                    // 寒暑假、课表过期：大号把「寒假ing」「打开 App 更新课表」摆在中间；中号交给 RestStateView。
                    if family == .systemLarge, let notice {
                        ScheduleNoticeGreetingView(notice: notice)
                    // 大号放假当天和两日课表一样：图标、祝福和假期进度占住中间，不再只有底下一小段。
                    } else if family == .systemLarge, today.courseList.isEmpty,
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
        RemainingCoursesText(count: count)
    }
}

private struct TodayCourseRow: View {
    @WidgetStyleColors private var widgetColors
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
    @Environment(\.scheduleStyle) private var style

    var body: some View {
        let appearance = ScheduleWidgetStylePalette(style: style, dark: colorScheme == .dark, theme: ThemePalette.of(NextWidgetConfiguration.globalBrandColor))
        HStack(spacing: large ? 9 : 6) {
            RoundedRectangle(cornerRadius: style == .minimal ? 3 : appearance.courseRadius)
                .fill(widgetColors.accent(for: course, theme: theme, colorful: colorfulCourses, colorScheme: colorScheme))
                .frame(width: 5, height: large ? 40 : (timeOnSeparateLine ? 39 : 29))
            VStack(alignment: .leading, spacing: 2) {
                if let primary = options.primaryValue(for: course) {
                    Text(primary)
                        .font(style.widgetFont(size: large ? 14 : 12, weight: .bold))
                        .foregroundStyle(widgetColors.primary)
                        .lineLimit(1)
                }
                if let metadata = options.metadata(for: course) {
                    Text(metadata)
                        .font(style.widgetFont(size: large ? 10 : 9, weight: .medium))
                        .foregroundStyle(widgetColors.secondary)
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
            RoundedRectangle(cornerRadius: style == .minimal ? (large ? 11 : 8) : appearance.courseRadius)
                .fill(
                    renderingMode == .fullColor
                        ? (style == .minimal
                            ? widgetColors.tint(for: course, colorScheme: colorScheme, theme: theme, colorful: colorfulCourses)
                            : widgetColors.accent(for: course, theme: theme, colorful: colorfulCourses, colorScheme: colorScheme).opacity(appearance.courseFillOpacity))
                        : Color.white
                )
                // Clear and tinted Home Screen appearances render widgets in
                // accented mode and remap opaque colors to solid white.
                .opacity(renderingMode == .fullColor ? 1 : 0.14)
        }
        .overlay {
            WidgetCourseRule(color: style == .grid ? widgetColors.accent(for: course, theme: theme, colorful: colorfulCourses, colorScheme: colorScheme) : widgetColors.primary)
        }
        .saturation(completed ? 0 : 1)
        .opacity(completed ? 0.56 : 1)
    }

    private var timeLabel: some View {
        Text(course.timeRange)
            .font(style.widgetFont(size: large ? 10 : 9, weight: .semibold))
            .foregroundStyle(widgetColors.primary)
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

nonisolated private struct ProportionalWeight: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}

nonisolated private struct ProportionalMaxHeight: LayoutValueKey {
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
    @WidgetStyleColors private var widgetColors
    let course: WidgetCourse
    let completed: Bool
    let inProgress: Bool
    let metrics: TimelineMetrics
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scheduleWidgetTheme) private var theme
    @Environment(\.scheduleWidgetColorfulCourses) private var colorfulCourses
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.scheduleWidgetDisplayOptions) private var options
    @Environment(\.scheduleStyle) private var style

    var body: some View {
        let appearance = ScheduleWidgetStylePalette(style: style, dark: colorScheme == .dark, theme: ThemePalette.of(NextWidgetConfiguration.globalBrandColor))
        let accent = widgetColors.accent(for: course, theme: theme, colorful: colorfulCourses, colorScheme: colorScheme)
        HStack(alignment: .top, spacing: metrics.columnSpacing) {
            if options.showTime {
                // 开始时间对着卡片顶，结束时间对着卡片底：卡片被拉高时，一眼看得出这门课有多长。
                VStack(alignment: .trailing, spacing: 0) {
                    Text(course.startLabel)
                        .font(style.widgetFont(size: metrics.startFont, weight: .bold))
                        .foregroundStyle(inProgress ? accent : widgetColors.primary)
                    Spacer(minLength: 2)
                    if let end = endLabel {
                        Text(end)
                            .font(style.widgetFont(size: metrics.endFont, weight: .medium))
                            .foregroundStyle(widgetColors.secondary)
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
                RoundedRectangle(cornerRadius: style == .minimal ? 2.5 : appearance.courseRadius)
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
                RoundedRectangle(cornerRadius: style == .minimal ? metrics.cornerRadius : appearance.courseRadius)
                    .fill(
                        renderingMode == .fullColor
                            ? (style == .minimal
                                ? widgetColors.tint(for: course, colorScheme: colorScheme, theme: theme, colorful: colorfulCourses)
                                : accent.opacity(appearance.courseFillOpacity))
                            : Color.white
                    )
                    .opacity(renderingMode == .fullColor ? 1 : 0.14)
            }
            .overlay {
                WidgetCourseRule(color: style == .grid ? widgetColors.accent(for: course, theme: theme, colorful: colorfulCourses, colorScheme: colorScheme) : widgetColors.primary)
            }
        }
        .saturation(completed ? 0 : 1)
        .opacity(completed ? 0.56 : 1)
    }

    @ViewBuilder
    private var titleText: some View {
        if let primary = options.primaryValue(for: course) {
            Text(primary)
                .font(style.widgetFont(size: metrics.titleFont, weight: .bold))
                .foregroundStyle(widgetColors.primary)
        }
    }

    private func metaText(_ value: String) -> some View {
        Text(value)
            .font(style.widgetFont(size: metrics.metaFont, weight: .medium))
            .foregroundStyle(widgetColors.secondary)
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
    @Environment(\.scheduleStyle) private var style
    @WidgetStyleColors private var widgetColors
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
                        .foregroundStyle(widgetColors.muted)
                        .frame(width: 2)
                        .padding(.leading, metrics.barCenter - 1)
                    Text(isNow ? "休息中 · \(Self.duration(minutes))" : "休息 \(Self.duration(minutes))")
                        .font(style.widgetFont(size: metrics.gapFont, weight: .semibold))
                        .foregroundStyle(isNow ? widgetColors.accent(for: theme) : widgetColors.muted)
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
    @Environment(\.scheduleWidgetNotice) private var notice
    @Environment(\.scheduleWidgetNow) private var now

    var body: some View {
        if let notice {
            // 寒暑假、课表过期：两列都没有课可列，整块只放今天的日期和中间的「寒假ing」。
            VStack(alignment: .leading, spacing: 0) {
                WidgetDateHeader(day: payload.currentDay(now: now), tableName: payload.title)
                ScheduleNoticeGreetingView(notice: notice)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
            columns
        }
    }

    private var columns: some View {
        let today = payload.currentDay(now: now)
        let tomorrowDate = WidgetSchedulePayload.dateString(
            Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now
        )
        // 左边固定是今天（没课就说没课、道祝福），右边是今天之后最近有课的一天，跳过周末和
        // 放假；三周内都没课时照旧是明天。
        let next = payload.nextCourseDay(after: now)
        let right = next?.day ?? payload.fullDay(for: tomorrowDate, fallbackOffset: 1)

        // 右边不是明天时标上「后天的课」「10/2 的课」。左边占着同样一行但不显示，两列的课才对得齐。
        let rightHint = (next?.offset ?? 1) > 1 ? OtherDay.hint(for: right, now: now) : nil
        // 两天同一周，「第 N 周」只在右边写一次：靠着组件右上角，读起来是整块的标题。
        let sameWeek = today.week != nil && today.week == right.week
        let leftHeader = WidgetDateHeader(
            day: today, compact: true, tableName: payload.title, dayHint: rightHint, hidesDayHint: true,
            hidesWeek: sameWeek
        )
        let rightHeader = WidgetDateHeader(
            day: right, compact: true, tableName: payload.title, hidesTableName: true, dayHint: rightHint
        )
        return HStack(alignment: .top, spacing: 13) {
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
    @Environment(\.scheduleWidgetNow) private var now

    /// 一列最多试着放几门。再多半宽的列也放不下，剩下的写进「后面还有 N 门课」。
    private static let maxLimit = 8

    var body: some View {
        if day.courseList.isEmpty {
            column(limit: 0)
        } else {
            // 以前写死 5 门，多出来的课会被悄悄截掉。和今日课表一样从多到少试，挑第一个放得下的，
            // 「后面还有几门」才数得准。
            ViewThatFits(in: .vertical) {
                ForEach(Array(stride(from: min(day.courseList.count, Self.maxLimit), through: 1, by: -1)), id: \.self) { limit in
                    column(limit: limit)
                }
            }
        }
    }

    private func column(limit: Int) -> some View {
        let window = day.courseWindow(limit: limit, nowMinutes: nowMinutes)
        return VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topLeading) {
                companionHeader.hidden()
                header
            }
                // 日期栏和下面的课拉开到 18（加上外面 VStack 的 7），比课与课之间松。
                .padding(.bottom, 11)
            if day.courseList.isEmpty {
                // 这一支本来就是「这天没有课」，所以今天那列固定说「今日无课」；
                // 今天是法定假日就换成带图标和假期进度的祝福，整列不再只有一行灰字。
                if isToday, let greeting = ChineseCalendarInfo.restGreeting(for: now) {
                    HolidayGreetingView(greeting: greeting)
                } else {
                    EmptyCoursesView(
                        message: isToday ? RestState.message(now: now) : "没有课程"
                    )
                }
            } else {
                Group {
                    if timeline {
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
                if window.remainingCount > 0 {
                    RemainingCoursesText(count: window.remainingCount)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.top, 3)
                }
            }
        }
        // 时间线要往下铺满整列；列表照旧按内容高度贴顶。ViewThatFits 量的是理想高度，挑行数不受影响。
        .fixedSize(horizontal: false, vertical: !timeline && !day.courseList.isEmpty)
        .frame(maxWidth: .infinity, maxHeight: timeline ? .infinity : nil, alignment: .topLeading)
    }
}

/// 「后面还有 N 门课」。没显示的都排在最后一行之后（已经上完的才会被省在前面），所以说「后面」。
private struct RemainingCoursesText: View {
    @Environment(\.scheduleStyle) private var style
    @WidgetStyleColors private var widgetColors
    let count: Int

    var body: some View {
        Text("后面还有 \(count) 门课")
            .font(style.widgetFont(size: 9, weight: .medium))
            .foregroundStyle(widgetColors.muted)
            .lineLimit(1)
    }
}

private struct WidgetDateHeader: View {
    @Environment(\.scheduleStyle) private var style
    @WidgetStyleColors private var widgetColors
    let day: WidgetDay
    /// 两日课表的列只有半个组件宽：右侧的节日徽标和第二行的假期倒计时在那里放不下。
    var compact = false
    /// 下面的休息状态已经在大字显示同一段假期时，日期栏就别重复倒计时了。
    var hidesCountdown = false
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
    private var columnHeight: CGFloat {
        if isLarge { return 35 }
        return family == .systemMedium ? 30 : 27
    }

    /// 2×1 的日期栏有更充足的横向空间，字号比小号更醒目。
    private var dateFontSize: CGFloat {
        if isLarge { return 29 }
        return family == .systemMedium ? 24 : 22
    }

    var body: some View {
        // 「周五」「初八」各自竖排成一列，日期、星期、农历之间各一条竖线。
        let isCompact = compact || family == .systemSmall
        // 两行之间几乎不留空：竖线本身比字高，行距再拉开就散了。
        VStack(alignment: .leading, spacing: 0) {
            header(isCompact: isCompact)
            secondaryLine
                // 竖线比字高，靠负边距把这行收回去，贴着上一行的文字底部。「明天的课」带着
                // 胶囊底色，比字高，再往上收就压住上一行的「第 N 周」，反过来留一点空。
                // 中号（2×1）的小组件里课表名紧跟在日期下方，额外留一点间隔更易读。
                .padding(.top, dayHint == nil
                    ? (family == .systemLarge && !compact ? 4 : (family == .systemMedium ? 1 : (family == .systemSmall ? 3 : -2)))
                    : 4)
        }
        // 第二行的 ViewThatFits 报的最小高度是最矮那种排法（倒计时不换行），外面的 VStack
        // 照这个预留，下面的课就会多分到一截、以为放得下，整块撑出组件。按实际高度占位。
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 第二行：左边课表名、调休，右边「明天的课」或常驻的假期倒计时。一行挤不下（小号）时
    /// 倒计时换到下一行；连这样都放不下才按重要程度往下减：先去倒计时，再去课表名，
    /// 「明天的课」要一直在，调休一句话自己都放不下时交给它自己的缩字。
    @ViewBuilder
    private var secondaryLine: some View {
        let note = day.normalizedNote.flatMap { repeatsBadge($0) ? nil : $0 }
        let trimmedName = tableName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 只占位的课表名碰上调休：这一行已经有调休撑着了，别把它往右推。
        let name: String? = trimmedName.isEmpty || (hidesTableName && note != nil) ? nil : trimmedName
        // 调休那天不报倒计时；那个位置有「明天的课」时让给它。
        let countdown = day.normalizedNote == nil && !compact && dayHint == nil ? holidayCountdown : nil
        if note != nil || name != nil || dayHint != nil || countdown != nil {
            ViewThatFits(in: .horizontal) {
                secondaryRow(name: name, note: note, countdown: countdown)
                if let countdown {
                    VStack(alignment: .trailing, spacing: 1) {
                        secondaryRow(name: name, note: note)
                        HolidayCountdownChip(countdown: countdown, sizeBoost: min(sizeBoost, 2))
                            .fixedSize()
                    }
                }
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

    private func secondaryRow(name: String?, note: String?, countdown: ChineseHolidayCountdown? = nil) -> some View {
        HStack(spacing: 6) {
            if let name {
                Text(name)
                    .font(style.widgetFont(size: 9, weight: .semibold))
                    .foregroundStyle(widgetColors.muted)
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
            } else if let countdown {
                HolidayCountdownChip(countdown: countdown, sizeBoost: min(sizeBoost, 2))
                    .fixedSize()
            }
        }
    }

    private func header(isCompact: Bool) -> some View {
        let weekday = day.displayLabel.isEmpty ? nil : day.displayLabel
        // 小号一行要塞下日期、星期、农历和「第 N 周」，各列之间收紧一点。
        return HStack(spacing: isCompact ? 4 : (isLarge ? 8 : 6)) {
            // 小号里一行很挤，日期绝不能被压得折行，宁可让右边的周数让位。
            Text(day.dayOfMonthLabel)
                .font(style.widgetFont(size: dateFontSize, weight: .bold, design: .rounded))
                .foregroundStyle(widgetColors.primary)
                .lineLimit(1)
                .fixedSize()

            columnDivider

            if let weekday {
                verticalText(
                    weekday,
                    weight: .bold,
                    color: weekday == "周六" || weekday == "周日"
                        ? Color.pink
                        : widgetColors.accent(for: theme)
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
                VStack(alignment: isCompact ? .center : .trailing, spacing: 2) {
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
                    if isCompact, let badge = badgeText {
                        HolidayBadge(title: badge, highlighted: calendarDay?.isStatutoryHoliday ?? false)
                    }
                }
                // 小号与两日课表每列的右侧共用两行栏，周数和节日居中对齐。
                .frame(
                    minWidth: isCompact ? 48 : nil,
                    alignment: isCompact ? .center : .trailing
                )
                .offset(y: family == .systemSmall ? 4 : 0)
            } else if isCompact, let badge = badgeText {
                HolidayBadge(title: badge, highlighted: calendarDay?.isStatutoryHoliday ?? false)
                    .frame(minWidth: 48, alignment: .center)
                    .offset(y: family == .systemSmall ? 4 : 0)
            }
        }
    }

    /// 不给字号就是这个尺寸的默认字号（大号放大过）。
    private func weekLabel(_ text: String, size: CGFloat? = nil) -> some View {
        Text(text)
            .font(style.widgetFont(size: size ?? 10 + min(sizeBoost, 2), weight: .semibold))
            .foregroundStyle(widgetColors.secondary)
            .lineLimit(1)
            .fixedSize()
    }

    private var columnDivider: some View {
        Rectangle()
            .fill(widgetColors.muted.opacity(0.45))
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
                    .font(style.widgetFont(size: size, weight: weight))
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

    /// 服务端自动生成的放假说明就是假期名本身（「中秋节」），
    /// 节日名已经在右侧徽标里了，再在下面写一遍就重复了。
    private func repeatsBadge(_ note: String) -> Bool {
        guard let badgeText else { return false }
        return note == badgeText || note == badgeText + "放假" || badgeText.hasPrefix(note)
    }

    private var lunarText: String? {
        guard options.showLunarDate, let calendarDay else { return nil }
        return calendarDay.lunar.shortLabel
    }

    /// 星期旁边那一列始终用于农历，节日单独显示在右侧。
    private var stackedDetail: String? {
        return lunarText
    }

    private var detailColor: Color {
        return widgetColors.secondary
    }

    /// 开了「始终显示最近节假日」时，今天不在假期里就提示最近的一段法定假期（看未来 120 天）。
    private var holidayCountdown: ChineseHolidayCountdown? {
        guard options.showsResidentHoliday, !hidesCountdown else { return nil }
        guard let date = day.date, let reference = ChineseCalendarInfo.date(fromDate: date),
              let next = ChineseCalendarInfo.countdown(from: reference, withinDays: 120),
              next.daysAway > 0 else { return nil }
        return next
    }
}

/// 日期栏第二行右边常驻的假期倒计时：「距国庆节还有 5 天」，天数用主题色大一号。
/// 只报还剩几天，右边缘和上一行的「第 N 周」对齐：多一个色块或日期，两行的右端就对不上了。
private struct HolidayCountdownChip: View {
    @Environment(\.scheduleStyle) private var style
    @WidgetStyleColors private var widgetColors
    let countdown: ChineseHolidayCountdown
    /// 大号日期栏放大过字，这里跟着放大一点。
    var sizeBoost: CGFloat = 0
    @Environment(\.scheduleWidgetTheme) private var theme
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        countdownText(tint: renderingMode == .fullColor ? widgetColors.accent(for: theme) : widgetColors.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private func countdownText(tint: Color) -> Text {
        let leading = Text(countdown.leading)
            .font(style.widgetFont(size: 10 + sizeBoost, weight: .semibold))
            .foregroundColor(widgetColors.secondary)
        guard let amount = countdown.amount else { return leading }
        return leading
            + Text(" ")
            + Text(amount)
                .font(style.widgetFont(size: 12 + sizeBoost, weight: .bold, design: .rounded))
                .foregroundColor(tint)
            + Text(" " + countdown.trailing)
                .font(style.widgetFont(size: 10 + sizeBoost, weight: .semibold))
                .foregroundColor(widgetColors.secondary)
    }
}

/// 选了「接着显示下一次课」、小组件换到别的日子时，日期栏上的标注：「明天的课」「10/2 的课」。
private struct OtherDayChip: View {
    @Environment(\.scheduleStyle) private var style
    @WidgetStyleColors private var widgetColors
    let title: String
    @Environment(\.scheduleWidgetTheme) private var theme
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let tint = widgetColors.accent(for: theme)
        Text(title)
            .font(style.widgetFont(size: 9, weight: .bold))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background {
                Capsule().fill(renderingMode == .fullColor ? tint.opacity(0.16) : Color.white.opacity(0.14))
            }
            .foregroundStyle(renderingMode == .fullColor ? tint : widgetColors.primary)
    }
}

/// 某一天离今天几天，用来说「明天」「后天」「3 天后」。今天及以前返回 `nil`。
private enum OtherDay {
    static func offset(of day: WidgetDay, now: Date) -> Int? {
        guard let date = day.date, let target = ChineseCalendarInfo.date(fromDate: date) else { return nil }
        let calendar = ChineseCalendarInfo.gregorian
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: target)).day ?? 0
        return days > 0 ? days : nil
    }

    /// 「明天」「后天」「3 天后」。
    static func label(for day: WidgetDay, now: Date) -> String? {
        guard let days = offset(of: day, now: now) else { return nil }
        switch days {
        case 1: return "明天"
        case 2: return "后天"
        default: return "\(days) 天后"
        }
    }

    /// 日期栏上的「明天的课」「后天的课」；再往后直接写日期：「10/2 的课」。
    static func hint(for day: WidgetDay, now: Date) -> String? {
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
    @Environment(\.scheduleStyle) private var style
    @WidgetStyleColors private var widgetColors
    /// 胶囊的高度。临近课程的纯文字标题也占这么高，换不换日子课的位置都不跳。
    static let height: CGFloat = 16

    let day: WidgetDay
    @Environment(\.scheduleWidgetTheme) private var theme
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.scheduleWidgetNow) private var now

    var body: some View {
        let tint = widgetColors.accent(for: theme)
        let fullColor = renderingMode == .fullColor
        // 醒目只交给胶囊一处，后面的星期用灰字：再用强调色写一遍日期，就和上面日期栏的
        // 今天叠成两行日期，分不清哪个是课的日子。明天、后天不写日期，胶囊已经说了。
        let near = (OtherDay.offset(of: day, now: now) ?? 1) <= 2
        let detail = (near ? [day.displayLabel] : [day.compactDate, day.displayLabel])
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        HStack(spacing: 5) {
            Text(OtherDay.label(for: day, now: now) ?? "")
                .font(style.widgetFont(size: 10, weight: .heavy))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background {
                    Capsule().fill(fullColor ? tint : Color.white.opacity(0.28))
                }
                .foregroundStyle(fullColor ? Color.white : widgetColors.primary)
                .widgetAccentable()
            Text(detail)
                .font(style.widgetFont(size: 11, weight: .semibold))
                .foregroundStyle(widgetColors.secondary)
        }
        .lineLimit(1)
        .fixedSize()
        .frame(height: Self.height)
    }
}

/// 日期栏下面那行调休提示：「上 10.9 周四的课」「国庆节放假」。
private struct AdjustmentNoteChip: View {
    @Environment(\.scheduleStyle) private var style
    @WidgetStyleColors private var widgetColors
    let note: String
    @Environment(\.scheduleWidgetTheme) private var theme
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(style.widgetFont(size: 8, weight: .bold))
            Text(note)
                .font(style.widgetFont(size: 9, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(renderingMode == .fullColor ? widgetColors.accent(for: theme) : widgetColors.primary)
    }
}

/// 节日/法定假期徽标。法定假期用粉色，普通节日和节气跟随主题色。
private struct HolidayBadge: View {
    @Environment(\.scheduleStyle) private var style
    @WidgetStyleColors private var widgetColors
    let title: String
    let highlighted: Bool
    @Environment(\.scheduleWidgetTheme) private var theme
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let tint = highlighted ? Color.pink : widgetColors.accent(for: theme)
        Text(title)
            .font(style.widgetFont(size: 9, weight: .bold))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background {
                Capsule().fill(renderingMode == .fullColor ? tint.opacity(0.16) : Color.white.opacity(0.14))
            }
            .foregroundStyle(renderingMode == .fullColor ? tint : widgetColors.primary)
    }
}

/// 休息状态：今天是法定假日就道贺（「中秋快乐」），
/// 其余一律「今日无课」；下面一行小字是最近的一段法定假期。
private enum RestState {
    static func message(now: Date) -> String {
        ChineseCalendarInfo.restGreeting(for: now) ?? "今日无课"
    }

    static func countdown(options: ScheduleWidgetDisplayOptions, now: Date) -> ChineseHolidayCountdown? {
        guard options.showHoliday else { return nil }
        return ChineseCalendarInfo.countdown(from: now, withinDays: 120)
    }

    /// 休息时顶上来的那段假期，排成和「临近课程」一样的三行：小标签「4 天后」、
    /// 标题「国庆节」、说明「10.1 - 10.7 · 休 7 天」。已经在放假就是「放假中」「国庆快乐」。
    /// 关掉节假日提示或 120 天内没有假期时为 `nil`。
    static func holiday(
        options: ScheduleWidgetDisplayOptions,
        now: Date
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
    static func inlineText(options: ScheduleWidgetDisplayOptions, now: Date) -> String {
        if let greeting = ChineseCalendarInfo.restGreeting(for: now) { return greeting }
        if let countdown = countdown(options: options, now: now), countdown.daysAway > 0 {
            return countdown.phrase
        }
        return "今日无课"
    }
}

private struct EmptyCoursesView: View {
    @Environment(\.scheduleStyle) private var style
    @WidgetStyleColors private var widgetColors
    let message: String

    var body: some View {
        Text(message)
            .font(style.widgetFont(size: 12, weight: .semibold))
            .foregroundStyle(widgetColors.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

/// 两日课表放假当天今天那一列：图标、祝福，下面是这段假期的日期和进度（一天一个点，过去的和今天实心）。
/// 半个组件宽、一整列高，只写一行「国庆快乐」太空。关掉节假日提示时只留图标和祝福。
private struct HolidayGreetingView: View {
    @Environment(\.scheduleStyle) private var style
    @WidgetStyleColors private var widgetColors
    let greeting: String
    @Environment(\.scheduleWidgetDisplayOptions) private var options
    @Environment(\.scheduleWidgetCelebrating) private var celebrating
    @Environment(\.scheduleWidgetFireworksPreviewTime) private var previewTime
    @Environment(\.scheduleWidgetNow) private var now

    var body: some View {
        let countdown = RestState.countdown(options: options, now: now).flatMap { $0.daysAway == 0 ? $0 : nil }
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                icon
                VStack(spacing: 4) {
                    Text(greeting)
                        .font(style.widgetFont(size: 17, weight: .bold))
                        .foregroundStyle(widgetColors.primary)
                    if let countdown {
                        Text(Self.dateText(for: countdown, now: now))
                            .font(style.widgetFont(size: 10, weight: .medium))
                            .foregroundStyle(widgetColors.secondary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                if let countdown, let progress = Self.progress(of: countdown.window, now: now) {
                    VStack(spacing: 6) {
                        HStack(spacing: 4) {
                            ForEach(1...progress.total, id: \.self) { index in
                                Circle()
                                    .fill(index <= progress.day ? Color.pink : widgetColors.muted.opacity(0.3))
                                    .frame(width: 6, height: 6)
                                    .widgetAccentable(index <= progress.day)
                            }
                        }
                        Text(progress.day == progress.total ? "假期最后一天" : "第 \(progress.day) 天 · 还剩 \(progress.total - progress.day) 天")
                            .font(style.widgetFont(size: 9, weight: .semibold))
                            .foregroundStyle(widgetColors.muted)
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
            .font(style.widgetFont(size: 30, weight: .semibold))
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
    private static func dateText(for countdown: ChineseHolidayCountdown, now: Date) -> String {
        let window = countdown.window
        guard progress(of: window, now: now) != nil else { return countdown.dateLabel }
        return "\(ChineseCalendarInfo.monthDayLabel(window.start)) - \(ChineseCalendarInfo.monthDayLabel(window.end))"
    }

    /// 今天是这段假期的第几天、一共几天。只有一天的假期不画点。
    private static func progress(of window: ChineseHolidayWindow, now: Date) -> (day: Int, total: Int)? {
        let total = window.dayCount
        let today = ChineseCalendarInfo.dateString(now)
        guard total > 1, total <= 12, let gap = ChineseCalendarInfo.dayGap(from: window.start, to: today) else { return nil }
        return (min(max(gap + 1, 1), total), total)
    }
}

/// 彩炮在小组件里的位置。只有放假祝福里的彩炮会报，报了最外层才铺烟花。
private struct FireworksOriginKey: PreferenceKey {
    static let defaultValue: Anchor<CGPoint>? = nil

    static func reduce(value: inout Anchor<CGPoint>?, nextValue: () -> Anchor<CGPoint>?) {
        value = value ?? nextValue()
    }
}

/// 今天没有要列的课时的主视图。上面一行小字交代今天：「今日课程已结束」或「今日无课」；
/// 最近的一段假期和「临近课程」里的一节课一个排法（小标签、标题、一行说明），贴着底边。
/// 放假当天不写上面那行，「放假中 / 国庆快乐」已经说明了。没有假期可说时只居中说今天。
private struct RestStateView: View {
    @Environment(\.scheduleStyle) private var style
    @WidgetStyleColors private var widgetColors
    /// 今天排过课（已经上完）还是本来就没课。
    let hadCourses: Bool
    @Environment(\.scheduleWidgetDisplayOptions) private var options
    @Environment(\.scheduleWidgetNotice) private var notice
    @Environment(\.scheduleWidgetNow) private var now

    private var todayStatus: String { hadCourses ? "今日课程已结束" : "今日无课" }

    var body: some View {
        if let notice {
            ScheduleNoticeBlock(notice: notice)
        } else if let holiday = RestState.holiday(options: options, now: now) {
            VStack(alignment: .leading, spacing: 0) {
                if RestState.countdown(options: options, now: now)?.daysAway != 0 {
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
        .font(style.widgetFont(size: 11, weight: .semibold))
        .foregroundStyle(widgetColors.muted)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private func holidayBlock(_ holiday: (caption: String, title: String, detail: String)) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(holiday.caption)
                .font(style.widgetFont(size: 11, weight: .semibold))
                .foregroundStyle(widgetColors.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(holiday.title)
                    .font(style.widgetFont(size: 15, weight: .bold))
                    .foregroundStyle(widgetColors.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                Text(holiday.detail)
                    .font(style.widgetFont(size: 10, weight: .medium))
                    .foregroundStyle(widgetColors.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }
}

/// 放假和课表过期时的文字、图标。
private extension WidgetScheduleNotice {
    var symbol: String {
        switch self {
        case .vacation(let vacation):
            switch vacation.kind {
            case .winter: return "snowflake"
            case .summer: return "sun.max.fill"
            case .other: return "beach.umbrella.fill"
            }
        case .stale:
            return "arrow.triangle.2.circlepath"
        }
    }

    var tint: Color {
        switch self {
        case .vacation(let vacation):
            switch vacation.kind {
            case .winter: return .cyan
            case .summer: return .orange
            case .other: return .pink
            }
        case .stale:
            return WidgetPalette.secondary
        }
    }

    var title: String {
        switch self {
        case .vacation(let vacation): return vacation.title
        case .stale: return "课表需要更新"
        }
    }

    /// 标题下面那行小字：放假写节日祝福和「距开学还有 N 天」，都没有就不写；过期提示打开 App。
    func detail(now: Date) -> String? {
        switch self {
        case .vacation(let vacation):
            let parts = [ChineseCalendarInfo.restGreeting(for: now), vacation.countdown].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .stale:
            return "打开 App 更新课表"
        }
    }

    /// 锁屏单行。
    var inlineText: String {
        switch self {
        case .vacation(let vacation):
            guard let days = vacation.daysUntilTerm, days > 0 else { return vacation.title }
            return "\(vacation.title) · 距开学 \(days) 天"
        case .stale:
            return "打开 App 更新课表"
        }
    }

    /// 锁屏圆形里图标下面那两三个字。
    var circularText: String {
        switch self {
        case .vacation(let vacation):
            if let days = vacation.daysUntilTerm, days > 0 { return "\(days)天" }
            switch vacation.kind {
            case .winter: return "寒假"
            case .summer: return "暑假"
            case .other: return "放假"
            }
        case .stale:
            return "待更新"
        }
    }
}

/// 小号、中号的放假 / 过期状态：和假期倒计时一样贴着底边，图标、大字标题、一行说明。
private struct ScheduleNoticeBlock: View {
    @Environment(\.scheduleStyle) private var style
    @WidgetStyleColors private var widgetColors
    let notice: WidgetScheduleNotice
    @Environment(\.scheduleWidgetNow) private var now

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 6)
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: notice.symbol)
                    .font(style.widgetFont(size: 20, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(notice.tint)
                    .widgetAccentable()
                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.title)
                        .font(style.widgetFont(size: 17, weight: .bold))
                        .foregroundStyle(widgetColors.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let detail = notice.detail(now: now) {
                        Text(detail)
                            .font(style.widgetFont(size: 10, weight: .medium))
                            .foregroundStyle(widgetColors.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// 大号（今日课表、两日课表）的放假 / 过期状态：和放假祝福一样把图标、标题摆在中间。
private struct ScheduleNoticeGreetingView: View {
    @Environment(\.scheduleStyle) private var style
    @WidgetStyleColors private var widgetColors
    let notice: WidgetScheduleNotice
    @Environment(\.scheduleWidgetNow) private var now

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                Image(systemName: notice.symbol)
                    .font(style.widgetFont(size: 34, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(notice.tint)
                    .widgetAccentable()
                VStack(spacing: 4) {
                    Text(notice.title)
                        .font(style.widgetFont(size: 20, weight: .bold))
                        .foregroundStyle(widgetColors.primary)
                    if let detail = notice.detail(now: now) {
                        Text(detail)
                            .font(style.widgetFont(size: 11, weight: .medium))
                            .foregroundStyle(widgetColors.secondary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            // 和放假祝福一样整组稍微偏上。
            Spacer(minLength: 0).frame(maxHeight: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 图标和字挨近一点，默认的 Label 间距在小组件里显得散。
private struct StatusLabelStyle: LabelStyle {
    @Environment(\.scheduleStyle) private var style
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
                .font(style.widgetFont(size: 10, weight: .semibold))
            configuration.title
        }
    }
}

enum WidgetPalette {
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

    /// 示例课表的「今天」就是今天，不然会被当成过期的课表。
    static var placeholder: ScheduleEntry { placeholder(at: WidgetClock.now) }

    static func placeholder(at now: Date) -> ScheduleEntry {
        let today = WidgetDay.empty(date: WidgetSchedulePayload.dateString(now), offset: 0)
        return ScheduleEntry(
            date: now,
            state: .loaded(
                WidgetSchedulePayload(
                    title: AppBrand.name,
                    sourceLabel: nil,
                    generatedAt: nil,
                    semester: "2026-2027-1",
                    currentWeek: 1,
                    today: WidgetDay(
                        day: today.day,
                        label: today.label,
                        date: today.date,
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
}

enum ScheduleEntryState {
    case loaded(WidgetSchedulePayload)
    case unconfigured
    case failed(String)
}

/// 从 App Group 里读课表生成时间线；各个小组件的配置由 `ScheduleIntentTimelineProvider` 再套上。
///
/// 一次交出从现在到明天的整条时间线（见 `WidgetSchedulePayload.timelinePlan(from:)`），
/// 次日零点才回来要新的。以前一次只给一条、每个上下课边界（最迟半小时）回来刷一次，
/// 一个小组件一天六十来次，把系统给的刷新预算用光，之后的刷新被推迟，下课了还显示「正在上」。
/// 课表在 App 里改了由 App 调 `WidgetCenter` 立刻重刷，不靠这里的定时。
enum ScheduleTimeline {
    static func make(now: Date) -> Timeline<ScheduleEntry> {
        let payload = ScheduleWidgetStore.load()
        ChineseCalendarInfo.usePublishedHolidays(payload?.holidays ?? [])
        // 课表只解码这一次，每条条目拿的是同一份（数组是写时复制，不会真的拷贝）。
        let state: ScheduleEntryState = payload.map { .loaded($0) } ?? .unconfigured
        let plan = payload?.timelinePlan(from: now)
            ?? WidgetTimelinePlan(dates: [now], reload: WidgetSchedulePayload.startOfNextDay(after: now))
        let rounds = CelebrateHolidayIntent.rounds()
        var dates = plan.dates
        let fired = CelebrateHolidayIntent.justFired(now: now)
        if fired {
            // 刚按了彩炮：第一条放烟花，散完后再来一条把彩炮放回去、换掉看不见的碎片。
            // 这一条按自己的日期画，碰巧跨过了上下课边界也画得对。
            dates = Set(dates + [now.addingTimeInterval(FireworksTiming.total + 0.3)]).sorted()
        }
        let entries = dates.map { date in
            let celebrating = fired && date == now
            return ScheduleEntry(
                date: date,
                state: state,
                celebrating: celebrating,
                // 放烟花那一条沿用按之前的身份，之后的都换成新的，见 `ScheduleEntry.fireworksRound`。
                fireworksRound: celebrating ? rounds.previous : rounds.latest
            )
        }
        return Timeline(entries: entries, policy: .after(plan.reload))
    }
}

#if WIDGET_GALLERY
/// 预览画廊（`scripts/widget-gallery.sh`）的入口。小组件和实时活动的视图都是 private，
/// 画廊只能从这份文件里拿，拿到的和桌面、锁屏上跑的是同一份代码。
enum WidgetGalleryViews {
    enum Kind: String, CaseIterable {
        case upcoming, twoday
    }

    /// 实时活动里可以单独渲染的几块。灵动岛的外形由画廊自己画。
    enum ActivityPart: String {
        case lockScreen, watch, islandLeading, islandTrailing, islandBottom, compactLeading, compactTrailing, minimal
    }

    static func widget(kind: Kind, family: WidgetFamily, entry: ScheduleEntry) -> AnyView {
        switch kind {
        case .upcoming:
            return AnyView(ScheduleWidgetRoot(entry: entry, familyOverride: family) { UpcomingOrTodayScheduleView(payload: $0) })
        case .twoday:
            return AnyView(ScheduleWidgetRoot(entry: entry, familyOverride: family) { TwoDayScheduleView(payload: $0) })
        }
    }

    static func widgetBackground(for colorScheme: ColorScheme) -> Color {
        ScheduleStyle.load(from: UserDefaults(suiteName: NextWidgetConfiguration.appGroup)).canvasColor(dark: colorScheme == .dark) ?? WidgetPalette.background(for: colorScheme)
    }

    static func liveActivity(
        _ part: ActivityPart,
        state: ScheduleLiveActivityAttributes.ContentState,
        attributes: ScheduleLiveActivityAttributes,
        isStale: Bool
    ) -> AnyView {
        let style = ScheduleStyle.load(from: UserDefaults(suiteName: NextWidgetConfiguration.appGroup))
        let display = ScheduleLiveActivityDisplay(state: state, isStale: isStale, attributes: attributes)
        switch part {
        case .lockScreen:
            return AnyView(ScheduleLiveActivityLockScreenContent(display: display).environment(\.activityFamily, .medium).scheduleWidgetStyle(style).environment(\.liveActivityPalette, LiveActivityContentPalette(style: style)))
        case .watch:
            return AnyView(ScheduleLiveActivityLockScreenContent(display: display).environment(\.activityFamily, .small).scheduleWidgetStyle(style).environment(\.liveActivityPalette, LiveActivityContentPalette(style: style)))
        case .islandLeading:
            return AnyView(ScheduleLiveActivityIslandLeading(display: display).scheduleWidgetStyle(style).environment(\.liveActivityPalette, LiveActivityContentPalette(style: style)))
        case .islandTrailing:
            return AnyView(ScheduleLiveActivityIslandTrailing(display: display).scheduleWidgetStyle(style).environment(\.liveActivityPalette, LiveActivityContentPalette(style: style)))
        case .islandBottom:
            return AnyView(ScheduleLiveActivityIslandBottom(display: display).scheduleWidgetStyle(style).environment(\.liveActivityPalette, LiveActivityContentPalette(style: style)))
        case .compactLeading, .minimal:
            return AnyView(ScheduleLiveActivityLogo(size: 21).scheduleWidgetStyle(style).environment(\.liveActivityPalette, LiveActivityContentPalette(style: style)))
        case .compactTrailing:
            return AnyView(ScheduleLiveActivityIslandCompactTrailing(display: display).scheduleWidgetStyle(style).environment(\.liveActivityPalette, LiveActivityContentPalette(style: style)))
        }
    }

    /// 手表智能叠放和收尾卡片用的深色底（`activityBackgroundTint`）。
    static var activitySurface: Color { ScheduleStyle.load(from: UserDefaults(suiteName: NextWidgetConfiguration.appGroup)).canvasColor(dark: true) ?? ScheduleLiveActivityPalette.surface }
}
#endif

#if DEBUG && !WIDGET_GALLERY && false
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
        let pinned = ChineseCalendarInfo.gregorian.date(from: components)!
        WidgetClock.override = pinned
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
            date: pinned,
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

#Preview("今日课程 · 放礼花", as: .systemLarge) {
    UpcomingScheduleWidget()
} timeline: {
    FireworksPreview.entry(celebrating: false, round: 0, afterClass: .todayOnly)
    FireworksPreview.entry(celebrating: true, round: 0, afterClass: .todayOnly)
    FireworksPreview.entry(celebrating: false, round: 1, afterClass: .todayOnly)
}
#endif
