import SwiftUI

/// Four distinct day layouts, sharing the existing course callbacks and resolved bell schedule.
struct ScheduleStyledDayView: View {
    @Environment(\.scheduleStyle) private var style
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scheduleStaticRendering) private var staticRendering
    /// Weekday (1–7) of the page, so the grid column's VoiceOver labels name the right day.
    let day: Int
    let blocks: [NativeScheduleCourseBlock]
    let clocks: [ScheduleSlot]
    let slotCount: Int
    let nowMinutes: Int?
    let completedBeforeMinutes: Int?
    let cardHeight: CGFloat
    let emptyNote: String?
    let holidayGreeting: String?
    let emptyHeight: CGFloat
    let isEditable: Bool
    let onCourseSelected: (NativeScheduleCourseBlock) -> Void
    let onCoursePreview: (NativeScheduleCourseBlock) -> Void
    let onEmptySlot: (Int) -> Void

    private var visibleClocks: [ScheduleSlot] { Array(clocks.prefix(slotCount)) }
    private var status: ScheduleStyledDayStatus {
        .init(clocks: clocks, now: staticRendering ? nil : nowMinutes,
              completedBefore: staticRendering ? nil : completedBeforeMinutes)
    }

    /// Paper and board show the shared rest card on a free day, and the card already carries the note.
    private var showsRestCard: Bool { blocks.isEmpty && (style == .paper || style == .board) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let emptyNote, !showsRestCard {
                Text(emptyNote).font(.caption).foregroundStyle(.scheduleMeta).padding(.bottom, 12)
            }
            switch style {
            case .grid: grid
            case .table: table
            case .paper, .board:
                if blocks.isEmpty {
                    ScheduleEmptyDayView(note: emptyNote, holidayGreeting: holidayGreeting, dayPresentation: emptyHeight > 0)
                        .frame(height: max(emptyHeight, 220))
                        .modifier(ScheduleHolidayFireworks())
                } else if style == .paper {
                    paper
                } else {
                    board
                }
            case .minimal: EmptyView()
            }
        }
    }

    /// Height must match the rows used here: the outer horizontal pager has a fixed cross axis.
    static func height(style: ScheduleStyle, blocks: [NativeScheduleCourseBlock], clocks: [ScheduleSlot],
                       slotCount: Int, cardHeight: CGFloat, hasNote: Bool = false) -> CGFloat {
        let note: CGFloat = hasNote ? 42 : 0
        let rows = Array(clocks.prefix(slotCount))
        switch style {
        case .grid:
            return note + CGFloat(rows.count) * gridRowHeight(cardHeight) + CGFloat(max(0, rows.count - 1)) * NativeScheduleDayColumn.slotGap
        case .table:
            return note + 32 + rows.reduce(CGFloat(0)) { value, slot in
                value + CGFloat(max(1, blocks.filter { $0.startSlot <= slot.number && slot.number <= $0.endSlot }.count)) * tableRowHeight(cardHeight)
            }
        case .paper, .board:
            if blocks.isEmpty { return max(220, cardHeight * 2) }
            // At most three time-of-day / status sections, including their headings and separators.
            return note + CGFloat(blocks.count) * cardHeight + 3 * 48 + 32
        case .minimal: return NativeScheduleDayTimeline.height(blocks: blocks, cardHeight: cardHeight)
        }
    }

    private static func gridRowHeight(_ cardHeight: CGFloat) -> CGFloat { max(48, cardHeight * 0.52) }
    private static func tableRowHeight(_ cardHeight: CGFloat) -> CGFloat { max(58, cardHeight * 0.60) }

    private var grid: some View {
        let height = Self.gridRowHeight(cardHeight)
        return GeometryReader { geometry in
            HStack(alignment: .top, spacing: 8) {
                VStack(spacing: NativeScheduleDayColumn.slotGap) {
                    ForEach(visibleClocks) { slot in
                        ScheduleStyledSlotLabel(slot: slot).frame(width: 48, height: height)
                    }
                }
                NativeScheduleDayColumn(
                    day: day, dateText: nil, isToday: nowMinutes != nil, adjustment: nil,
                    columnWidth: max(24, geometry.size.width - 56), rowHeight: height,
                    slotCount: visibleClocks.count, clocks: clocks, compactCards: false,
                    showsDateHeader: false, isEditable: isEditable, blocks: blocks,
                    onCourseSelected: onCourseSelected, onCoursePreview: onCoursePreview, onEmptySlot: onEmptySlot,
                    nowMinutes: status.now, dayPresentation: true, completedBeforeMinutes: status.completedBefore
                )
            }
        }
        .frame(height: CGFloat(visibleClocks.count) * height + CGFloat(max(0, visibleClocks.count - 1)) * NativeScheduleDayColumn.slotGap)
    }

    private var table: some View {
        VStack(spacing: 0) {
            ScheduleDayTableHeading()
            ForEach(visibleClocks) { slot in
                ScheduleDayTableRow(
                    slot: slot, blocks: blocks.filter { $0.startSlot <= slot.number && slot.number <= $0.endSlot },
                    rowHeight: Self.tableRowHeight(cardHeight), status: status, isEditable: isEditable,
                    showsBottomRule: slot.number != visibleClocks.last?.number,
                    onCourseSelected: onCourseSelected, onCoursePreview: onCoursePreview, onEmptySlot: onEmptySlot
                )
            }
        }
        // The frame is stroked on top: course rows fill their cells edge to edge and would paint
        // over a border drawn underneath them.
        .background { ScheduleSurface(cornerRadius: 0, isPanel: true, showsBorder: false) }
        .overlay {
            Rectangle().strokeBorder(Color.scheduleCellBorder(dark: scheme == .dark), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
    }

    private var paper: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(["上午", "下午", "晚上", "课程"], id: \.self) { session in
                let courses = orderedBlocks.filter { block in
                    ScheduleStyleTime.session(status.start(block)) == session
                }
                if !courses.isEmpty { courseSection(session, courses: courses) }
            }
        }
        .padding(12)
        .background { ScheduleSurface(cornerRadius: 2, isPanel: true) }
    }

    private var board: some View {
        let current = orderedBlocks.filter { status.phase($0) == .current }
        let future = orderedBlocks.filter { status.phase($0) == .upcoming }
        let completed = orderedBlocks.filter { status.phase($0) == .completed }
        return VStack(alignment: .leading, spacing: 0) {
            if !current.isEmpty { courseSection("正在上", courses: current) }
            if !future.isEmpty { courseSection(status.now == nil ? "课程安排" : "接下来", courses: future) }
            if !completed.isEmpty { courseSection("已结束", courses: completed) }
        }
        .padding(.vertical, 8)
        .background { ScheduleSurface(cornerRadius: 0, isPanel: true) }
    }

    private var orderedBlocks: [NativeScheduleCourseBlock] {
        blocks.sorted { ($0.startSlot, $0.endSlot, $0.id) < ($1.startSlot, $1.endSlot, $1.id) }
    }

    private func courseSection(_ title: String, courses: [NativeScheduleCourseBlock]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScheduleDaySectionHeading(title: title).frame(height: 40)
            ForEach(courses) { block in
                ScheduleStyledDepartureRow(block: block, status: status)
                    .frame(height: cardHeight)
                    .modifier(ScheduleCourseInteraction(
                        cornerRadius: 2, isEditable: isEditable,
                        onPreview: { onCoursePreview(block) }, onEdit: { onCourseSelected(block) }
                    ))
            }
        }
    }
}

