import SwiftUI

struct NativeScheduleDayColumn: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scheduleHasBackgroundImage) private var hasBackground
    // Week-grid heights: compact 40, comfortable 44, relaxed 49.
    static let slotHeight: CGFloat = 44
    // The Web grid uses a 3px row gap on mobile. Keep the native cells on the
    // same rhythm so empty rows do not look stretched apart.
    static let slotGap: CGFloat = 3
    static let dateHeaderHeight: CGFloat = 48

    let day: Int
    let dateText: String?
    /// 表头上显示的日期：平时只写几号，月初写「10月」。为空时退回 `dateText`。
    var headerDateText: String? = nil
    let isToday: Bool
    /// 这一天的调休。有值时日期旁边多一个「休」/「班」角标。
    let adjustment: ResolvedCalendarAdjustment?
    let columnWidth: CGFloat
    let rowHeight: CGFloat
    /// 画到第几节。晚上没课的行可以收起来，见 `NativeSchedulePreferences.hideSlotsAfter`。
    var slotCount: Int = ScheduleSlot.all.count
    let compactCards: Bool
    let showsDateHeader: Bool
    let blocks: [NativeScheduleCourseBlock]
    let onCourseSelected: (NativeScheduleCourseBlock) -> Void
    let onEmptySlot: (Int) -> Void

    /// 每张卡片所在「重叠簇」的列数：互相重叠（含连环重叠）的课一起分列，
    /// 其他时段的课保持整宽，不再因为当天某处有冲突就整天变窄。
    private var clusterLaneCounts: [String: Int] {
        var counts: [String: Int] = [:]
        var cluster: [NativeScheduleCourseBlock] = []
        var clusterEnd = Int.min
        func flush() {
            let lanes = max(1, (cluster.map(\.lane).max() ?? 0) + 1)
            for block in cluster { counts[block.id] = lanes }
            cluster.removeAll()
        }
        for block in blocks.sorted(by: { ($0.startSlot, $0.endSlot) < ($1.startSlot, $1.endSlot) }) {
            if !cluster.isEmpty && block.startSlot > clusterEnd { flush() }
            cluster.append(block)
            clusterEnd = cluster.count == 1 ? block.endSlot : max(clusterEnd, block.endSlot)
        }
        flush()
        return counts
    }

    private var headerAccessibilityLabel: String {
        let base = [dayLabel, dateText].compactMap { $0 }.joined(separator: " ")
        guard let adjustment else { return base }
        return "\(base)，\(adjustment.detail)"
    }

    private var columnHeight: CGFloat {
        CGFloat(slotCount) * rowHeight + CGFloat(max(0, slotCount - 1)) * Self.slotGap
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsDateHeader {
                // 和日视图星期条同一个写法：几号在上、星期在下，今天写「今天」。
                VStack(spacing: 3) {
                    HStack(spacing: 1) {
                        Text(headerDateText ?? dateText ?? "–")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(isToday ? Color.cpuBrand : Color.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        if let adjustment {
                            ScheduleAdjustmentBadge(adjustment: adjustment)
                        }
                    }
                    // The badge is fixed-size, so cap the row to the header's
                    // inner box and let the date shrink instead of spilling out.
                    .frame(maxWidth: max(0, columnWidth - 6))
                    Text(isToday ? "今天" : dayLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isToday ? Color.cpuBrand : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                // 星期表头不加框，直接把字放在底色上；今天靠主题色文字和整列淡底标出来。
                .frame(width: columnWidth, height: Self.dateHeaderHeight)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(headerAccessibilityLabel)
            }

            let laneCounts = clusterLaneCounts
            ZStack(alignment: .topLeading) {
                // 空节次不画格子，只留一块透明的长按区域；整张表的分隔线由外层统一画。
                VStack(spacing: Self.slotGap) {
                    ForEach(ScheduleSlot.all.prefix(slotCount), id: \.number) { slot in
                        let occupied = blocks.contains { ($0.startSlot...$0.endSlot).contains(slot.number) }
                        Color.clear
                            .frame(width: columnWidth, height: rowHeight)
                            .contentShape(Rectangle())
                            .modifier(ScheduleLongPressFeedback {
                                guard !occupied else { return }
                                onEmptySlot(slot.number)
                            })
                            .allowsHitTesting(!occupied)
                            .accessibilityLabel(Text(verbatim: "第 \(slot.number) 节，长按添加课程"))
                            .accessibilityAddTraits(.isButton)
                    }
                }
                ForEach(blocks) { block in
                    let laneCount = laneCounts[block.id] ?? 1
                    NativeScheduleCourseCard(course: block.course, compact: compactCards || columnWidth < 70)
                        .frame(
                            width: max(12, columnWidth / CGFloat(laneCount) - 2),
                            height: max(
                                34,
                                CGFloat(block.endSlot - block.startSlot + 1) * rowHeight
                                    + CGFloat(block.endSlot - block.startSlot) * Self.slotGap
                                    - 2
                            )
                        )
                        .contentShape(Rectangle())
                        .modifier(ScheduleLongPressFeedback(cornerRadius: NativeScheduleCourseCard.gridCornerRadius, pressedScale: 1.10) {
                            onCourseSelected(block)
                        })
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint(Text("长按修改课程"))
                    .offset(
                        x: 1 + CGFloat(block.lane) * (columnWidth / CGFloat(laneCount)),
                        y: CGFloat(block.startSlot - 1) * (rowHeight + Self.slotGap) + 1
                    )
                }
            }
            .frame(width: columnWidth, height: columnHeight)
        }
        .frame(width: columnWidth)
        .background {
            if isToday {
                // 今天整列用柔和的主题色底，深浅模式都清晰可见
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.cpuBrand.opacity(hasBackground ? (colorScheme == .dark ? 0.18 : 0.14) : (colorScheme == .dark ? 0.15 : 0.08)))
                    .allowsHitTesting(false)
            }
        }
    }

    private var dayLabel: String {
        ["周一", "周二", "周三", "周四", "周五", "周六", "周日"].indices.contains(day - 1)
            ? ["周一", "周二", "周三", "周四", "周五", "周六", "周日"][day - 1]
            : "周\(day)"
    }
}

