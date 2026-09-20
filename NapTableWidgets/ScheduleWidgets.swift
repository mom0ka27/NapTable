import SwiftUI
import WidgetKit

/// The widget bundle: the three schedule widgets plus the Live Activity.
/// Ported from `../CPU-Web/ios_next` (CpuTime) `CPUWebWidgets/ScheduleWidgets.swift`.
/// CpuTime's timeline fetched a Web endpoint; this one reads the payload the app
/// writes into the shared App Group, so it works with no network at all.
#if os(iOS)
@main
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
            // Past the content's stale date this course is over. The system
            // re-renders at that moment, which is the only callback available
            // to the extension: switch to the next class of the day, or to a
            // closing card until the app dismisses the activity.
            let display = ScheduleLiveActivityDisplay(state: context.state, isStale: context.isStale)
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
        } dynamicIsland: { context in
            DynamicIsland {
                // The camera owns the centre of the expanded island. Put the
                // title in the full-width bottom region rather than squeezing
                // it between the logo, camera and a growing timer.
                DynamicIslandExpandedRegion(.leading, priority: 1) {
                    HStack(spacing: 5) {
                        ScheduleLiveActivityLogo(size: 24)
                        Text(ScheduleLiveActivityDisplay(state: context.state, isStale: context.isStale).islandTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(ScheduleLiveActivityPalette.accent)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    // 放不下就整块挪到下面那一行，而不是被摄像头和圆角切掉。
                    .dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.trailing, priority: 1) {
                    if let state = ScheduleLiveActivityDisplay(state: context.state, isStale: context.isStale).state {
                        ScheduleLiveActivityCountdown(state: state, compact: true, centered: true)
                            .frame(maxWidth: .infinity, minHeight: 40, alignment: .trailing)
                            .dynamicIsland(verticalPlacement: .belowIfTooWide)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    let display = ScheduleLiveActivityDisplay(state: context.state, isStale: context.isStale)
                    Group {
                        if let state = display.state {
                            ScheduleLiveActivityExpandedDetails(state: state)
                        } else {
                            ScheduleLiveActivityFinishedRow(title: display.closingTitle)
                        }
                    }
                    .padding(.top, 5)
                }
            } compactLeading: {
                ScheduleLiveActivityLogo(size: 21)
                    .accessibilityLabel("药大拾间课表")
            } compactTrailing: {
                Group {
                    if let state = ScheduleLiveActivityDisplay(state: context.state, isStale: context.isStale).state {
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
            } minimal: {
                ScheduleLiveActivityLogo(size: 21)
                    .accessibilityLabel("药大拾间课表")
            }
            // 左右和底部交给系统：`contentMargins(_:_:for: .expanded)` 是覆盖而不是
            // 叠加，之前把三边一起写死（18/8/10）比系统默认值窄，左上角的图标和右上角
            // 的「距上课」才会被胶囊圆角切掉。顶部沿用最早的 8pt：系统默认的上边距把
            // 内容压得太靠下，而上边并不是被圆角切到的那一侧。
            .contentMargins(.top, 8, for: .expanded)
            .widgetURL(context.attributes.deepLinkURL)
            .keylineTint(ScheduleLiveActivityPalette.brand)
        }
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

    init(state: ScheduleLiveActivityAttributes.ContentState, isStale: Bool) {
        let localState = state.resolvedFromLocalSchedule() ?? state
        // Only a persistent activity carries on to the next class; otherwise
        // it is on its way out and should simply say the class is over.
        self.state = isStale && NextWidgetConfiguration.liveActivityIsPersistent
            ? localState.afterEndState
            : (isStale ? nil : localState)
        self.hasMoreToday = localState.afterEndState != nil
    }

    var islandTitle: String { state?.phaseTitle ?? closingTitle }

    /// 今天还有课但这一节已经结束（非常驻马上就收起）时说「已下课」；今天没课了
    /// 就说「今日无课」，而不是预告明天的课。
    var closingTitle: String { hasMoreToday ? "已下课" : "今日无课" }
}

private extension ScheduleLiveActivityAttributes.ContentState {
    /// Broadcast pushes deliberately contain no course content. Resolve the
    /// boundary against the timetable written by the app into the App Group.
    func resolvedFromLocalSchedule() -> Self? {
        guard let dateKey = broadcastDateKey,
              let timestamp = broadcastTimestamp,
              let payload = ScheduleWidgetStore.load(),
              let day = payload.knownDay(for: dateKey) else { return nil }

        let datedCourses = day.courseList.compactMap { course -> (WidgetCourse, Date, Date)? in
            guard let start = Self.date(dateKey, time: course.startTime),
                  let end = Self.date(dateKey, time: course.endTime), end > start else { return nil }
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
        content
            .environment(\.liveActivityPalette, palette)
            .activityBackgroundTint(nil)
            .activitySystemActionForegroundColor(.primary)
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

            if let note = state.normalizedAdjustmentNote {
                ScheduleLiveActivityAdjustmentChip(note: note)
            }
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
        .background {
            LinearGradient(
                colors: [ScheduleLiveActivityPalette.brand.opacity(colorScheme == .dark ? 0.12 : 0.06), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
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
            if let note = state.normalizedAdjustmentNote {
                ScheduleLiveActivityAdjustmentChip(note: note)
            }
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
            content(showsTimeRange: true)
            content(showsTimeRange: false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .activityBackgroundTint(ScheduleLiveActivityPalette.surface)
        .activitySystemActionForegroundColor(.white)
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
            Text([state.location.isEmpty ? state.teacher : state.location, state.periodLabel ?? ""]
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
            ProgressView(timerInterval: state.startDate...state.endDate, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                // The default timer progress label draws another clock below
                // the track even when its frame is only a few points tall.
                EmptyView()
            }
            .progressViewStyle(.linear)
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
        Text(
            timerInterval: min(state.updatedAt, end)...end,
            countsDown: true,
            showsHours: state.countdownShowsHours
        )
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .multilineTextAlignment(alignment)
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
        StaticConfiguration(kind: kind, provider: ScheduleTimelineProvider()) { entry in
            ScheduleWidgetRoot(entry: entry) { payload in
                UpcomingScheduleView(payload: payload)
            }
        }
        .configurationDisplayName("临近课程")
        .description("在桌面或锁屏显示当前课程和接下来一节课。")
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
        StaticConfiguration(kind: kind, provider: ScheduleTimelineProvider()) { entry in
            ScheduleWidgetRoot(entry: entry) { payload in
                TodayScheduleView(payload: payload)
            }
        }
        .configurationDisplayName("今日课表")
        .description("查看今天的完整课程安排。")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

private struct TwoDayScheduleWidget: Widget {
    let kind = "me.mom0ka27.naptable.widget.twoday"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ScheduleTimelineProvider()) { entry in
            ScheduleWidgetRoot(entry: entry) { payload in
                TwoDayScheduleView(payload: payload)
            }
        }
        .configurationDisplayName("两日课表")
        .description("并排显示今天和明天的课程。")
        .supportedFamilies([.systemLarge])
    }
}

private struct ScheduleWidgetThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = ScheduleWidgetTheme.colorGlass
}

private struct ScheduleWidgetDisplayOptionsEnvironmentKey: EnvironmentKey {
    static let defaultValue = ScheduleWidgetDisplayOptions.default
}

private extension EnvironmentValues {
    var scheduleWidgetTheme: ScheduleWidgetTheme {
        get { self[ScheduleWidgetThemeEnvironmentKey.self] }
        set { self[ScheduleWidgetThemeEnvironmentKey.self] = newValue }
    }

    var scheduleWidgetDisplayOptions: ScheduleWidgetDisplayOptions {
        get { self[ScheduleWidgetDisplayOptionsEnvironmentKey.self] }
        set { self[ScheduleWidgetDisplayOptionsEnvironmentKey.self] = newValue }
    }
}

private struct ScheduleWidgetRoot<Content: View>: View {
    let entry: ScheduleEntry
    @ViewBuilder let content: (WidgetSchedulePayload) -> Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let theme = NextWidgetConfiguration.scheduleTheme
        let displayOptions = NextWidgetConfiguration.displayOptions
        Group {
            switch entry.state {
            case .loaded(let payload):
                content(payload)
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
        .environment(\.scheduleWidgetDisplayOptions, displayOptions)
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
    @Environment(\.widgetFamily) private var family

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
    @Environment(\.widgetFamily) private var family
    @Environment(\.scheduleWidgetDisplayOptions) private var options

    @ViewBuilder
    var body: some View {
        let selection = payload.upcoming()
        if family.isAccessory {
            LockScreenScheduleView(payload: payload, day: selection.0, courses: selection.1)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                WidgetDateHeader(
                    day: selection.0,
                    hidesCountdown: selection.1.isEmpty
                        && AfterClassView.showsHolidayCard(payload: payload, options: options)
                )
                Spacer(minLength: 8)

                if selection.1.isEmpty {
                    AfterClassView(payload: payload, limit: family == .systemMedium ? 2 : 1)
                } else if family == .systemMedium {
                    HStack(alignment: .top, spacing: 14) {
                        UpcomingColumn(label: "当前", course: selection.1.first)
                        Divider()
                        UpcomingColumn(label: "接下来", course: selection.1.count > 1 ? selection.1[1] : nil)
                    }
                } else if let course = selection.1.first {
                    CourseSummary(course: course, roomy: true)
                    if selection.1.count > 1 {
                        Spacer(minLength: 7)
                        Text("接下来")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(WidgetPalette.muted)
                        CompactNextCourse(course: selection.1[1])
                    }
                }
            }
        }
    }
}

private struct LockScreenScheduleView: View {
    let payload: WidgetSchedulePayload
    let day: WidgetDay
    let courses: [WidgetCourse]
    @Environment(\.widgetFamily) private var family
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

    /// 单行锁屏只有一句话的位置：放假先道贺，平时让位给明天 / 假期这类更有用的信息。
    /// 这一行已经能写出明天的课时，周末问候就让位给课——两句话挤不进一行。
    private var inlineEmptyText: String {
        let hadCourses = !day.courseList.isEmpty
        let showsCourses = tomorrowCourseText != nil
        if let greeting = TodayRestMessage.greeting(hadCourses: hadCourses, showsCourses: showsCourses) {
            return greeting
        }
        return afterClassText ?? TodayRestMessage.text(hadCourses: hadCourses)
    }

    /// 今天没课之后，锁屏这一行改成明天第一节课或最近的假期。
    private var afterClassText: String? {
        switch options.afterClass {
        case .none:
            return nil
        case .tomorrow:
            return tomorrowCourseText ?? AfterClassView.holidayLine()
        case .holiday:
            return AfterClassView.holidayLine()
        }
    }

    /// 「明天 08:00 高数」；设置不是「明天的课程」或明天空着时为 `nil`。
    private var tomorrowCourseText: String? {
        guard options.afterClass == .tomorrow,
              let tomorrow = payload.tomorrow(),
              let course = tomorrow.courseList.first else { return nil }
        return ["明天", options.showTime ? course.startLabel : nil, course.displayName]
            .compactMap { $0 }
            .joined(separator: " ")
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
                Text([day.compactDate, day.displayLabel].filter { !$0.isEmpty }.joined(separator: " "))
                    .font(.system(size: 10, weight: .semibold))
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

    /// 今天没有在上的课时，这块写什么：放假道贺 > 明天的课 > 「今天没有课～」。
    /// 明天的课一旦顶上来，就不再另起一行说今天，两行都留给真正有用的信息。
    private var emptyLines: (primary: String, secondary: String?) {
        let hadCourses = !day.courseList.isEmpty
        let tomorrow = tomorrowCourseText
        if let greeting = TodayRestMessage.greeting(hadCourses: hadCourses, showsCourses: tomorrow != nil) {
            return (greeting, afterClassText ?? "打开课表查看本周安排")
        }
        if let tomorrow { return (tomorrow, AfterClassView.holidayLine()) }
        return (TodayRestMessage.text(hadCourses: hadCourses), afterClassText ?? "打开课表查看本周安排")
    }

    private func inlineText(_ course: WidgetCourse) -> String {
        [
            day.shortLabel,
            options.showTime ? course.startLabel : nil,
            options.primaryValue(for: course),
            options.metadata(for: course)
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }
}

private struct UpcomingColumn: View {
    let label: String
    let course: WidgetCourse?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WidgetPalette.secondary)
            if let course {
                CourseSummary(course: course, roomy: false)
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
    let course: WidgetCourse
    let roomy: Bool
    @Environment(\.scheduleWidgetTheme) private var theme
    @Environment(\.scheduleWidgetDisplayOptions) private var options

    var body: some View {
        HStack(alignment: .top, spacing: roomy ? 9 : 7) {
            RoundedRectangle(cornerRadius: 3)
                .fill(WidgetPalette.accent(for: course, theme: theme))
                .frame(width: 5, height: roomy ? 58 : 62)
            VStack(alignment: .leading, spacing: roomy ? 3 : 2) {
                if let primary = options.primaryValue(for: course) {
                    Text(primary)
                        .font(.system(size: roomy ? 15 : 13, weight: .bold))
                        .foregroundStyle(WidgetPalette.primary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.76)
                }
                if let metadata = options.metadata(for: course) {
                    Text(metadata)
                        .font(.system(size: roomy ? 10 : 9))
                        .foregroundStyle(WidgetPalette.secondary)
                        .lineLimit(1)
                }
                if options.showTime {
                    Text(course.timeRange)
                        .font(.system(size: roomy ? 11 : 10, weight: .semibold))
                        .foregroundStyle(WidgetPalette.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
    }
}

private struct CompactNextCourse: View {
    let course: WidgetCourse
    @Environment(\.scheduleWidgetTheme) private var theme
    @Environment(\.scheduleWidgetDisplayOptions) private var options

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(WidgetPalette.accent(for: course, theme: theme))
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
    @Environment(\.widgetFamily) private var family
    @Environment(\.scheduleWidgetDisplayOptions) private var options

    var body: some View {
        let now = Date.now
        let todayDate = WidgetSchedulePayload.dateString(now)
        let today = payload.currentDay(now: now)
        let limit = family == .systemLarge ? 7 : 2
        let nowMinutes = today.date == todayDate
            ? WidgetSchedulePayload.minutesSinceMidnight(now)
            : nil
        let window = today.courseWindow(limit: limit, nowMinutes: nowMinutes)
        // 今天已经没有未结束的课程时，这块位置交给「明天 / 最近节假日」。
        let finished = nowMinutes.map { minutes in
            today.courseList.allSatisfy { $0.hasEnded(at: minutes) }
        } ?? false
        let showsAfterClass = today.courseList.isEmpty || (finished && options.showsAfterClassPreview)
        VStack(alignment: .leading, spacing: family == .systemLarge ? 8 : 7) {
            WidgetDateHeader(
                day: today,
                showsCountdown: true,
                hidesCountdown: showsAfterClass && AfterClassView.showsHolidayCard(payload: payload, options: options)
            )
            if showsAfterClass {
                AfterClassView(payload: payload, limit: family == .systemLarge ? 5 : 2)
            } else {
                ForEach(Array(window.courses.enumerated()), id: \.offset) { _, course in
                    TodayCourseRow(
                        course: course,
                        large: family == .systemLarge,
                        timeOnSeparateLine: false,
                        completed: nowMinutes.map { course.hasEnded(at: $0) } ?? false
                    )
                }
                if window.remainingCount > 0 {
                    Text("还有 \(window.remainingCount) 门课程")
                        .font(.system(size: 9))
                        .foregroundStyle(WidgetPalette.muted)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }
}

private struct TodayCourseRow: View {
    let course: WidgetCourse
    let large: Bool
    let timeOnSeparateLine: Bool
    let completed: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scheduleWidgetTheme) private var theme
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.scheduleWidgetDisplayOptions) private var options

    var body: some View {
        HStack(spacing: large ? 9 : 6) {
            RoundedRectangle(cornerRadius: 3)
                .fill(WidgetPalette.accent(for: course, theme: theme))
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
        .padding(.vertical, large ? 6 : 4)
        .background {
            RoundedRectangle(cornerRadius: large ? 11 : 8)
                .fill(
                    renderingMode == .fullColor
                        ? WidgetPalette.tint(for: course, colorScheme: colorScheme, theme: theme)
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

private struct TwoDayScheduleView: View {
    let payload: WidgetSchedulePayload

    var body: some View {
        let now = Date.now
        let todayDate = WidgetSchedulePayload.dateString(now)
        let today = payload.currentDay(now: now)
        let tomorrowDate = WidgetSchedulePayload.dateString(
            Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now
        )
        let tomorrow = payload.fullDay(for: tomorrowDate, fallbackOffset: 1)

        HStack(alignment: .top, spacing: 13) {
            DayColumn(
                day: today,
                nowMinutes: today.date == todayDate ? WidgetSchedulePayload.minutesSinceMidnight(now) : nil,
                isToday: today.date == todayDate,
                siblingHasCourses: !tomorrow.courseList.isEmpty
            )
            Divider()
            DayColumn(day: tomorrow, nowMinutes: nil)
        }
    }
}

private struct DayColumn: View {
    let day: WidgetDay
    let nowMinutes: Int?
    /// 明天那一列没课就照常说「没有课程」，祝福只属于今天。
    var isToday = false
    /// 另一列排着课：这半边即使今天空着也不道「周末快乐～」。
    var siblingHasCourses = false

    var body: some View {
        let window = day.courseWindow(limit: 5, nowMinutes: nowMinutes)
        VStack(alignment: .leading, spacing: 7) {
            WidgetDateHeader(day: day, compact: true)
            if day.courseList.isEmpty {
                // 这一支本来就是「这天没有课」，所以今天那列固定说「今天没有课～」。
                EmptyCoursesView(
                    message: isToday
                        ? TodayRestMessage.text(hadCourses: false, showsCourses: siblingHasCourses)
                        : "没有课程"
                )
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WidgetDateHeader: View {
    let day: WidgetDay
    /// 两日课表的列只有半个组件宽：右侧的节日徽标和下面那行假期提示在那里放不下。
    var compact = false
    /// 不开「常驻」时，只有今日课表的日期栏会在临近假期时带上倒计时。
    var showsCountdown = false
    /// 下面的课后区域已经在大字显示同一段假期时，日期栏这行就别重复了。
    var hidesCountdown = false
    @Environment(\.scheduleWidgetTheme) private var theme
    @Environment(\.scheduleWidgetDisplayOptions) private var options
    @Environment(\.widgetFamily) private var family

    var body: some View {
        // 「周五」「初八」各自竖排成一列，日期、星期、农历之间各一条竖线；最近的
        // 假期不挤在同一行里，单独放到下面一行。
        let isCompact = compact || family == .systemSmall
        // 两行之间几乎不留空：竖线本身比字高，行距再拉开就散了。
        VStack(alignment: .leading, spacing: 0) {
            header(isCompact: isCompact)
            // 调休比「距中秋还有几天」重要，两行挤不下时让调休占这一行。
            if let note = day.normalizedNote {
                AdjustmentNoteChip(note: note)
                    .padding(.top, -2)
            } else if !compact, let countdown = holidayCountdown {
                HolidayCountdownChip(countdown: countdown)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    // 竖线比字高，靠负边距把这行收回去，贴着上一行的文字底部。
                    .padding(.top, -2)
            }
        }
    }

    private func header(isCompact: Bool) -> some View {
        let weekday = day.displayLabel.isEmpty ? nil : day.displayLabel
        return HStack(spacing: 6) {
            Text(day.compactDate)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(WidgetPalette.primary)

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

            if let week = day.week, week > 0 {
                Text("第 \(week) 周")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(WidgetPalette.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
    }

    private var columnDivider: some View {
        Rectangle()
            .fill(WidgetPalette.muted.opacity(0.45))
            .frame(width: 1, height: 24)
    }

    /// 一个字一行的竖排。两个字排完正好和左边的日期一样高；三个字的节日名
    /// （中秋节、国庆节）收一号字，免得把日期栏撑高。
    private func verticalText(_ value: String, weight: Font.Weight, color: Color) -> some View {
        let characters = Array(value)
        let size: CGFloat = characters.count > 2 ? 8 : 10
        return VStack(spacing: characters.count > 2 ? -1 : 0) {
            ForEach(Array(characters.enumerated()), id: \.offset) { _, character in
                Text(String(character))
                    .font(.system(size: size, weight: weight))
                    .foregroundStyle(color)
            }
        }
        .fixedSize()
    }

    private var calendarDay: ChineseCalendarDay? {
        guard let date = day.date else { return nil }
        return ChineseCalendarInfo.info(forDate: date)
    }

    private var badgeText: String? {
        guard options.showHoliday else { return nil }
        return calendarDay?.badge
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

    /// 今天不是节日时提示最近的一段法定假期。开了「常驻」就一直显示（看未来 120 天），
    /// 否则只有今日课表的日期栏会带上它，并且只看未来一个月。
    private var holidayCountdown: ChineseHolidayCountdown? {
        let resident = options.showsResidentHoliday
        guard !hidesCountdown, resident || showsCountdown else { return nil }
        guard let date = day.date, let reference = ChineseCalendarInfo.date(fromDate: date),
              let next = ChineseCalendarInfo.countdown(from: reference, withinDays: resident ? 120 : 30),
              next.daysAway > 0 else { return nil }
        return next
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

/// 日期栏下面那行假期提示。用一条竖的主题色细条起头，和课程行的色条呼应，
/// 比再放一个胶囊徽标安静。
private struct HolidayCountdownChip: View {
    let countdown: ChineseHolidayCountdown
    @Environment(\.scheduleWidgetTheme) private var theme
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        // 只报还剩几天，右边缘和上一行的「第 N 周」对齐：多一个色块或日期，
        // 两行的右端就对不上了。
        countdownText(tint: renderingMode == .fullColor ? WidgetPalette.accent(for: theme) : WidgetPalette.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private func countdownText(tint: Color) -> Text {
        let leading = Text(countdown.leading)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(WidgetPalette.secondary)
        guard let amount = countdown.amount else { return leading }
        return leading
            + Text(" ")
            + Text(amount)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(tint)
            + Text(" " + countdown.trailing)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(WidgetPalette.secondary)
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

/// 今天没课时说的那一句。三种情况分开说，都压在八个字以内，小组件里排得下一行：
/// 放假道贺 →「中秋快乐～」；今天排了课并且上完了 →「今天的课上完啦～」；
/// 今天本来就没排课 →「今天没有课～」。
///
/// 「距国庆节 12 天」这类假期提示不在这里，由 `AfterClassView.holidayFootnote`
/// 作为下面一行小字保留。
private enum TodayRestMessage {
    /// `showsCourses` 是这块界面上还列着课（两日课表的另一列、课后的明天预览）。
    /// 旁边摆着一排课还说「周末快乐～」就成了反话，此时只报事实；法定假日照旧道贺。
    static func text(hadCourses: Bool, showsCourses: Bool = false, now: Date = .now) -> String {
        if let greeting = greeting(hadCourses: hadCourses, showsCourses: showsCourses, now: now) { return greeting }
        return hadCourses ? "今天的课上完啦～" : "今天没有课～"
    }

    static func greeting(hadCourses: Bool, showsCourses: Bool = false, now: Date = .now) -> String? {
        ChineseCalendarInfo.restGreeting(for: now, hasCourses: hadCourses || showsCourses)
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

/// 今天的课上完之后显示什么：明天的课程（灰显）或最近的一段法定假期。
/// 设置见「小组件」页的「今天课程结束后」。
private struct AfterClassView: View {
    let payload: WidgetSchedulePayload
    let limit: Int
    @Environment(\.scheduleWidgetDisplayOptions) private var options
    @Environment(\.widgetFamily) private var family

    @ViewBuilder
    var body: some View {
        switch options.afterClass {
        case .none:
            EmptyCoursesView(message: todayMessage)
        case .tomorrow:
            if let tomorrow = payload.tomorrow(), !tomorrow.courseList.isEmpty {
                tomorrowPreview(tomorrow)
            } else {
                // 明天也没课：能给出假期就给假期，否则老老实实说没课。
                holidayCard(message: todayMessage)
            }
        case .holiday:
            holidayCard(message: todayMessage)
        }
    }

    /// 今天排了课才说「上完啦」，本来就空着的一天说「没有课」。
    private var todayMessage: String {
        TodayRestMessage.text(hadCourses: !payload.currentDay().courseList.isEmpty)
    }

    private func tomorrowPreview(_ day: WidgetDay) -> some View {
        let visible = Array(day.courseList.prefix(max(1, limit)))
        // 明天的课已经把这块占满了，就不再留一行说「今天没有课～」；
        // 法定假日那句「中秋快乐～」还是值得一行。
        let greeting = TodayRestMessage.greeting(
            hadCourses: !payload.currentDay().courseList.isEmpty,
            showsCourses: true
        )
        return VStack(alignment: .leading, spacing: 5) {
            if let greeting {
                Text(greeting)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(WidgetPalette.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            HStack(spacing: 5) {
                Text("明天")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(WidgetPalette.secondary)
                Text([day.compactDate, day.displayLabel].filter { !$0.isEmpty }.joined(separator: " "))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(WidgetPalette.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            ForEach(Array(visible.enumerated()), id: \.offset) { _, course in
                // completed 的灰度处理就是这里要的「标灰」：明天的课不该抢今天的注意力。
                TodayCourseRow(
                    course: course,
                    large: false,
                    timeOnSeparateLine: false,
                    completed: true
                )
            }
            if day.courseList.count > visible.count {
                Text("明天还有 \(day.courseList.count - visible.count) 门课程")
                    .font(.system(size: 9))
                    .foregroundStyle(WidgetPalette.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 今天没课时的主视图：先说今天的状态，最近的假期作为下面一行小字保留。
    private func holidayCard(message: String) -> some View {
        let countdown = Self.countdown()
        return VStack(spacing: 3) {
            if countdown != nil {
                Image(systemName: "party.popper")
                    .font(.system(size: family == .systemSmall ? 13 : 15, weight: .semibold))
                    .foregroundStyle(WidgetPalette.muted)
            }
            Text(message)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(WidgetPalette.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
            if let footnote = countdown.flatMap(Self.holidayFootnote) {
                Text(footnote)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(WidgetPalette.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    /// 假期小字：还没放假就倒数，已经在假期里就改说这一段连休几天（再说一遍
    /// 「今天是中秋节」跟上面那句祝福重复了）。
    static func holidayFootnote(_ countdown: ChineseHolidayCountdown) -> String? {
        guard countdown.daysAway > 0 else {
            return countdown.window.dayCount > 1 ? "假期 \(countdown.dateLabel)" : nil
        }
        return "\(countdown.phrase) · \(countdown.dateLabel)"
    }

    /// 「距国庆节 12 天」「明天就是中秋节」；锁屏那一行也用它。
    static func holidayLine(now: Date = .now) -> String? {
        countdown(now: now)?.phrase
    }

    static func countdown(now: Date = .now) -> ChineseHolidayCountdown? {
        ChineseCalendarInfo.countdown(from: now, withinDays: 120)
    }

    /// 课后区域会不会显示假期大字报。日期栏靠它决定要不要让出那一行。
    static func showsHolidayCard(
        payload: WidgetSchedulePayload,
        options: ScheduleWidgetDisplayOptions,
        now: Date = .now
    ) -> Bool {
        guard countdown(now: now) != nil else { return false }
        switch options.afterClass {
        case .none: return false
        case .holiday: return true
        case .tomorrow: return payload.tomorrow(now: now)?.courseList.isEmpty ?? true
        }
    }
}

private enum WidgetPalette {
    static let primary = Color.primary
    static let secondary = Color.secondary
    static let muted = Color.secondary.opacity(0.72)
    private static let colorGlassAccents: [Color] = [
        Color(red: 232 / 255, green: 91 / 255, blue: 75 / 255),
        Color(red: 74 / 255, green: 120 / 255, blue: 242 / 255),
        Color(red: 139 / 255, green: 92 / 255, blue: 246 / 255),
        Color(red: 23 / 255, green: 166 / 255, blue: 154 / 255),
        Color(red: 224 / 255, green: 162 / 255, blue: 36 / 255),
        Color(red: 236 / 255, green: 112 / 255, blue: 161 / 255),
    ]
    private static let colorGlassTints: [Color] = [
        Color(red: 253 / 255, green: 236 / 255, blue: 233 / 255),
        Color(red: 234 / 255, green: 240 / 255, blue: 1),
        Color(red: 242 / 255, green: 236 / 255, blue: 1),
        Color(red: 229 / 255, green: 248 / 255, blue: 245 / 255),
        Color(red: 1, green: 247 / 255, blue: 224 / 255),
        Color(red: 253 / 255, green: 235 / 255, blue: 244 / 255),
    ]

    static func accent(for theme: ScheduleWidgetTheme) -> Color {
        switch theme {
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

    static func accent(for course: WidgetCourse, theme: ScheduleWidgetTheme) -> Color {
        theme == .colorGlass ? colorGlassAccents[index(for: course)] : accent(for: theme)
    }

    static func background(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 14 / 255, green: 20 / 255, blue: 32 / 255)
            : Color(red: 248 / 255, green: 251 / 255, blue: 1)
    }

    static func tint(
        for course: WidgetCourse,
        colorScheme: ColorScheme,
        theme: ScheduleWidgetTheme
    ) -> Color {
        let index = index(for: course)
        let courseAccent = accent(for: course, theme: theme)
        if colorScheme == .dark {
            return courseAccent.opacity(0.18)
        }
        guard theme != .colorGlass else {
            return colorGlassTints[index]
        }
        switch theme {
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
            return colorGlassTints[index]
        }
    }

    private static func index(for course: WidgetCourse) -> Int {
        let hash = course.displayName.unicodeScalars.reduce(0) { partial, scalar in
            (partial &* 31 &+ Int(scalar.value)) & 0x7fff_ffff
        }
        return hash % colorGlassAccents.count
    }
}

struct ScheduleEntry: TimelineEntry {
    let date: Date
    let state: ScheduleEntryState

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

struct ScheduleTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> ScheduleEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (ScheduleEntry) -> Void) {
        completion(.placeholder)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ScheduleEntry>) -> Void) {
        let now = Date.now
        let entry: ScheduleEntry
        let payload = ScheduleWidgetStore.load()
        if let payload {
            entry = ScheduleEntry(date: now, state: .loaded(payload))
        } else {
            entry = ScheduleEntry(date: now, state: .unconfigured)
        }
        let periodic = Calendar.current.date(byAdding: .minute, value: 30, to: now) ?? now.addingTimeInterval(1800)
        // 下课那一刻就该换内容（划掉已结束的课、放学后切到明天），别等下一个半小时。
        let refresh = payload.flatMap { Self.nextBoundary(in: $0, now: now) }.map { min($0, periodic) } ?? periodic
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }

    /// 今天剩下的课程边界里最近的一个（开始或结束），没有就返回 nil。
    private static func nextBoundary(in payload: WidgetSchedulePayload, now: Date) -> Date? {
        let today = payload.currentDay(now: now)
        let nowMinutes = WidgetSchedulePayload.minutesSinceMidnight(now)
        let startOfDay = ChineseCalendarInfo.gregorian.startOfDay(for: now)
        let minutes = today.courseList
            .flatMap { [Self.minutes($0.startTime), $0.endMinutes > 0 ? $0.endMinutes : nil] }
            .compactMap { $0 }
            .filter { $0 > nowMinutes }
            .min()
        guard let minutes else { return nil }
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