struct ScheduleStyledDayStatus {
    enum Phase { case current, upcoming, completed }
    let clocks: [ScheduleSlot]
    let now: Int?
    let completedBefore: Int?

    func start(_ block: NativeScheduleCourseBlock) -> String { clocks.first { $0.number == block.startSlot }?.start ?? "—" }
    func end(_ block: NativeScheduleCourseBlock) -> String { clocks.first { $0.number == block.endSlot }?.end ?? "—" }
    func phase(_ block: NativeScheduleCourseBlock) -> Phase {
        guard let end = scheduleClockMinutes(end(block)), let start = scheduleClockMinutes(start(block)) else { return .upcoming }
        if let limit = completedBefore ?? now, end <= limit { return .completed }
        if let now, start <= now && now < end { return .current }
        return .upcoming
    }
    func label(_ block: NativeScheduleCourseBlock) -> String? {
        switch phase(block) {
        case .completed: return "已结束"
        case .current:
            let remaining = (scheduleClockMinutes(end(block)) ?? 0) - (now ?? 0)
            return "正在上 · 还剩 \(max(1, remaining)) 分"
        case .upcoming:
            guard let now, let start = scheduleClockMinutes(start(block)), start > now else { return nil }
            return start - now < 60 ? "\(start - now) 分钟后" : nil
        }
    }
}

