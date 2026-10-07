import SwiftUI

/// The board's day view: what is on now, what comes next and how long is left.
/// Any other day, a day with the now indicator off and a share image have no "now", so they show
/// one plain timetable instead.
struct ScheduleBoardDayView: View {
    @Environment(\.scheduleStyle) private var style
    /// In timetable order.
    let blocks: [NativeScheduleCourseBlock]
    let status: ScheduleStyledDayStatus
    let cardHeight: CGFloat
    let isEditable: Bool
    let onCourseSelected: (NativeScheduleCourseBlock) -> Void
    let onCoursePreview: (NativeScheduleCourseBlock) -> Void

    private static let nowHeight: CGFloat = 36
    private static let headingHeight: CGFloat = 40
    private static let heroGap: CGFloat = 4
    private static let verticalPadding: CGFloat = 8
    private static func heroHeight(_ cardHeight: CGFloat) -> CGFloat { max(148, cardHeight * 1.38) }
    private static func rowHeight(_ cardHeight: CGFloat) -> CGFloat { max(68, cardHeight * 0.66) }
    private static func finishedHeight(_ cardHeight: CGFloat) -> CGFloat { max(34, cardHeight * 0.34) }

    /// The day pager is sized before it knows the time, so this is the layout at its tallest: every
    /// course that can be in progress at once as a hero block, the rest as full rows under 接下来,
    /// and both headings. The plain timetable is exact, which a share image relies on.
    static func height(blocks: [NativeScheduleCourseBlock], cardHeight: CGFloat, isStatic: Bool) -> CGFloat {
        let count = CGFloat(blocks.count)
        let padding = 2 * verticalPadding
        if isStatic { return headingHeight + count * rowHeight(cardHeight) + padding }
        let concurrent = CGFloat(blocks.map { block in
            blocks.filter { $0.startSlot <= block.startSlot && block.startSlot <= $0.endSlot }.count
        }.max() ?? 1)
        return nowHeight + concurrent * (heroHeight(cardHeight) + heroGap)
            + (count - concurrent) * rowHeight(cardHeight) + 2 * headingHeight + padding
    }

    private func courses(_ phase: ScheduleStyledDayStatus.Phase) -> [NativeScheduleCourseBlock] {
        blocks.filter { status.phase($0) == phase }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let now = status.now {
                let current = courses(.current), upcoming = courses(.upcoming), finished = courses(.completed)
                ScheduleBoardNowLine(minutes: now, remaining: current.count + upcoming.count)
                    .frame(height: Self.nowHeight)
                ForEach(current) { block in
                    course(block, height: Self.heroHeight(cardHeight)) {
                        ScheduleBoardHero(block: block, status: status, now: now)
                    }
                    .padding(.bottom, Self.heroGap)
                }
                list("接下来", upcoming, countsDown: true)
                if !finished.isEmpty {
                    ScheduleBoardHeading(title: "已结束", ruled: false).frame(height: Self.headingHeight)
                    ForEach(finished) { block in
                        course(block, height: Self.finishedHeight(cardHeight)) {
                            ScheduleBoardFinishedRow(block: block, status: status)
                        }
                    }
                }
            } else {
                list("课程安排", blocks, countsDown: false)
            }
        }
        .padding(.vertical, Self.verticalPadding)
        .background { ScheduleSurface(cornerRadius: 0, isPanel: true, showsBorder: style.framesPanel) }
    }

    @ViewBuilder
    private func list(_ title: String, _ courses: [NativeScheduleCourseBlock], countsDown: Bool) -> some View {
        if !courses.isEmpty {
            ScheduleBoardHeading(title: title).frame(height: Self.headingHeight)
            ForEach(courses) { block in
                course(block, height: Self.rowHeight(cardHeight)) {
                    ScheduleBoardRow(block: block, status: status,
                                     note: note(block, isNext: countsDown && block.id == courses.first?.id),
                                     showsDivider: block.id != courses.last?.id)
                }
            }
        }
    }

    /// Same gestures as every other course surface: tap to preview, long press to edit.
    private func course<Content: View>(_ block: NativeScheduleCourseBlock, height: CGFloat,
                                       @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(height: height)
            .contentShape(Rectangle())
            .modifier(ScheduleCourseInteraction(
                cornerRadius: 2, isEditable: isEditable,
                onPreview: { onCoursePreview(block) }, onEdit: { onCourseSelected(block) }
            ))
    }

    /// The trailing edge of a row: a countdown for the next course, and 已结束 for a finished
    /// course in the plain timetable. Every other row leaves it empty; the times already lead.
    private func note(_ block: NativeScheduleCourseBlock, isNext: Bool) -> ScheduleBoardRow.Note? {
        if status.phase(block) == .completed { return .init(text: "已结束", emphasized: false) }
        if isNext, let now = status.now, let start = scheduleClockMinutes(status.start(block)), start > now {
            let wait = start - now
            let text = wait < 60 ? "\(wait) 分钟后"
                : (wait % 60 == 0 ? "\(wait / 60) 小时后" : "\(wait / 60) 小时 \(wait % 60) 分后")
            return .init(text: text, emphasized: true)
        }
        return nil
    }
}