/// 「08:00」→ 480。解析不了返回 nil。
func scheduleClockMinutes(_ value: String) -> Int? {
    let parts = value.split(separator: ":").compactMap { Int($0) }
    return parts.count >= 2 ? parts[0] * 60 + parts[1] : nil
}

/// 日期旁边的调休角标：放假「休」，调课「班」。周视图表头和日视图星期条共用。
struct ScheduleAdjustmentBadge: View {
    let adjustment: ResolvedCalendarAdjustment

    var body: some View {
        Text(adjustment.badge)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.white)
            .fixedSize()
            .frame(width: 11, height: 11, alignment: .center)
            // 小字号汉字做光学居中，仅移动文字，不移动底色。
            .offset(x: 0.2)
            .background(
                (adjustment.kind == .off ? Color.pink : Color.orange).opacity(0.85),
                in: RoundedRectangle(cornerRadius: 3, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

/// 按下立即显示反馈；只有长按成功时才震动，滚动或提前松手不会触发。
private struct ScheduleLongPressFeedback: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPressed = false
    @State private var feedbackTrigger = 0

    var cornerRadius: CGFloat = 8
    var pressedScale: CGFloat = 1.04
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(isPressed ? 0.16 : 0))
                    .allowsHitTesting(false)
            }
            .scaleEffect(isPressed && !reduceMotion ? pressedScale : 1)
            .shadow(color: .black.opacity(isPressed ? 0.12 : 0), radius: 6, y: 2)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.8), value: isPressed)
            .zIndex(isPressed ? 1 : 0)
            .onLongPressGesture(minimumDuration: 0.4) {
                isPressed = false
                feedbackTrigger += 1
                action()
            } onPressingChanged: { pressing in
                isPressed = pressing
            }
            #if os(iOS)
            .sensoryFeedback(.impact(weight: .heavy, intensity: 1), trigger: feedbackTrigger)
            #endif
    }
}