private struct ScheduleDayTableHeading: View {
    var body: some View {
        HStack(spacing: 0) {
            Text("节").frame(width: 28)
            Text("时间").frame(width: 58)
            Text("课程").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8)
            // Same 6pt inset as the room text in the rows below.
            Text("教室").padding(.leading, 6).frame(width: 80, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .frame(height: 32)
        .background(Color.primary.opacity(0.06))
    }
}

private struct ScheduleDayTableRow: View {
    @Environment(\.colorScheme) private var scheme
    let slot: ScheduleSlot
    let blocks: [NativeScheduleCourseBlock]
    let rowHeight: CGFloat
    let status: ScheduleStyledDayStatus
    let isEditable: Bool
    /// The last row sits on the table frame, which already closes it.
    var showsBottomRule = true
    let onCourseSelected: (NativeScheduleCourseBlock) -> Void
    let onCoursePreview: (NativeScheduleCourseBlock) -> Void
    let onEmptySlot: (Int) -> Void

    private var rule: Color { .scheduleCellBorder(dark: scheme == .dark) }
    var body: some View {
        HStack(spacing: 0) {
            Text(String(slot.number)).font(.caption.bold()).frame(width: 28)
            Rectangle().fill(rule).frame(width: 0.5)
            VStack(spacing: 3) {
                Text(slot.start)
                Text(slot.end)
            }
            .font(.system(size: 10, design: .monospaced))
            // 28 + 0.5 + 57 + 0.5 = the heading's 28 + 58, so the course column starts under its title.
            .frame(width: 57)
            Rectangle().fill(rule).frame(width: 0.5)
            if blocks.isEmpty {
                HStack(spacing: 0) {
                    Text("—").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8)
                    Rectangle().fill(rule).frame(width: 0.5)
                    Text("—").padding(.leading, 6).frame(width: 79.5, alignment: .leading)
                }
                .contentShape(Rectangle())
                .modifier(ScheduleEmptySlotInteraction(slot: slot.number, isEditable: isEditable, onAdd: onEmptySlot))
            } else {
                VStack(spacing: 0) {
                    ForEach(blocks) { block in
                        ScheduleDayTableCourse(block: block, status: status, continuation: slot.number > block.startSlot)
                            .frame(height: rowHeight)
                            .modifier(ScheduleCourseInteraction(
                                cornerRadius: 0, isEditable: isEditable,
                                onPreview: { onCoursePreview(block) }, onEdit: { onCourseSelected(block) }
                            ))
                    }
                }
            }
        }
        .frame(height: CGFloat(max(1, blocks.count)) * rowHeight)
        .overlay(alignment: .bottom) {
            if showsBottomRule { Rectangle().fill(rule).frame(height: 0.5) }
        }
    }
}

