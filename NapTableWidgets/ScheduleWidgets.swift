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
            let display = ScheduleLiveActivityDisplay(state: context.state, isStale: context.isStale, attributes: context.attributes)
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
                        Text(ScheduleLiveActivityDisplay(state: context.state, isStale: context.isStale, attributes: context.attributes).islandTitle)
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
                DynamicIslandExpandedRegion(.trailing, priority: 1) {
                    // Merged rows carry one timer each; a third one up here
                    // would only repeat the share's.
                    if let state = ScheduleLiveActivityDisplay(state: context.state, isStale: context.isStale, attributes: context.attributes).state,
                       state.companion == nil {
                        ScheduleLiveActivityCountdown(state: state, compact: true, centered: true)
                            .frame(maxWidth: .infinity, minHeight: 24, alignment: .topTrailing)
                            .padding(.top, -8)
                            .dynamicIsland(verticalPlacement: .belowIfTooWide)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    let display = ScheduleLiveActivityDisplay(state: context.state, isStale: context.isStale, attributes: context.attributes)
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
            } compactLeading: {
                ScheduleLiveActivityLogo(size: 21)
                    .accessibilityLabel("药大拾间课表")
            } compactTrailing: {
                Group {
                    if let state = ScheduleLiveActivityDisplay(state: context.state, isStale: context.isStale, attributes: context.attributes).state {
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
            // 的「距上课」才会被胶囊圆角切掉。顶部归零：上边不是被圆角切到的那一侧，
            // 系统默认的上边距只会把内容白白往下压。
            .contentMargins(.top, 0, for: .expanded)
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

    init(state: ScheduleLiveActivityAttributes.ContentState, isStale: Bool, attributes: ScheduleLiveActivityAttributes) {
        if attributes.protocolVersion == 2 {
            self.state = LiveActivityDisplaySnapshot.resolveStored(attributes: attributes, at: Date())
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
        let isStale = isStale || localState.endDate <= Date()
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
        let timestamp = max(broadcastTimestamp, Date())
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
                    Text(timerInterval: entry.timer, countsDown: true, showsHours: entry.showsHours)
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
                    ProgressView(timerInterval: progress, countsDown: false) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                    .progressViewStyle(.linear)
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
        .description("查看今天的完整课程安排。")
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
        .description("并排显示今天和明天的课程。")
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
}

private struct ScheduleWidgetRoot<Content: View>: View {
    let entry: ScheduleEntry
    @ViewBuilder let content: (WidgetSchedulePayload) -> Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let theme = NextWidgetConfiguration.scheduleTheme
        var displayOptions = NextWidgetConfiguration.displayOptions
        // 「今天的课上完后」已经挪进每个小组件自己的「编辑小组件」里。
        if let afterClass = entry.configuration.afterClass {
            displayOptions.afterClass = afterClass
        }
        return Group {
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
        .environment(\.scheduleWidgetColorfulCourses, !NextWidgetConfiguration.solidCourseColors)
        .environment(\.scheduleWidgetDisplayOptions, displayOptions)
        .environment(\.scheduleWidgetConfiguration, entry.configuration)
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
    @Environment(\.scheduleWidgetConfiguration) private var configuration

    @ViewBuilder
    var body: some View {
        let selection = payload.upcoming(afterClass: options.afterClass)
        // 「最近有课的一天」把今天换成了别的日子：标出来，课程压暗。
        let otherDayHint = OtherDay.hint(for: selection.0)
        if family.isAccessory {
            LockScreenScheduleView(payload: payload, day: selection.0, courses: selection.1)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                // 换到别的日子时日期栏照旧是今天，靠「明天的课」说明下面是哪天的课。
                WidgetDateHeader(
                    day: otherDayHint == nil ? selection.0 : payload.currentDay(),
                    hidesCountdown: selection.1.isEmpty
                        && AfterClassView.showsHolidayCard(payload: payload, options: options),
                    tableName: payload.title,
                    dayHint: otherDayHint
                )
                Spacer(minLength: 8)

                if selection.1.isEmpty {
                    AfterClassView(payload: payload, limit: family == .systemMedium ? 2 : 1)
                } else if family == .systemMedium {
                    HStack(alignment: .top, spacing: 14) {
                        UpcomingColumn(label: otherDayHint == nil ? "当前" : "第一节", course: selection.1.first)
                        Divider()
                        UpcomingColumn(label: "接下来", course: selection.1.count > 1 ? selection.1[1] : nil)
                    }
                    .dimmedAsOtherDay(otherDayHint != nil)
                } else if let course = selection.1.first {
                    // 默认只放一节：当前这节，没在上课就是接下来那节。「编辑小组件」里可以改成两节。
                    let showsNext = configuration.upcomingCourseCount > 1 && selection.1.count > 1
                    // 两节挤在小号里：第一节的色条跟着文字走、课名只占一行，第二节不再另起标题。
                    CourseSummary(course: course, roomy: true, fitsContent: showsNext)
                        .dimmedAsOtherDay(otherDayHint != nil)
                    if showsNext {
                        Spacer(minLength: 6)
                        CompactNextCourse(course: selection.1[1])
                            .dimmedAsOtherDay(otherDayHint != nil)
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
        case .holiday, .nextCourseDay:
            // 「最近有课的一天」在选课时就已经换过日子了，走到这里说明三周内都没课。
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
                // 换到了别的日子时带上「明天」，锁屏是单色的，压暗看不出来。
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
    /// 色条高度跟着文字，课名只占一行。小号放两节课时用，固定高度的色条会在时间下面空出一截。
    var fitsContent = false
    @Environment(\.scheduleWidgetTheme) private var theme
    @Environment(\.scheduleWidgetColorfulCourses) private var colorfulCourses
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scheduleWidgetDisplayOptions) private var options

    var body: some View {
        HStack(alignment: .top, spacing: roomy ? 9 : 7) {
            RoundedRectangle(cornerRadius: 3)
                .fill(WidgetPalette.accent(for: course, theme: theme, colorful: colorfulCourses, colorScheme: colorScheme))
                .frame(width: 5, height: fitsContent ? nil : (roomy ? 58 : 62))
                .frame(maxHeight: fitsContent ? .infinity : nil)
            VStack(alignment: .leading, spacing: roomy ? 3 : 2) {
                if let primary = options.primaryValue(for: course) {
                    Text(primary)
                        .font(.system(size: roomy ? 15 : 13, weight: .bold))
                        .foregroundStyle(WidgetPalette.primary)
                        .lineLimit(fitsContent ? 1 : 2)
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
        .fixedSize(horizontal: false, vertical: fitsContent)
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
    @Environment(\.widgetFamily) private var family
    @Environment(\.scheduleWidgetDisplayOptions) private var options

    var body: some View {
        let now = Date.now
        let today = payload.currentDay(now: now)
        let nowMinutes = today.date == WidgetSchedulePayload.dateString(now)
            ? WidgetSchedulePayload.minutesSinceMidnight(now)
            : nil
        // 今天已经没有未结束的课程时，这块位置交给「明天 / 最近节假日」。
        let finished = nowMinutes.map { minutes in
            today.courseList.allSatisfy { $0.hasEnded(at: minutes) }
        } ?? false
        let showsAfterClass = today.courseList.isEmpty || (finished && options.showsAfterClassPreview)
        // 「最近有课的一天」：课换成那一天的（日期栏照旧是今天，课程压暗）；三周内都没课才走下面的课后卡片。
        let rolled = showsAfterClass && options.afterClass == .nextCourseDay
            ? payload.nextCourseDay(after: now)
            : nil
        Group {
            if let rolled {
                courseList(day: rolled.day, nowMinutes: nil, otherDay: true, headerDay: today)
            } else if showsAfterClass {
                // 课后卡片自己会撑满剩下的高度，不参与下面按行数挑排法。
                VStack(alignment: .leading, spacing: spacing) {
                    WidgetDateHeader(
                        day: today,
                        showsCountdown: true,
                        hidesCountdown: AfterClassView.showsHolidayCard(payload: payload, options: options),
                        tableName: payload.title
                    )
                    AfterClassView(
                        payload: payload,
                        limit: family == .systemLarge ? 5 : 2,
                        showsRemainingCount: family != .systemMedium
                    )
                }
            } else {
                courseList(day: today, nowMinutes: nowMinutes)
            }
        }
        // 大号的课排不满时，系统默认把整块内容竖着居中，日期栏就飘在半空；贴顶放。
        .frame(maxHeight: family == .systemLarge ? .infinity : nil, alignment: .top)
    }

    private var spacing: CGFloat { family == .systemLarge ? 8 : 7 }

    /// `otherDay`：换到了最近有课的另一天，日期栏照旧是今天（`headerDay`），标上「明天的课」，课程压暗。
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
            // 两门课之间的间隔一档档收，但不低于 4，再挤就粘在一起了；提示和上面那门课
            // 之间的距离不动。还放不下（小屏手机）才把提示贴到右下角，往下探进系统留的边距里。
            let window = day.courseWindow(limit: maxLimit, nowMinutes: nowMinutes)
            ViewThatFits(in: .vertical) {
                ForEach([7, 6, 5, 4] as [CGFloat], id: \.self) { rowSpacing in
                    courses(
                        today: day, nowMinutes: nowMinutes, limit: maxLimit, rowSpacing: rowSpacing,
                        otherDay: otherDay, headerDay: headerDay
                    )
                }
                courses(
                    today: day, nowMinutes: nowMinutes, limit: maxLimit, rowSpacing: 6, showsRemaining: false,
                    otherDay: otherDay, headerDay: headerDay
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
        rowSpacing: CGFloat? = nil,
        showsRemaining: Bool = true,
        otherDay: Bool = false,
        headerDay: WidgetDay? = nil
    ) -> some View {
        let window = today.courseWindow(limit: limit, nowMinutes: nowMinutes)
        return VStack(alignment: .leading, spacing: 0) {
            // 中号从日期栏和第一门课之间省出一点，留给两门课之间。
            WidgetDateHeader(
                day: headerDay ?? today,
                showsCountdown: true,
                tableName: payload.title,
                dayHint: otherDay ? OtherDay.hint(for: today) : nil
            )
                .padding(.bottom, family == .systemLarge ? spacing : 5)
            VStack(alignment: .leading, spacing: rowSpacing ?? spacing) {
                ForEach(Array(window.courses.enumerated()), id: \.offset) { _, course in
                    TodayCourseRow(
                        course: course,
                        large: family == .systemLarge,
                        timeOnSeparateLine: false,
                        completed: otherDay || (nowMinutes.map { course.hasEnded(at: $0) } ?? false),
                        verticalPadding: family == .systemLarge ? nil : 3
                    )
                }
            }
            if showsRemaining && window.remainingCount > 0 {
                // 和上面那门课拉开一点，不然像是那门课的附注。
                remainingText(window.remainingCount)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, family == .systemLarge ? 10 : 8)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
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

private struct TwoDayScheduleView: View {
    let payload: WidgetSchedulePayload
    @Environment(\.scheduleWidgetConfiguration) private var configuration

    var body: some View {
        let now = Date.now
        let today = payload.currentDay(now: now)
        let tomorrowDate = WidgetSchedulePayload.dateString(
            Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now
        )
        // 「编辑小组件」里可以把右边换成最近有课的一天：左边照旧是今天（没课就说没课、道祝福），
        // 右边跳过没课的日子；三周内都没课时照旧是明天。
        let next = configuration.twoDayStart == .nextCourseDay ? payload.nextCourseDay(after: now) : nil
        let right = next?.day ?? payload.fullDay(for: tomorrowDate, fallbackOffset: 1)

        HStack(alignment: .top, spacing: 13) {
            DayColumn(
                day: today,
                nowMinutes: WidgetSchedulePayload.minutesSinceMidnight(now),
                isToday: true,
                siblingHasCourses: !right.courseList.isEmpty,
                tableName: payload.title
            )
            Divider()
            // 右边不是明天时标上「后天的课」「3 天后的课」。
            DayColumn(
                day: right,
                nowMinutes: nil,
                tableName: payload.title,
                hidesTableName: true,
                dayHint: (next?.offset ?? 1) > 1 ? OtherDay.hint(for: right) : nil
            )
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
    var tableName: String? = nil
    /// 明天那列也占着课表名那一行但不显示，两列的课才对得齐。
    var hidesTableName = false
    var dayHint: String? = nil

    var body: some View {
        let window = day.courseWindow(limit: 5, nowMinutes: nowMinutes)
        VStack(alignment: .leading, spacing: 7) {
            WidgetDateHeader(day: day, compact: true, tableName: tableName, hidesTableName: hidesTableName, dayHint: dayHint)
                // 日期栏和下面的课拉开到 18（加上外面 VStack 的 7），比课与课之间松。
                .padding(.bottom, 11)
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
    /// 当前课表名，放在第二行最左边。两日课表只在今天那一列写一次。
    var tableName: String? = nil
    /// 课表名只占位不显示（两日课表明天那一列）。
    var hidesTableName = false
    /// 显示的不是今天时（「最近有课的一天」）第二行右边的标注，比假期倒计时优先。
    var dayHint: String? = nil
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
            secondaryLine
                // 竖线比字高，靠负边距把这行收回去，贴着上一行的文字底部。「明天的课」带着
                // 胶囊底色，比字高，再往上收就压住上一行的「第 N 周」，反过来留一点空。
                .padding(.top, dayHint == nil ? -2 : 4)
        }
    }

    /// 第二行：左边课表名、调休，右边假期倒计时。一行挤不下（小号）时倒计时换到
    /// 下一行；连这样都放不下才按重要程度往下减：先去倒计时，再去课表名，调休留到最后。
    @ViewBuilder
    private var secondaryLine: some View {
        let note = day.normalizedNote.flatMap { repeatsBadge($0) ? nil : $0 }
        let trimmedName = tableName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 只占位的课表名碰上调休：这一行已经有调休撑着了，别把它往右推。
        let name: String? = trimmedName.isEmpty || (hidesTableName && note != nil) ? nil : trimmedName
        // 调休那天就不报倒计时了，和以前一样；显示的不是今天时，那个位置让给「明天的课」。
        let countdown = day.normalizedNote == nil && !compact && dayHint == nil ? holidayCountdown : nil
        if note != nil || name != nil || countdown != nil || dayHint != nil {
            ViewThatFits(in: .horizontal) {
                secondaryRow(name: name, note: note, countdown: countdown)
                if let countdown {
                    VStack(alignment: .trailing, spacing: 1) {
                        secondaryRow(name: name, note: note, countdown: nil)
                        HolidayCountdownChip(countdown: countdown)
                            .fixedSize()
                    }
                }
                secondaryRow(name: name, note: note, countdown: nil)
                secondaryRow(name: nil, note: note, countdown: nil)
                // 「明天的课」要一直在：挤不下时连调休也让出去。
                if dayHint != nil {
                    secondaryRow(name: nil, note: nil, countdown: nil)
                }
                // 调休一句话自己都放不下时，交给它自己的缩字。
                if let note {
                    AdjustmentNoteChip(note: note)
                }
            }
        }
    }

    private func secondaryRow(
        name: String?,
        note: String?,
        countdown: ChineseHolidayCountdown?
    ) -> some View {
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
            } else if let countdown {
                HolidayCountdownChip(countdown: countdown)
                    .fixedSize()
            }
        }
    }

    private func header(isCompact: Bool) -> some View {
        let weekday = day.displayLabel.isEmpty ? nil : day.displayLabel
        // 小号一行要塞下日期、星期、农历和「第 N 周」，各列之间收紧一点。
        return HStack(spacing: isCompact ? 4 : 6) {
            // 小号里一行很挤，日期绝不能被压得折行，宁可让右边的周数让位。
            Text(day.compactDate)
                .font(.system(size: 19, weight: .bold, design: .rounded))
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

            if let week = day.week, week > 0 {
                // 放不下「第 N 周」先去掉空格、再缩字，都放不下才不显示；「第」不省，
                // 单写「5周」像是说五个星期。也别去挤左边的日期。
                ViewThatFits(in: .horizontal) {
                    weekLabel("第 \(week) 周")
                    weekLabel("第\(week)周")
                    weekLabel("第\(week)周", size: 9)
                    weekLabel("第\(week)周", size: 8)
                    Color.clear.frame(width: 0, height: 0)
                }
            }
        }
    }

    private func weekLabel(_ text: String, size: CGFloat = 10) -> some View {
        Text(text)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(WidgetPalette.secondary)
            .lineLimit(1)
            .fixedSize()
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

/// 选了「最近有课的一天」、小组件换到别的日子时，日期栏上的标注：「明天的课」「3 天后的课」。
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
    static func offset(of day: WidgetDay, now: Date = .now) -> Int? {
        guard let date = day.date, let target = ChineseCalendarInfo.date(fromDate: date) else { return nil }
        let calendar = ChineseCalendarInfo.gregorian
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: target)).day ?? 0
        return days > 0 ? days : nil
    }

    /// 「明天」「后天」「3 天后」。
    static func label(for day: WidgetDay, now: Date = .now) -> String? {
        guard let days = offset(of: day, now: now) else { return nil }
        switch days {
        case 1: return "明天"
        case 2: return "后天"
        default: return "\(days) 天后"
        }
    }

    /// 日期栏上的「明天的课」。
    static func hint(for day: WidgetDay, now: Date = .now) -> String? {
        label(for: day, now: now).map { "\($0)的课" }
    }
}

private extension View {
    /// 不是今天的课：和已经下课、课后预览明天的课一样压暗，不抢今天的注意力。
    func dimmedAsOtherDay(_ dimmed: Bool) -> some View {
        saturation(dimmed ? 0 : 1).opacity(dimmed ? 0.56 : 1)
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
    var showsRemainingCount: Bool = true
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
        case .holiday, .nextCourseDay:
            // 「最近有课的一天」由外面直接换成那一天；到这里说明三周内都没课，就给假期。
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
            if showsRemainingCount && day.courseList.count > visible.count {
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
            if let footnote = countdown.flatMap({ Self.holidayFootnote($0) }) {
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

    /// 「距国庆节还有 12 天」「距中秋节还有 1 天」；锁屏那一行也用它。
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
        case .nextCourseDay: return payload.nextCourseDay(after: now) == nil
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
        if let payload {
            entry = ScheduleEntry(date: now, state: .loaded(payload))
        } else {
            entry = ScheduleEntry(date: now, state: .unconfigured)
        }
        let periodic = Calendar.current.date(byAdding: .minute, value: 30, to: now) ?? now.addingTimeInterval(1800)
        // 下课那一刻就该换内容（划掉已结束的课、放学后切到明天），别等下一个半小时。
        let refresh = payload.flatMap { Self.nextBoundary(in: $0, now: now) }.map { min($0, periodic) } ?? periodic
        return Timeline(entries: [entry], policy: .after(refresh))
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