/// 只按课程起始时间排列，不为空节次预留网格。同一时刻的课共用一个时间节点。
struct NativeScheduleDayTimeline: View {
    let blocks: [NativeScheduleCourseBlock]
    let clocks: [ScheduleSlot]
    /// 没课时空状态下面的一行说明，比如调休的「国庆节放假」。
    var emptyNote: String? = nil
    var holidayGreeting: String? = nil
    /// 今天才有值：课表时区下零点起的分钟数，用来标出正在上和下一节。
    var nowMinutes: Int? = nil
    /// 用于已结束卡片的判断，也适用于过去日期和关闭「现在」指示器时。
    var completedBeforeMinutes: Int? = nil
    var cardHeight: CGFloat = 108
    /// 日视图传入可见区域高度；分享图沿用内容本身的高度。
    var emptyHeight: CGFloat = 0
    let onCourseSelected: (NativeScheduleCourseBlock) -> Void

    private static let groupGap: CGFloat = 20

    /// 一组课（同一时刻开始的那几门）相对「现在」的位置。
    private enum Phase: Equatable {
        case none
        case past
        /// 正在上，还剩几分钟。
        case current(remaining: Int)
        /// 今天的下一组，还有几分钟开始。
        case next(minutesUntil: Int)
    }

    private func phases(_ groups: [[NativeScheduleCourseBlock]]) -> [Phase] {
        guard let now = nowMinutes else { return groups.map { _ in .none } }
        var foundNext = false
        let ranges = groups.map { courses -> (Int, Int)? in
            let startSlot = courses[0].startSlot
            let endSlot = courses.map(\.endSlot).max() ?? startSlot
            guard let start = scheduleClockMinutes(startTime(startSlot)),
                  let end = scheduleClockMinutes(endTime(endSlot)) else { return nil }
            return (start, end)
        }
        let inClass = ranges.contains { range in range.map { $0.0 <= now && now <= $0.1 } ?? false }
        return ranges.map { range in
            guard let (start, end) = range else { return .none }
            if now > end { return .past }
            if now >= start { return .current(remaining: end - now) }
            if !inClass && !foundNext {
                foundNext = true
                return .next(minutesUntil: start - now)
            }
            return .none
        }
    }
    private static let cardGap: CGFloat = 10
    /// 节点在每组里的纵向位置，和时间文字第一行对齐。
    private static let nodeY: CGFloat = 28

    private func heightOfGroup(_ courses: [NativeScheduleCourseBlock]) -> CGFloat {
        CGFloat(courses.count) * cardHeight + CGFloat(courses.count - 1) * Self.cardGap
    }

    /// 「现在」落在时间线上的纵向位置（相对整列顶部），左边细线在它以上染成主题色。
    /// 上课期间从节点走到卡片底，课间从卡片底走到下一组的节点。不是今天时为 nil。
    private func progressY(_ groups: [[NativeScheduleCourseBlock]]) -> CGFloat? {
        guard let now = nowMinutes else { return nil }
        var knots: [(minutes: Int, y: CGFloat)] = []
        var top: CGFloat = 0
        for courses in groups {
            let startSlot = courses[0].startSlot
            let endSlot = courses.map(\.endSlot).max() ?? startSlot
            let height = heightOfGroup(courses)
            if let start = scheduleClockMinutes(startTime(startSlot)) {
                knots.append((max(start, knots.last?.minutes ?? start), top + Self.nodeY))
            }
            if let end = scheduleClockMinutes(endTime(endSlot)) {
                knots.append((max(end, knots.last?.minutes ?? end), top + max(Self.nodeY, height)))
            }
            top += height + Self.groupGap
        }
        guard let first = knots.first, now >= first.minutes else { return 0 }
        for (a, b) in zip(knots, knots.dropFirst()) where now < b.minutes {
            let fraction = CGFloat(now - a.minutes) / CGFloat(max(1, b.minutes - a.minutes))
            return a.y + (b.y - a.y) * fraction
        }
        return knots.last?.y ?? 0
    }