private func boardSlotText(_ block: NativeScheduleCourseBlock) -> String {
    "第 \(block.startSlot)\(block.startSlot == block.endSlot ? "" : "–\(block.endSlot)") 节"
}

/// 「高等数学，教室 A101，第 1–2 节，08:00 至 09:40，已结束」
private func boardSpokenLabel(_ block: NativeScheduleCourseBlock, status: ScheduleStyledDayStatus, state: String?) -> String {
    [block.course.name,
     NativeScheduleCourseCard.displayLocation(block.course.location).map { "教室 \($0)" },
     boardSlotText(block),
     "\(status.start(block)) 至 \(status.end(block))",
     state].compactMap { $0 }.joined(separator: "，")
}

private struct ScheduleBoardNowLine: View {
    @Environment(\.scheduleStyle) private var style
    @Environment(\.colorScheme) private var scheme
    let minutes: Int
    /// Courses in progress or still to come.
    let remaining: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("现在").font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(2).opacity(0.72)
            Text(String(format: "%02d:%02d", minutes / 60, minutes % 60))
                .font(.system(size: 16, weight: .bold, design: .monospaced))
            Spacer(minLength: 8)
            Text(remaining > 0 ? "今天还有 \(remaining) 门课" : "今天的课上完了")
                .font(.system(size: 12, weight: .medium)).monospacedDigit().opacity(0.72)
        }
        .foregroundStyle(style.inkColor(dark: scheme == .dark))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
    }
}

private struct ScheduleBoardHeading: View {
    @Environment(\.scheduleStyle) private var style
    @Environment(\.colorScheme) private var scheme
    let title: String
    /// The heavy rule that opens a list. 已结束 is a quieter footer and goes without.
    var ruled = true