private struct ScheduleDayTableCourse: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var theme = NativeThemeSettings.shared
    let block: NativeScheduleCourseBlock
    let status: ScheduleStyledDayStatus
    let continuation: Bool

    var body: some View {
        let swatch = ScheduleCourseTint.swatch(for: block.course.name, solid: theme.solidCourseColor)
        let ink = swatch.accent(scheme: scheme)
        HStack(spacing: 0) {
            Rectangle().fill(ink).frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(block.course.name).font(.subheadline.weight(.semibold)).lineLimit(2).minimumScaleFactor(0.8)
                // The status belongs to the course, so it is written once, on its first period.
                if continuation {
                    Text("续课").font(.caption2)
                } else if let label = status.label(block) {
                    Text(label).font(.caption2).lineLimit(1)
                }
            }
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(.scheduleCellBorder(dark: scheme == .dark)).frame(width: 0.5)
            Text(NativeScheduleCourseCard.displayLocation(block.course.location) ?? "—")
                .font(.caption).lineLimit(3).minimumScaleFactor(0.8)
                .frame(width: 67.5, alignment: .leading).padding(.horizontal, 6)
        }
        .foregroundStyle(ink)
        .background(NativeScheduleCourseCard.fill(for: swatch, dark: scheme == .dark))
        .accessibilityElement(children: .combine)
        .accessibilityLabel([block.course.name, block.course.location, "\(status.start(block)) 至 \(status.end(block))", status.label(block)].compactMap { $0 }.joined(separator: "，"))
    }
}

private struct ScheduleDaySectionHeading: View {
    @Environment(\.scheduleStyle) private var style
    @Environment(\.colorScheme) private var scheme
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 13, weight: .bold, design: style.fontDesign))
            Rectangle().fill(style.inkColor(dark: scheme == .dark).opacity(style == .board ? 0.6 : 0.2))
                .frame(height: style == .board ? 2 : 0.5)
        }
        .foregroundStyle(style.inkColor(dark: scheme == .dark))
        .padding(.horizontal, 12)
    }
}

private struct ScheduleStyledDepartureRow: View {
    @Environment(\.scheduleStyle) private var style
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var theme = NativeThemeSettings.shared
    let block: NativeScheduleCourseBlock
    let status: ScheduleStyledDayStatus

    private var dark: Bool { scheme == .dark }
    private var inverse: Bool { style == .board && status.phase(block) == .current }
    private var ink: Color { inverse ? (style.canvasColor(dark: dark) ?? .white) : style.inkColor(dark: dark) }
    private var accent: Color { style.styleAccent(dark: dark, fallback: .primary) }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(status.start(block)).font(.system(size: style == .board ? 24 : 20, weight: .bold, design: style.fontDesign))
                Text(status.end(block)).font(.system(size: 12, design: style.fontDesign))
            }
            .lineLimit(1).minimumScaleFactor(0.7).frame(width: style == .board ? 82 : 64, alignment: .leading)
            Rectangle()
                .fill(ScheduleCourseTint.accent(for: block.course.name, scheme: scheme, solid: theme.solidCourseColor))
                .frame(width: 2).padding(.vertical, 16)
            VStack(alignment: .leading, spacing: 5) {
                Text(block.course.name).font(.headline.weight(.semibold)).lineLimit(2).minimumScaleFactor(0.8)
                if let location = NativeScheduleCourseCard.displayLocation(block.course.location) {
                    Text("@\(location)").font(.subheadline).lineLimit(1)
                }
                Text("第 \(block.startSlot)\(block.startSlot == block.endSlot ? "" : "–\(block.endSlot)") 节")
                    .font(.caption2)
                if let label = status.label(block) {
                    Text(label).font(.caption.weight(.semibold)).foregroundStyle(inverse ? ink : accent)
                        .lineLimit(1).minimumScaleFactor(0.75)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fontDesign(style.fontDesign)
        .foregroundStyle(ink)
        .padding(.horizontal, 12)
        .background(inverse ? style.inkColor(dark: dark) : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(ink.opacity(0.15)).frame(height: 0.5) }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Read-only schedules expose neither a gesture nor an add action on empty periods.
struct ScheduleEmptySlotInteraction: ViewModifier {
    let slot: Int
    let isEditable: Bool
    let onAdd: (Int) -> Void
    func body(content: Content) -> some View {
        content
            .modifier(ScheduleLongPressFeedback { if isEditable { onAdd(slot) } })
            .allowsHitTesting(isEditable)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("第 \(slot) 节，空节次")
            .accessibilityHint(isEditable ? "长按添加课程" : "")
            .accessibilityAddTraits(isEditable ? .isButton : [])
            .accessibilityAction { if isEditable { onAdd(slot) } }
    }
}