    private var groups: [[NativeScheduleCourseBlock]] {
        Dictionary(grouping: blocks, by: \.startSlot)
            .sorted { $0.key < $1.key }
            .map { _, courses in
                courses.sorted { ($0.lane, $0.endSlot, $0.id) < ($1.lane, $1.endSlot, $1.id) }
            }
    }

    static func height(blocks: [NativeScheduleCourseBlock], cardHeight: CGFloat) -> CGFloat {
        guard !blocks.isEmpty else { return max(220, cardHeight * 2) }
        let groupCount = Set(blocks.map(\.startSlot)).count
        return CGFloat(blocks.count) * cardHeight
            + CGFloat(blocks.count - groupCount) * cardGap
            + CGFloat(groupCount - 1) * groupGap
    }

    var body: some View {
        if blocks.isEmpty {
            ScheduleEmptyDayView(note: emptyNote, holidayGreeting: holidayGreeting)
                .frame(height: max(emptyHeight, Self.height(blocks: blocks, cardHeight: cardHeight)))
                .modifier(ScheduleHolidayFireworks())
        } else {
            let groups = groups
            let phases = phases(groups)
            let groupTops = groups.indices.map { index in
                groups[..<index].reduce(CGFloat(0)) { $0 + heightOfGroup($1) + Self.groupGap }
            }
            // 正在上或等待下一节时，染色线至少连接到对应的主题色节点。
            // 课间的时间插值可能还没走到下一节点，不能让线和高亮圆圈断开。
            let highlightedNodeY = groups.indices.compactMap { index -> CGFloat? in
                switch phases[index] {
                case .current, .next: return groupTops[index] + Self.nodeY
                case .past, .none: return nil
                }
            }.max() ?? 0
            let progress = progressY(groups).map { max($0, highlightedNodeY) }
            let isInClass = phases.contains { phase in
                if case .current = phase { return true }
                return false
            }
            VStack(alignment: .leading, spacing: Self.groupGap) {
                ForEach(groups.indices, id: \.self) { index in
                    let courses = groups[index]
                    let phase = phases[index]
                    let startSlot = courses[0].startSlot
                    let endSlot = courses.map(\.endSlot).max() ?? startSlot
                    let groupHeight = heightOfGroup(courses)
                    let lineTop = index == 0 ? Self.nodeY : 0
                    // 最后一组正在上课时，线也继续向卡片底部延伸。
                    let lineBottom = index == groups.count - 1
                        ? (isInClass ? max(Self.nodeY, (progress ?? 0) - groupTops[index]) : Self.nodeY)
                        : groupHeight + Self.groupGap
                    let filled = progress.map {
                        min(max($0 - groupTops[index] - lineTop, 0), max(0, lineBottom - lineTop))
                    } ?? 0
                    HStack(alignment: .top, spacing: 12) {
                        // 开始时间是这一栏的主角，结束时间和节次退到下面两行。正在上或
                        // 下一节时，第三行换成主题色的剩余 / 倒计时，标出现在走到哪了。
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(startTime(startSlot))
                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                                .foregroundStyle(startColor(phase))
                            Text(endTime(endSlot))
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(phase == .past ? .tertiary : .secondary)
                            if let status = statusText(phase) {
                                Text(status)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.cpuBrand)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.cpuBrand.opacity(0.12), in: Capsule())
                                    .padding(.top, 2)
                            } else {
                                Text(slotRange(startSlot, endSlot))
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 2)
                            }
                        }
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(width: 56, alignment: .trailing)
                        .padding(.top, 17)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            ["\(slotRange(startSlot, endSlot))，\(startTime(startSlot)) 至 \(endTime(endSlot))", statusText(phase)]
                                .compactMap { $0 }.joined(separator: "，")
                        )