    var body: some View {
        let ink = style.inkColor(dark: scheme == .dark)
        VStack(alignment: .leading, spacing: 6) {
            Spacer(minLength: 0)
            Text(title).font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(2)
                .foregroundStyle(ink.opacity(0.72)).padding(.horizontal, 12)
            Rectangle().fill(ink.opacity(ruled ? 0.65 : 0)).frame(height: 2)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// The course in progress, inverted: time range, name, room and teacher, time left and progress.
private struct ScheduleBoardHero: View {
    @Environment(\.scheduleStyle) private var style
    @Environment(\.colorScheme) private var scheme
    @Environment(\.appThemeBrand) private var brand
    @ObservedObject private var theme = NativeThemeSettings.shared
    let block: NativeScheduleCourseBlock
    let status: ScheduleStyledDayStatus
    let now: Int

    private var dark: Bool { scheme == .dark }
    /// The block swaps light and dark, so the colors on it come from the other scheme.
    private var accent: Color { ThemePalette.of(brand).text(dark: !dark) }
    private var range: (start: Int, end: Int)? {
        guard let start = scheduleClockMinutes(status.start(block)), let end = scheduleClockMinutes(status.end(block)),
              end > start else { return nil }
        return (start, end)
    }
    private var remaining: Int { max(1, (range?.end ?? now) - now) }
    private var detail: String? {
        let teacher = block.course.teacher?.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [NativeScheduleCourseCard.displayLocation(block.course.location), teacher].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        let paper = style.canvasColor(dark: dark) ?? .white
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("正在上 · \(boardSlotText(block))")
                    .font(.system(size: 11, weight: .bold)).tracking(1).opacity(0.72)
                Spacer(minLength: 8)
                Text("还剩 \(remaining) 分")
                    .font(.system(size: 13, weight: .bold)).monospacedDigit().foregroundStyle(accent)
            }
            Spacer(minLength: 4)
            Text("\(status.start(block)) — \(status.end(block))")
                .font(.system(size: 30, weight: .bold, design: .monospaced)).minimumScaleFactor(0.6)
            Spacer(minLength: 4)
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(ScheduleCourseTint.accent(for: block.course.name, scheme: dark ? .light : .dark,
                                                    solid: theme.solidCourseColor))
                    .frame(width: 9, height: 9)
                Text(block.course.name).font(.headline.weight(.bold)).minimumScaleFactor(0.75)
            }
            if let detail {
                Text(detail).font(.subheadline).opacity(0.72).padding(.top, 3)
            }
            Spacer(minLength: 8)
            Rectangle().fill(paper.opacity(0.25)).frame(height: 3)
                .overlay(alignment: .leading) {
                    GeometryReader { geometry in
                        let fraction = range.map { CGFloat(now - $0.start) / CGFloat($0.end - $0.start) } ?? 0
                        Rectangle().fill(accent).frame(width: geometry.size.width * min(1, max(0, fraction)))
                    }
                }
        }
        .lineLimit(1)
        .foregroundStyle(paper)
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(style.inkColor(dark: dark))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(boardSpokenLabel(block, status: status, state: "正在上，还剩 \(remaining) 分"))
    }
}

/// A course still to come, or any course in the plain timetable: the start time leads, with
/// the end time under it.
private struct ScheduleBoardRow: View {
    struct Note {
        let text: String
        /// The countdown to the next course takes the theme color.
        let emphasized: Bool
    }

    @Environment(\.scheduleStyle) private var style
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var theme = NativeThemeSettings.shared
    let block: NativeScheduleCourseBlock
    let status: ScheduleStyledDayStatus
    let note: Note?
    var showsDivider = true

    var body: some View {
        let ink = style.inkColor(dark: scheme == .dark)
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(status.start(block)).font(.system(size: 24, weight: .bold, design: .monospaced))
                Text(status.end(block)).font(.system(size: 12, weight: .medium, design: .monospaced)).opacity(0.72)
            }
            .minimumScaleFactor(0.7)
            .frame(width: 82, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(ScheduleCourseTint.accent(for: block.course.name, scheme: scheme, solid: theme.solidCourseColor))
                        .frame(width: 9, height: 9)
                    Text(block.course.name).font(.headline.weight(.semibold)).minimumScaleFactor(0.75)
                }
                Text([NativeScheduleCourseCard.displayLocation(block.course.location), boardSlotText(block)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).opacity(0.72)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let note {
                Text(note.text).font(.caption.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(note.emphasized ? AnyShapeStyle(.themeText) : AnyShapeStyle(ink.opacity(0.72)))
                    .fixedSize()
            }
        }
        .lineLimit(1)
        .foregroundStyle(ink)
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if showsDivider { Rectangle().fill(ink.opacity(0.15)).frame(height: 0.5) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(boardSpokenLabel(block, status: status, state: note?.text))
    }
}

/// A finished course folds down to one quiet line.
private struct ScheduleBoardFinishedRow: View {
    @Environment(\.scheduleStyle) private var style
    @Environment(\.colorScheme) private var scheme
    let block: NativeScheduleCourseBlock
    let status: ScheduleStyledDayStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(status.start(block)).font(.system(size: 14, weight: .semibold, design: .monospaced))
                .frame(width: 82, alignment: .leading)
            Text(block.course.name).font(.subheadline).minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            if let location = NativeScheduleCourseCard.displayLocation(block.course.location) {
                Text(location).font(.caption)
            }
        }
        .lineLimit(1)
        .foregroundStyle(style.inkColor(dark: scheme == .dark).opacity(0.62))
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(boardSpokenLabel(block, status: status, state: "已结束"))
    }
}
