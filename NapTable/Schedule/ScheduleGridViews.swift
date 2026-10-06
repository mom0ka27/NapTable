import SwiftUI

struct NativeScheduleDayColumn: View {
    @Environment(\.scheduleStyle) private var style
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scheduleStaticRendering) private var staticRendering
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
    /// 这一天的调休。有值时表头右上角显示「休」/「班」角标。
    let adjustment: ResolvedCalendarAdjustment?
    let columnWidth: CGFloat
    let rowHeight: CGFloat
    /// 画到第几节。晚上没课的行可以收起来，见 `NativeSchedulePreferences.hideSlotsAfter`。
    var slotCount: Int = ScheduleSlot.all.count
    /// 这一天的作息，读屏标签里报上课时间用。
    var clocks: [ScheduleSlot] = ScheduleSlot.all
    let compactCards: Bool
    let showsDateHeader: Bool
    /// 共享课表只读：卡片不提供「修改课程」，空节次也不报「长按添加」。
    var isEditable = true
    let blocks: [NativeScheduleCourseBlock]
    /// 长按课程：自己的课表进入编辑。
    let onCourseSelected: (NativeScheduleCourseBlock) -> Void
    /// 轻点课程：打开课程速览。
    var onCoursePreview: (NativeScheduleCourseBlock) -> Void = { _ in }
    let onEmptySlot: (Int) -> Void
    var nowMinutes: Int? = nil
    var dayPresentation = false
    var completedBeforeMinutes: Int? = nil

    /// 分享图不标今天，见 `scheduleStaticRendering`。
    private var marksToday: Bool { isToday && !staticRendering }

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
        if style == .minimal { minimalBody } else { styledBody }
    }

    private var minimalBody: some View {
        VStack(spacing: 0) {
            if showsDateHeader {
                // 和日视图星期条同一个写法：几号在上、星期在下，今天写「今天」。
                VStack(spacing: 3) {
                    Text(headerDateText ?? dateText ?? "–")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(marksToday ? AnyShapeStyle(.themeText) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: max(0, columnWidth - 6))
                    Text(marksToday ? "今天" : dayLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(marksToday ? AnyShapeStyle(.themeText) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                // 为角标留出顶部空间，窄列里的月初日期也不会与它重叠。
                .padding(.top, ScheduleAdjustmentBadge.size)
                // 星期表头不加框，直接把字放在底色上；今天靠主题色文字和整列淡底标出来。
                .frame(width: columnWidth, height: Self.dateHeaderHeight)
                .overlay(alignment: .topTrailing) {
                    if let adjustment {
                        ScheduleAdjustmentBadge(adjustment: adjustment)
                            .padding(.trailing, 2)
                    }
                }
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
                            // 被课程盖住的节次读屏直接跳过，读到的是上面那张卡片；
                            // 只读的共享课表里空节次没有可做的事，也不读。
                            .accessibilityHidden(occupied || !isEditable)
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
                        // 轻点看速览，长按进编辑；读屏双击走默认动作打开速览，修改放在操作里。
                        .modifier(ScheduleCourseInteraction(
                            cornerRadius: NativeScheduleCourseCard.gridCornerRadius,
                            isEditable: isEditable,
                            onPreview: { onCoursePreview(block) },
                            onEdit: { onCourseSelected(block) }
                        ))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(courseAccessibilityLabel(block))
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
            if marksToday {
                // 今天整列用柔和的主题色底，深浅模式都清晰可见
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.themeTint(ThemePalette.Surface.todayStrength(dark: colorScheme == .dark)))
                    .allowsHitTesting(false)
            }
        }
    }

    private var styledBody: some View {
        VStack(spacing: 0) {
            if showsDateHeader {
                ScheduleStyledDateHeader(day: day, date: headerDateText ?? dateText ?? "–",
                                         isToday: marksToday, adjustment: adjustment)
                    .frame(width: columnWidth, height: Self.dateHeaderHeight)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(headerAccessibilityLabel)
            }
            ZStack(alignment: .topLeading) {
                styledEmptyCells
                // 只有格子把「现在」线压在课程块下面、从空格子里露出来；其他风格由课表页画在
                // 课程上方，这里再画一条就成了两条。
                if style == .grid, let nowMinutes, !staticRendering, marksToday,
                   let now = styledNow(nowMinutes) {
                    ForEach(Array(styledNowSegments(now.slots).enumerated()), id: \.offset) { _, segment in
                        Rectangle().fill(.themeText).frame(width: segment.width, height: 1.5)
                            .offset(x: segment.x, y: now.y).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                ForEach(blocks) { block in styledCourse(block) }
            }
            .frame(width: columnWidth, height: columnHeight)
        }
        .frame(width: columnWidth)
        .background {
            if style == .table && day >= 6 { Color.primary.opacity(0.035) }
        }
    }

    private var styledEmptyCells: some View {
        let rows = Array(clocks.prefix(slotCount))
        let laneCounts = clusterLaneCounts
        return VStack(spacing: style == .table ? 0 : Self.slotGap) {
            ForEach(rows) { slot in
                let covering = blocks.filter { $0.startSlot <= slot.number && slot.number <= $0.endSlot }
                let occupied = !covering.isEmpty
                // 并排的课没占满这一格的宽度时，空着的那一半还要露出格子。
                let covered = occupied && Set(covering.map(\.lane)).count >= (laneCounts[covering[0].id] ?? 1)
                let previous = rows.first { $0.number == slot.number - 1 }
                ScheduleStyledWeekCell(today: marksToday, holiday: adjustment?.kind == .off,
                    startsSession: previous.map { ScheduleStyleTime.session($0.start) != ScheduleStyleTime.session(slot.start) } ?? true,
                    covered: covered, joinsBelow: covering.contains { $0.endSlot > slot.number })
                    .frame(width: columnWidth, height: rowHeight + (style == .table && slot.number != rows.last?.number ? Self.slotGap : 0))
                    .contentShape(Rectangle())
                    .modifier(ScheduleEmptySlotInteraction(slot: slot.number, isEditable: isEditable && !occupied, onAdd: onEmptySlot))
                    .accessibilityHidden(occupied || !isEditable)
            }
        }
    }

    private func styledCourse(_ block: NativeScheduleCourseBlock) -> some View {
        let lanes = clusterLaneCounts[block.id] ?? 1
        // 格子：课程块就是那一格，和旁边的空格子一样大，并排的课之间才留缝。
        // 表格：贴着格线填满单元格。其余风格四周留 1pt。
        let inset: CGFloat = style == .table ? 0.5 : (style == .grid && lanes == 1 ? 0 : 1)
        let status = ScheduleStyledDayStatus(clocks: clocks, now: staticRendering ? nil : nowMinutes,
                                             completedBefore: staticRendering ? nil : completedBeforeMinutes)
        // 表格的行线画在每一节顶上，课程块要越过行距贴到下一条线；最后一节下面没有行距。
        let reach = style == .table && block.endSlot < slotCount ? Self.slotGap : 0
        let height = CGFloat(block.endSlot - block.startSlot + 1) * rowHeight
            + CGFloat(block.endSlot - block.startSlot) * Self.slotGap + reach - inset * 2
        return ZStack(alignment: .trailing) {
            ScheduleStyledCourseTile(course: block.course, compact: compactCards || columnWidth / CGFloat(lanes) < 70,
                                     start: clocks.first { $0.number == block.startSlot }?.start,
                                     current: status.phase(block) == .current,
                                     trailingInset: dayPresentation && lanes == 1 && status.label(block) != nil ? 80 : 0)
            if dayPresentation, lanes == 1, let label = status.label(block) {
                Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.themeText)
                    .multilineTextAlignment(.trailing).frame(width: 76).padding(.trailing, 4)
            }
        }
        .frame(width: max(12, columnWidth / CGFloat(lanes) - inset * 2), height: max(34, height))
        .contentShape(Rectangle())
        .modifier(ScheduleCourseInteraction(cornerRadius: style.layout.cornerRadius, isEditable: isEditable,
                  onPreview: { onCoursePreview(block) }, onEdit: { onCourseSelected(block) }))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(courseAccessibilityLabel(block) + (status.label(block).map { "，" + $0 } ?? ""))
        .offset(x: inset + CGFloat(block.lane) * columnWidth / CGFloat(lanes),
                y: CGFloat(block.startSlot - 1) * (rowHeight + Self.slotGap) + inset)
    }

    /// 「现在」线的纵向位置，以及它落在哪几节上：上课时是那一节，课间是前后两节。
    private func styledNow(_ current: Int) -> (y: CGFloat, slots: ClosedRange<Int>)? {
        for (index, slot) in clocks.prefix(slotCount).enumerated() {
            guard let start = scheduleClockMinutes(slot.start), let end = scheduleClockMinutes(slot.end), end > start else { continue }
            if current < start {
                return index == 0 ? nil : (CGFloat(index) * (rowHeight + Self.slotGap) - Self.slotGap / 2, (slot.number - 1)...slot.number)
            }
            // 下课那一分钟仍停在这一节底部，和节次轴上的时间胶囊（`nowOffset`）同一个位置。
            if current <= end {
                return (CGFloat(index) * (rowHeight + Self.slotGap) + rowHeight * CGFloat(current - start) / CGFloat(end - start),
                        slot.number...slot.number)
            }
        }
        return nil
    }

    /// 「现在」线只画在没被课程盖住的地方：深色的课程底色是半透明的，线从课程块下面穿过去
    /// 会透上来压住课名。并排的课没占满时，空着的那几列照常画。
    private func styledNowSegments(_ slots: ClosedRange<Int>) -> [(x: CGFloat, width: CGFloat)] {
        let covering = blocks.filter { $0.startSlot <= slots.lowerBound && slots.upperBound <= $0.endSlot }
        guard let first = covering.first else { return [(0, columnWidth)] }
        let lanes = clusterLaneCounts[first.id] ?? 1
        let width = columnWidth / CGFloat(lanes)
        return (0..<lanes).filter { lane in !covering.contains { $0.lane == lane } }
            .map { (CGFloat($0) * width, width) }
    }

    private var dayLabel: String { ScheduleCourseTimeText.weekday(day) }

    /// 「高等数学，教室 A101，周一 第1–2节 08:00 至 09:40」。
    private func courseAccessibilityLabel(_ block: NativeScheduleCourseBlock) -> String {
        let time = ScheduleCourseTimeText(day: day, block: block, clocks: clocks)
        return [block.course.name,
                NativeScheduleCourseCard.displayLocation(block.course.location).map { "教室 \($0)" },
                time.spoken]
            .compactMap { $0 }
            .joined(separator: "，")
    }
}

/// 一门课这一次在哪天、哪几节、几点。课程速览的第二行和周视图卡片的读屏标签共用。
struct ScheduleCourseTimeText {
    let weekday: String
    let startSlot: Int
    let endSlot: Int
    let start: String?
    let end: String?

    init(day: Int, block: NativeScheduleCourseBlock, clocks: [ScheduleSlot]) {
        weekday = Self.weekday(day)
        startSlot = block.startSlot
        endSlot = block.endSlot
        start = clocks.first { $0.number == block.startSlot }?.start
        end = clocks.first { $0.number == block.endSlot }?.end
    }

    static func weekday(_ day: Int) -> String {
        let labels = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        return labels.indices.contains(day - 1) ? labels[day - 1] : "周\(day)"
    }

    /// 「周一 · 第 1–2 节 · 08:00–09:40」
    var display: String {
        let slots = startSlot == endSlot ? "第 \(startSlot) 节" : "第 \(startSlot)–\(endSlot) 节"
        let time = start.flatMap { start in end.map { "\(start)–\($0)" } }
        return [weekday, slots, time].compactMap { $0 }.joined(separator: " · ")
    }

    /// 「周一 第1–2节 08:00 至 09:40」：时间和其他读屏标签一样写「至」。
    var spoken: String {
        let slots = startSlot == endSlot ? "第\(startSlot)节" : "第\(startSlot)–\(endSlot)节"
        let time = start.flatMap { start in end.map { "\(start) 至 \($0)" } }
        return [weekday, slots, time].compactMap { $0 }.joined(separator: " ")
    }
}

/// 「08:00」→ 480。解析不了返回 nil。
func scheduleClockMinutes(_ value: String) -> Int? {
    let parts = value.split(separator: ":").compactMap { Int($0) }
    return parts.count >= 2 ? parts[0] * 60 + parts[1] : nil
}

/// 日期旁边的调休角标：放假「休」，调课「班」。周视图表头、日视图星期条、月历和
/// 当天安排共用这一个。不透明实色底配白字，深浅模式同色，白字对比度 4.70:1 / 5.18:1。
struct ScheduleAdjustmentBadge: View {
    static let size: CGFloat = 12
    /// 放假「休」的底色 #E11D48。
    static let offColor = Color(red: 0xE1 / 255, green: 0x1D / 255, blue: 0x48 / 255)
    /// 调课「班」的底色 #C2410C。
    static let swapColor = Color(red: 0xC2 / 255, green: 0x41 / 255, blue: 0x0C / 255)

    let adjustment: ResolvedCalendarAdjustment

    var body: some View {
        Text(adjustment.badge)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .fixedSize()
            .frame(width: Self.size, height: Self.size, alignment: .center)
            // 小字号汉字做光学居中，仅移动文字，不移动底色。
            .offset(x: 0.2)
            .background(
                adjustment.kind == .off ? Self.offColor : Self.swapColor,
                in: RoundedRectangle(cornerRadius: 3, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

/// 三种视图共用：轻点速览，长按编辑；共享课表长按仍打开只读速览。
struct ScheduleCourseInteraction: ViewModifier {
    var cornerRadius: CGFloat = 9
    var isEditable = true
    let onPreview: () -> Void
    let onEdit: () -> Void

    func body(content: Content) -> some View {
        content
            .modifier(ScheduleLongPressFeedback(
                cornerRadius: cornerRadius,
                pressedScale: 1.10,
                onTap: onPreview,
                action: isEditable ? onEdit : onPreview
            ))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(isEditable ? "轻点查看课程详情，长按修改课程" : "查看课程详情")
            .accessibilityAction { onPreview() }
            .accessibilityActions {
                if isEditable { Button("修改课程", action: onEdit) }
            }
    }
}

/// 按下立即显示反馈；只有长按成功时才震动，滚动或提前松手不会触发。
/// 传了 `onTap` 时轻点也有反应；已经触发长按的那一次按压，松手不再算轻点。
struct ScheduleLongPressFeedback: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPressed = false
    @State private var feedbackTrigger = 0
    @State private var didLongPress = false

    var cornerRadius: CGFloat = 8
    var pressedScale: CGFloat = 1.04
    var onTap: (() -> Void)? = nil
    let action: () -> Void

    func body(content: Content) -> some View {
        let pressable = content
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
                didLongPress = true
                feedbackTrigger += 1
                action()
            } onPressingChanged: { pressing in
                if pressing { didLongPress = false }
                isPressed = pressing
            }
        Group {
            if let onTap {
                // 轻点和长按同时识别，不分先后，长按照旧不挡滚动；长按过的那次松手靠 didLongPress 丢掉。
                pressable.simultaneousGesture(TapGesture().onEnded {
                    guard !didLongPress else {
                        didLongPress = false
                        return
                    }
                    onTap()
                })
            } else {
                pressable
            }
        }
        #if os(iOS)
        .sensoryFeedback(.impact(weight: .heavy, intensity: 1), trigger: feedbackTrigger)
        #endif
    }
}



/// 只按课程起始时间排列，不为空节次预留网格。同一时刻的课共用一个时间节点。
struct NativeScheduleDayTimeline: View {
    @Environment(\.scheduleStyle) private var style
    @Environment(\.scheduleStaticRendering) private var staticRendering
    /// 标准字号下的卡片高度。课表页按系统字号缩放，分享图固定用这个值。
    static let standardCardHeight: CGFloat = 108

    let blocks: [NativeScheduleCourseBlock]
    let clocks: [ScheduleSlot]
    /// 星期几（1–7）。格子风格的读屏标签报「周三 第1–2节」时用。
    var day: Int = 1
    /// 没课时空状态下面的一行说明，比如调休的「国庆节放假」。
    var emptyNote: String? = nil
    var holidayGreeting: String? = nil
    /// 今天才有值：课表时区下零点起的分钟数，用来标出正在上和下一节。
    var nowMinutes: Int? = nil
    /// 用于已结束卡片的判断，也适用于过去日期和关闭「现在」指示器时。
    var completedBeforeMinutes: Int? = nil
    var cardHeight: CGFloat = NativeScheduleDayTimeline.standardCardHeight
    /// 日视图传入可见区域高度；分享图沿用内容本身的高度。
    var emptyHeight: CGFloat = 0
    var isEditable = true
    let onCourseSelected: (NativeScheduleCourseBlock) -> Void
    var onCoursePreview: (NativeScheduleCourseBlock) -> Void = { _ in }

    var slotCount: Int = ScheduleSlot.all.count
    var onEmptySlot: (Int) -> Void = { _ in }

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
        guard let now = nowMinutes, !staticRendering else { return groups.map { _ in .none } }
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
        guard let now = nowMinutes, !staticRendering else { return nil }
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
        if style == .minimal { minimalBody } else {
            ScheduleStyledDayView(day: day, blocks: blocks, clocks: clocks, slotCount: slotCount,
                nowMinutes: nowMinutes, completedBeforeMinutes: completedBeforeMinutes, cardHeight: cardHeight,
                emptyNote: emptyNote, holidayGreeting: holidayGreeting, emptyHeight: emptyHeight,
                isEditable: isEditable, onCourseSelected: onCourseSelected, onCoursePreview: onCoursePreview,
                onEmptySlot: onEmptySlot)
        }
    }

    @ViewBuilder
    private var minimalBody: some View {
        if blocks.isEmpty {
            ScheduleEmptyDayView(
                note: emptyNote,
                holidayGreeting: holidayGreeting,
                dayPresentation: emptyHeight > 0
            )
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
                                .foregroundStyle(startStyle(phase))
                            // 上完的课靠节点和开始时间区分，结束时间不再调淡。
                            Text(endTime(endSlot))
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.scheduleMeta)
                            if let status = statusText(phase) {
                                Text(status)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.themeText)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(.themeTint(0.12), in: Capsule())
                                    .padding(.top, 2)
                            } else {
                                Text(slotRange(startSlot, endSlot))
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.scheduleMeta)
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
                                .modifier(ScheduleCourseInteraction(
                                    cornerRadius: 20,
                                    isEditable: isEditable,
                                    onPreview: { onCoursePreview(block) },
                                    onEdit: { onCourseSelected(block) }
                                ))
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
                                .fill(.themeText.opacity(0.6))
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
                                    .fill(.themeText)
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

    private func startStyle(_ phase: Phase) -> AnyShapeStyle {
        switch phase {
        case .current, .next: AnyShapeStyle(.themeText)
        case .past: AnyShapeStyle(.scheduleMeta)
        case .none: AnyShapeStyle(Color.primary)
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
                    Circle().fill(.themeTint(0.2))
                    Circle().fill(.themeFill).frame(width: Self.diameter(for: phase), height: Self.diameter(for: phase))
                case .next:
                    Circle().strokeBorder(.themeText, lineWidth: 1.5).frame(width: Self.diameter(for: phase), height: Self.diameter(for: phase))
                case .past:
                    Circle().fill(.themeText.opacity(0.6)).frame(width: Self.diameter(for: phase), height: Self.diameter(for: phase))
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
        guard !staticRendering, let minutes = completedBeforeMinutes ?? nowMinutes,
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
    @Environment(\.scheduleStyle) private var style
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
        if style == .minimal { minimalBody } else {
            ScheduleStyledCourseTile(course: course, compact: compact)
        }
    }

    private var minimalBody: some View {
        Group {
            if timeline {
                VStack(alignment: .leading, spacing: 7) {
                    Text(course.name)
                        .font(.headline.weight(completedAppearance ? .medium : .semibold))
                        .foregroundStyle(accent)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .layoutPriority(1)
                        .padding(.trailing, completedAppearance ? 26 : 0)
                    if let location = displayLocation {
                        Text("@\(location)")
                            .font(.footnote)
                            .foregroundStyle(accent)
                            .lineLimit(1)
                            .accessibilityLabel("教室 \(location)")
                    }
                    if let slotLabel {
                        // 节次和时间是要读的信息：不再压低透明度，上完的课也只退到次要元信息灰。
                        Text(slotLabel)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(completedAppearance ? AnyShapeStyle(.scheduleMeta) : AnyShapeStyle(accent))
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

                // 教室和课名同色，层级只靠字号和字重拉开，不再调透明度。
                if let location {
                    Text("@\(location)")
                        .font(.system(size: small ? 9 : 11, weight: .medium))
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

    private var displayLocation: String? { Self.displayLocation(course.location) }

    /// 教室名统一由卡片加「@」前缀；先去掉部分学校数据里自带的 @/＠，避免显示成「@@」。
    /// 周视图卡片的读屏标签和课程速览也按这个写法取教室。
    static func displayLocation(_ raw: String?) -> String? {
        guard let location = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
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
        // 周、日视图共享课程底色；已结束状态由勾号和时间轴表达。
        Self.fill(for: swatch, dark: colorScheme == .dark, hasBackground: hasBackground)
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
}
