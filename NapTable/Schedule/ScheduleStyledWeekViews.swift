import SwiftUI

/// Style-only helpers; calendar resolution, course lanes and permissions remain in the surface.
enum ScheduleStyleTime {
    static func session(_ start: String) -> String {
        guard let minutes = scheduleClockMinutes(start) else { return "课程" }
        if minutes < 12 * 60 { return "上午" }
        return minutes < 18 * 60 ? "下午" : "晚上"
    }

    static func numeral(_ number: Int) -> String {
        let values = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
        guard number > 0, number < 100 else { return String(number) }
        if number < 10 { return values[number] }
        return (number < 20 ? "十" : values[number / 10] + "十") + (number % 10 == 0 ? "" : values[number % 10])
    }
}

struct ScheduleStyledDateHeader: View {
    @Environment(\.scheduleStyle) private var style
    @Environment(\.colorScheme) private var scheme
    @Environment(\.appThemeBrand) private var brand
    @Environment(\.scheduleStaticRendering) private var staticRendering
    let day: Int
    let date: String
    let isToday: Bool
    let adjustment: ResolvedCalendarAdjustment?
    var selected = false

    private var today: Bool { isToday && !staticRendering }
    private var dark: Bool { scheme == .dark }
    private var accent: Color { style.styleAccent(dark: dark, fallback: ThemePalette.of(brand).text(dark: dark)) }
    private var inverse: Bool { style == .table && (today || selected) }
    private var ink: Color { inverse ? ThemePalette.of(brand).onFill(dark: dark) : (today ? accent : style.inkColor(dark: dark)) }

    var body: some View {
        VStack(spacing: 3) {
            if style == .grid {
                Text(["一", "二", "三", "四", "五", "六", "日"][max(0, min(6, day - 1))])
                    .font(.system(size: 16, weight: .bold, design: style.fontDesign))
            } else {
                Text(today ? (style == .paper ? "今日" : "今天") : ScheduleCourseTimeText.weekday(day))
                    .font(.system(size: 11, weight: .semibold, design: style.fontDesign))
            }
            HStack(spacing: 2) {
                Text(date)
                    .font(.system(size: style == .paper ? 15 : 11, weight: .medium, design: style.fontDesign))
                    .monospacedDigit()
                    .padding(.horizontal, style == .paper ? 4 : 0)
                    .overlay { if style == .paper && today { Capsule().stroke(accent, lineWidth: 1) } }
                if let adjustment { ScheduleStyledAdjustmentMark(adjustment: adjustment) }
            }
        }
        .foregroundStyle(ink)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if inverse { Rectangle().fill(.themeFill) }
            else if selected { Rectangle().fill(accent.opacity(dark ? 0.16 : 0.08)) }
        }
        .overlay(alignment: .bottom) {
            if style == .board && (today || selected) { Rectangle().fill(accent).frame(height: 3) }
        }
    }
}

struct ScheduleStyledAdjustmentMark: View {
    @Environment(\.scheduleStyle) private var style
    @Environment(\.colorScheme) private var scheme
    let adjustment: ResolvedCalendarAdjustment

    var body: some View {
        if style == .paper || style == .board {
            let dark = scheme == .dark
            let ink = style.styleAccent(dark: dark, fallback: .primary)
            let canvas = style.canvasColor(dark: dark) ?? .white
            Text(adjustment.badge)
                .font(.system(size: 9, weight: .bold, design: style.fontDesign))
                .foregroundStyle(adjustment.kind == .off ? canvas : ink)
                .frame(width: 13, height: 13)
                .background(adjustment.kind == .off ? ink : .clear)
                .overlay { Rectangle().strokeBorder(ink, lineWidth: 1) }
                .accessibilityHidden(true)
        } else {
            ScheduleAdjustmentBadge(adjustment: adjustment)
        }
    }
}