                        VStack(spacing: Self.cardGap) {
                            ForEach(courses) { block in
                                NativeScheduleCourseCard(
                                    course: block.course,
                                    timeline: true,
                                    isCompleted: isCompleted(block),
                                    // 左栏已经写了节次；同一时刻有几门课、各自结束得不一样时才在卡片上补一行。
                                    slotLabel: courses.count > 1 ? slotLabel(block, showsTime: true) : nil
                                )
                                .frame(height: cardHeight)
                                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                                .modifier(ScheduleLongPressFeedback(cornerRadius: 20) {
                                    onCourseSelected(block)
                                })
                                .accessibilityAddTraits(.isButton)
                                .accessibilityHint("长按修改课程")
                                .accessibilityAction { onCourseSelected(block) }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.leading, 16)
                    .overlay(alignment: .topLeading) {
                        // 细线在时间文字外侧连接节点，课程之间只保留固定留白；
                        // 节点所在的位置留空，让实心点盖住线、空心圈内保持透明。
                        let nodeRadius = TimelineNode.diameter(for: phase) / 2
                        let rail = Path { path in
                            let upperEnd = min(lineBottom, Self.nodeY - nodeRadius)
                            if upperEnd > lineTop {
                                path.addRect(CGRect(x: 2, y: lineTop, width: 1, height: upperEnd - lineTop))
                            }
                            let lowerStart = max(lineTop, Self.nodeY + nodeRadius)
                            if lineBottom > lowerStart {
                                path.addRect(CGRect(x: 2, y: lowerStart, width: 1, height: lineBottom - lowerStart))
                            }
                        }
                        ZStack(alignment: .top) {
                            rail
                                .fill(Color.secondary.opacity(0.15))
                                .frame(width: 5, height: max(groupHeight, lineBottom))
                            rail
                                .fill(Color.cpuBrand.opacity(0.6))
                                .frame(width: 5, height: max(groupHeight, lineBottom))
                                .mask(alignment: .top) {
                                    Rectangle().frame(height: lineTop + filled)
                                }
                            TimelineNode(phase: phase)
                                .offset(y: Self.nodeY - TimelineNode.size / 2)
                            if isInClass, let progress,
                               progress > groupTops[index] + lineTop,
                               progress <= groupTops[index] + lineBottom,
                               abs(progress - groupTops[index] - Self.nodeY) > nodeRadius + 1 {
                                Capsule()
                                    .fill(Color.cpuBrand)
                                    .frame(width: 9, height: 2)
                                    .offset(y: progress - groupTops[index] - 1)
                            }
                        }
                        .frame(width: 5, height: groupHeight, alignment: .top)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    private func startColor(_ phase: Phase) -> Color {
        switch phase {
        case .current, .next: Color.cpuBrand
        case .past: Color.secondary
        case .none: Color.primary
        }
    }

    private func statusText(_ phase: Phase) -> String? {
        switch phase {
        case .current(let remaining):
            return "还剩 \(max(1, remaining)) 分"
        case .next(let minutes):
            if minutes < 60 { return "\(max(1, minutes)) 分钟后" }
            return "约 \(Int((Double(minutes) / 60).rounded())) 小时后"
        case .past, .none:
            return nil
        }
    }

    /// 时间线上的节点：正在上是带光晕的实心点，下一节是主题色空心圈，上完的课保留主题色实心标记。
    private struct TimelineNode: View {
        static let size: CGFloat = 13
        let phase: Phase

        static func diameter(for phase: Phase) -> CGFloat {
            switch phase {
            case .current, .past: 7
            case .next: 8
            case .none: 5
            }
        }

        var body: some View {
            ZStack {
                switch phase {
                case .current:
                    Circle().fill(Color.cpuBrand.opacity(0.2))
                    Circle().fill(Color.cpuBrand).frame(width: Self.diameter(for: phase), height: Self.diameter(for: phase))
                case .next:
                    Circle().strokeBorder(Color.cpuBrand, lineWidth: 1.5).frame(width: Self.diameter(for: phase), height: Self.diameter(for: phase))
                case .past:
                    Circle().fill(Color.cpuBrand.opacity(0.6)).frame(width: Self.diameter(for: phase), height: Self.diameter(for: phase))
                case .none:
                    Circle().fill(Color.secondary.opacity(0.45)).frame(width: Self.diameter(for: phase), height: Self.diameter(for: phase))
                }
            }
            .frame(width: Self.size, height: Self.size)
        }
    }

    private func startTime(_ slot: Int) -> String {
        clocks.first { $0.number == slot }?.start ?? "—"
    }

    private func isCompleted(_ block: NativeScheduleCourseBlock) -> Bool {
        guard let minutes = completedBeforeMinutes ?? nowMinutes,
              let end = scheduleClockMinutes(endTime(block.endSlot)) else { return false }
        return minutes >= end
    }

    private func endTime(_ slot: Int) -> String {
        clocks.first { $0.number == slot }?.end ?? "—"
    }

    private func slotRange(_ start: Int, _ end: Int) -> String {
        start == end ? "第 \(start) 节" : "\(start)–\(end) 节"
    }

    private func slotLabel(_ block: NativeScheduleCourseBlock, showsTime: Bool) -> String {
        let slots = block.startSlot == block.endSlot
            ? "第 \(block.startSlot) 节"
            : "第 \(block.startSlot)–\(block.endSlot) 节"
        return showsTime ? "\(slots) · \(startTime(block.startSlot))–\(endTime(block.endSlot))" : slots
    }
}

struct NativeScheduleCourseCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scheduleHasBackgroundImage) private var hasBackground
    @ObservedObject private var themeSettings = NativeThemeSettings.shared
    let course: NativeScheduleCourse
    var compact = false
    var timeline = false
    var isCompleted = false
    var slotLabel: String? = nil