/// Retains the existing row pitch, including in settings thumbnails and background previews.
struct ScheduleStyledWeekCell: View {
    @Environment(\.scheduleStyle) private var style
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scheduleHasBackgroundImage) private var hasBackground
    let today: Bool
    let holiday: Bool
    let startsSession: Bool
    /// A course tile occupies this whole cell. Dark course fills are translucent, so a cell left
    /// underneath would show its border and the row gaps through the tile.
    var covered = false
    /// The course in this period runs on into the next one; its text must not be struck through.
    var joinsBelow = false

    var body: some View {
        let dark = scheme == .dark
        switch style.layout.grid {
        case .cells:
            if covered {
                Color.clear
            } else {
                RoundedRectangle(cornerRadius: style.layout.cornerRadius)
                    .fill(.scheduleCellSurface(hasBackground: hasBackground, dark: dark))
                    .overlay {
                        if today { RoundedRectangle(cornerRadius: style.layout.cornerRadius).fill(.themeTint(0.12)) }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: style.layout.cornerRadius)
                            .strokeBorder(.scheduleCellBorder(dark: dark), style: StrokeStyle(lineWidth: 1, dash: holiday ? [3, 3] : []))
                    }
            }
        case .table:
            // Rules are drawn once for the whole table by `ScheduleTableRules`; a border per cell
            // would double every shared edge.
            Rectangle().fill(today ? AnyShapeStyle(.themeTint(0.08)) : AnyShapeStyle(Color.clear))
        case .sessions:
            Color.clear.overlay(alignment: .top) {
                Rectangle().fill(style.inkColor(dark: dark).opacity(startsSession ? 0.65 : 0.12))
                    .frame(height: startsSession ? 2 : 0.5)
            }
        case .rows:
            Color.clear.overlay(alignment: .bottom) {
                if !joinsBelow {
                    Rectangle().fill(style.inkColor(dark: dark).opacity(0.16)).frame(height: 0.5)
                }
            }
        }
    }
}

struct ScheduleStyledCourseTile: View {
    @Environment(\.scheduleStyle) private var style
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scheduleHasBackgroundImage) private var hasBackground
    @Environment(\.scheduleStaticRendering) private var staticRendering
    @Environment(\.appThemeBrand) private var brand
    @ObservedObject private var theme = NativeThemeSettings.shared
    let course: NativeScheduleCourse
    var compact = false
    var start: String? = nil
    var current = false
    var trailingInset: CGFloat = 0

    private var dark: Bool { scheme == .dark }
    private var swatch: ScheduleCourseTint.Swatch { ScheduleCourseTint.swatch(for: course.name, solid: theme.solidCourseColor) }
    private var accent: Color { swatch.accent(scheme: scheme) }
    private var inverse: Bool { style == .board && current && !staticRendering }
    private var ink: Color {
        if inverse { return style.canvasColor(dark: dark) ?? .white }
        return style == .paper || style == .board ? style.inkColor(dark: dark) : accent
    }
    /// The course-color bar on the leading edge; the text is padded by the same amount to clear it.
    private var stripeWidth: CGFloat {
        switch style.layout.course {
        case .stripe: 3
        case .ink: 2
        case .card, .departure: 0
        }
    }
    /// The board has no fill and no bar, so a small course-color mark leads the name.
    private var courseName: Text {
        guard style.layout.course == .departure else { return Text(course.name) }
        // The inverted tile swaps light and dark, so its mark takes the course color of the other scheme.
        let mark = inverse ? swatch.accent(scheme: dark ? .light : .dark) : accent
        return Text("■ ").font(.system(size: 7)).baselineOffset(1.5).foregroundColor(mark) + Text(course.name)
    }

    var body: some View {
        GeometryReader { geometry in
            let short = geometry.size.height < 64
            let small = compact || short
            VStack(alignment: style.layout.centered ? .center : .leading, spacing: small ? 2 : 4) {
                if style == .board, let start {
                    Text(start).font(.system(size: small ? 10 : 14, weight: .heavy, design: .monospaced))
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                courseName
                    .font(.system(size: small ? 11 : 13, weight: .semibold, design: style.fontDesign))
                    .lineLimit(short ? 2 : (compact ? 4 : 3))
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
                    .accessibilityLabel(course.name)
                if let location = NativeScheduleCourseCard.displayLocation(course.location) {
                    Text("@\(location)")
                        .font(.system(size: small ? 9 : 11, weight: .medium, design: style.fontDesign))
                        .lineLimit(short ? 1 : 2)
                        .minimumScaleFactor(0.8)
                }
            }
            .multilineTextAlignment(style.layout.centered ? .center : .leading)
            .foregroundStyle(ink)
            .padding(.trailing, trailingInset)
            .padding(.leading, stripeWidth)
            .padding(.horizontal, small ? 4 : 7)
            .padding(.vertical, short ? 3 : 6)
            .frame(width: geometry.size.width, height: geometry.size.height,
                   alignment: style.layout.centered ? .center : .topLeading)
        }
        .background {
            if inverse { Rectangle().fill(style.inkColor(dark: dark)) }
            else if style.layout.course == .card || style.layout.course == .stripe {
                Rectangle().fill(NativeScheduleCourseCard.fill(for: swatch, dark: dark, hasBackground: hasBackground))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: style.layout.cornerRadius))
        .overlay(alignment: .leading) {
            if stripeWidth > 0 {
                Rectangle().fill(accent).frame(width: stripeWidth).padding(.vertical, style == .paper ? 5 : 0)
            }
        }
        .overlay {
            if style.layout.borderWidth > 0 {
                RoundedRectangle(cornerRadius: style.layout.cornerRadius)
                    .strokeBorder(current && !staticRendering ? ThemePalette.of(brand).text(dark: dark) : accent,
                                  lineWidth: current && !staticRendering ? 2 : style.layout.borderWidth)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ScheduleStyledSlotLabel: View {
    @Environment(\.scheduleStyle) private var style
    @Environment(\.colorScheme) private var scheme
    let slot: ScheduleSlot
    var startsSession = false

    var body: some View {
        VStack(spacing: 1) {
            if style == .board {
                if startsSession { Text(ScheduleStyleTime.session(slot.start)).font(.system(size: 8, weight: .bold)) }
                Text(slot.start).font(.system(size: 12, weight: .bold, design: .monospaced))
                Text("第\(slot.number)节").font(.system(size: 8))
            } else {
                Text(style == .paper ? ScheduleStyleTime.numeral(slot.number) : String(slot.number))
                    .font(.system(size: style == .paper ? 12 : 13, weight: .bold, design: style.fontDesign))
                Text(slot.start).font(.system(size: 9, design: style.fontDesign))
                Text(slot.end).font(.system(size: 9, design: style.fontDesign))
            }
        }
        .monospacedDigit()
        .foregroundStyle(style.inkColor(dark: scheme == .dark))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(slot.number) 节，\(slot.start) 至 \(slot.end)")
    }
}

/// Diagonal hatching for a day off in the table style. A grey column already means "weekend",
/// so a holiday needs a mark of its own.
struct ScheduleHolidayHatch: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 6
            }
            context.stroke(path, with: .color(.scheduleCellBorder(dark: scheme == .dark)), lineWidth: 0.6)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The one set of rules for the table style: every shared edge is stroked once, at one weight.
/// Place it behind the day columns. A course tile stops just short of the rules around it, and a
/// rule that would cross a course spanning several periods is left out.
struct ScheduleTableRules: View {
    @Environment(\.colorScheme) private var scheme
    let headerHeight: CGFloat
    let rowHeight: CGFloat
    let slotCount: Int
    let axisWidth: CGFloat
    let columnWidth: CGFloat
    let dayCount: Int
    /// Whether one course covers both sides of the rule above `row` (zero-based) in day `column`.
    var joined: (_ column: Int, _ row: Int) -> Bool = { _, _ in false }

    var body: some View {
        Canvas { context, size in
            let lineWidth: CGFloat = 0.6
            var path = Path()
            // Inset by half the line so the outer frame is not clipped to half its weight.
            path.addRect(CGRect(origin: .zero, size: size).insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
            for index in 0..<dayCount {
                let x = axisWidth + CGFloat(index) * columnWidth
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for row in 0..<max(1, slotCount) {
                let y = headerHeight + CGFloat(row) * (rowHeight + NativeScheduleDayColumn.slotGap)
                if axisWidth > 0 {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: axisWidth, y: y))
                }
                for column in 0..<dayCount where !joined(column, row) {
                    let x = axisWidth + CGFloat(column) * columnWidth
                    path.move(to: CGPoint(x: x, y: y))
                    path.addLine(to: CGPoint(x: x + columnWidth, y: y))
                }
            }
            context.stroke(path, with: .color(.scheduleCellBorder(dark: scheme == .dark)), lineWidth: lineWidth)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