    static let gridCornerRadius: CGFloat = 9

    var body: some View {
        Group {
            if timeline {
                VStack(alignment: .leading, spacing: 7) {
                    Text(course.name)
                        .font(.headline.weight(completedAppearance ? .medium : .semibold))
                        .foregroundStyle(completedAppearance ? Color.secondary : Color.primary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .layoutPriority(1)
                        .padding(.trailing, completedAppearance ? 26 : 0)
                    if let location = displayLocation {
                        Text("@\(location)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .accessibilityLabel("教室 \(location)")
                    }
                    if let slotLabel {
                        Text(slotLabel)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(completedAppearance ? Color.secondary : accent.opacity(0.8))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            } else {
                gridContent
            }
        }
        .background {
            RoundedRectangle(cornerRadius: timeline ? 20 : Self.gridCornerRadius, style: .continuous)
                .fill(courseFill)
                .allowsHitTesting(false)
        }
        // 日视图的卡片用一圈很轻的高光边缘收住淡彩，配合圆角和轻微阴影，
        // 保留 Liquid Glass 那种「有边界、没有厚重外框」的层次感。
        .overlay {
            if timeline {
                let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
                shape
                    .strokeBorder(courseBorder, lineWidth: 1)
                    .overlay {
                        if !completedAppearance {
                            shape.strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.62), lineWidth: 0.6)
                        }
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: timeline ? 20 : Self.gridCornerRadius, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if completedAppearance {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                    .frame(width: 25, height: 25)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(accent.opacity(colorScheme == .dark ? 0.20 : 0.12))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(accent.opacity(0.22), lineWidth: 1)
                            }
                    }
                    .rotationEffect(.degrees(10))
                    .padding(.trailing, 12)
                    .offset(y: -12.5)
                    .allowsHitTesting(false)
                    .accessibilityLabel("已结束")
            }
        }
        .shadow(
            color: timeline && !completedAppearance ? Color.black.opacity(colorScheme == .dark ? 0.18 : 0.07) : .clear,
            radius: timeline ? 7 : 0,
            y: timeline ? 3 : 0
        )
        .accessibilityElement(children: .combine)
    }

    private var gridContent: some View {
        GeometryReader { geometry in
            let shortCard = geometry.size.height < 64
            let small = compact || shortCard
            // 卡片上除了课名只放教室；老师、周次和备注在课程详情里看。
            let location = displayLocation

            // 文字居上、左对齐：课名在前，「@教室」跟在下面。
            VStack(alignment: .leading, spacing: small ? 2 : 4) {
                Text(course.name)
                    .font(.system(size: small ? 11 : 13, weight: .semibold))
                    .lineLimit(shortCard ? 2 : (compact ? 4 : 3))
                    .minimumScaleFactor(0.85)
                    .layoutPriority(1)

                if let location {
                    Text("@\(location)")
                        .font(.system(size: small ? 9 : 11, weight: .medium))
                        .opacity(0.72)
                        .lineLimit(shortCard ? 1 : 2)
                        .minimumScaleFactor(0.85)
                        .accessibilityLabel("教室 \(location)")
                }
            }
            .multilineTextAlignment(.leading)
            .foregroundStyle(accent)
            .padding(.horizontal, compact ? 4 : 7)
            .padding(.vertical, shortCard ? 4 : 6)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }

    /// 教室名统一由卡片加「@」前缀；先去掉部分学校数据里自带的 @/＠，避免显示成「@@」。
    private var displayLocation: String? {
        guard let location = clean(course.location)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "@＠").union(.whitespaces)),
            !location.isEmpty else { return nil }
        return location
    }

    private var swatch: ScheduleCourseTint.Swatch {
        ScheduleCourseTint.swatch(for: course.name, solid: themeSettings.solidCourseColor)
    }

    private var accent: Color {
        swatch.accent(scheme: colorScheme)
    }

    private var hue: Double { swatch.hue }

    private var saturation: Double { swatch.saturation }

    private var courseFill: Color {
        if completedAppearance {
            return ScheduleCourseTint.color(
                hue: hue,
                saturation: min(0.08, saturation),
                lightness: colorScheme == .dark ? 0.5 : 0.95
            ).opacity(colorScheme == .dark ? 0.12 : (hasBackground ? 0.92 : 1))
        }
        return Self.fill(for: swatch, dark: colorScheme == .dark, hasBackground: hasBackground)
    }

    private var completedAppearance: Bool { timeline && isCompleted }

    private var courseBorder: Color {
        if completedAppearance { return Color.secondary.opacity(0.12) }
        if colorScheme == .dark {
            return ScheduleCourseTint.color(
                hue: hue,
                saturation: min(0.5, saturation),
                lightness: 0.70
            ).opacity(0.34)
        }
        return ScheduleCourseTint.color(
            hue: hue,
            saturation: min(0.5, saturation),
            lightness: 0.55
        ).opacity(0.22)
    }

    /// 浅色是一块不透明的淡彩；深色用半透明的课程色压在黑底上，文字再用亮一档
    /// 的同色，和系统日历的深色事件一个思路。月视图的当天列表也用这一块底。
    static func fill(for swatch: ScheduleCourseTint.Swatch, dark: Bool, hasBackground: Bool = false) -> Color {
        let saturation = min(0.45, swatch.saturation)
        if dark {
            return ScheduleCourseTint.color(hue: swatch.hue, saturation: saturation, lightness: 0.5).opacity(0.22)
        }
        return ScheduleCourseTint.color(hue: swatch.hue, saturation: saturation, lightness: max(0.93, swatch.backgroundLightness))
            .opacity(hasBackground ? 0.92 : 1)
    }

    private func hslColor(hue: Double, saturation: Double, lightness: Double) -> Color {
        ScheduleCourseTint.color(hue: hue, saturation: saturation, lightness: lightness)
    }

    private func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
