import SwiftUI

/// Five visual styles share the same schedule data and interaction semantics.
struct ScheduleStylePicker: View {
    @ObservedObject private var settings = NativeThemeSettings.shared

    var body: some View {
        List {
            Section {
                ForEach(ScheduleStyle.allCases) { style in
                    Button {
                        settings.setStyle(style)
                    } label: {
                        HStack(spacing: 14) {
                            StylePreview(style: style)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(style.title)
                                    .foregroundStyle(.primary)
                                    .font(.headline)
                                Text(style.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            if settings.style == style {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.themeText)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(settings.style == style ? [.isSelected] : [])
                }
            } footer: {
                Text("课表风格不改变课程数据、主题色或背景图片。")
            }
        }
        .navigationTitle("课表风格")
    }
}

private struct StylePreview: View {
    let style: ScheduleStyle

    private static let rowHeight: CGFloat = 32
    private static let slotCount = 4
    private static let padding: CGFloat = 8
    /// The real components at full size: three day columns inside the week panel.
    private static let canvas = CGSize(
        width: 264,
        height: NativeScheduleDayColumn.dateHeaderHeight + CGFloat(slotCount) * rowHeight
            + CGFloat(slotCount - 1) * NativeScheduleDayColumn.slotGap + 2 * padding
    )
    /// The thumbnail is the whole canvas at one scale, so no edge of the panel is cut off.
    private static let width: CGFloat = 82
    private static var scale: CGFloat { width / canvas.width }

    /// Same column gaps as the week view: only minimal and grid keep space between days.
    private var gap: CGFloat { style == .minimal || style == .grid ? 4 : 0 }

    var body: some View {
        let columnWidth = (Self.canvas.width - 2 * Self.padding - 2 * gap) / 3
        HStack(alignment: .top, spacing: gap) {
            ForEach(1...3, id: \.self) { day in
                NativeScheduleDayColumn(
                    day: day, dateText: "\(day + 5)", isToday: false,
                    adjustment: nil, columnWidth: columnWidth, rowHeight: Self.rowHeight, slotCount: Self.slotCount,
                    compactCards: true, showsDateHeader: true, isEditable: false,
                    blocks: [sample(day)], onCourseSelected: { _ in }, onEmptySlot: { _ in }
                )
            }
        }
        .background(alignment: .topLeading) {
            if style == .table {
                ScheduleTableRules(headerHeight: NativeScheduleDayColumn.dateHeaderHeight, rowHeight: Self.rowHeight,
                                   slotCount: Self.slotCount, axisWidth: 0, columnWidth: columnWidth, dayCount: 3,
                                   joined: { column, row in row == sampleStart(column + 1) })
            }
        }
        .padding(Self.padding)
        // The table draws its own frame; a panel border around it would read as a second box.
        .background { ScheduleSurface(cornerRadius: 12, isPanel: true, showsBorder: style != .table) }
        .environment(\.scheduleStyle, style)
        .environment(\.scheduleStaticRendering, true)
        .environment(\.dynamicTypeSize, .medium)
        .frame(width: Self.canvas.width, height: Self.canvas.height, alignment: .top)
        .scaleEffect(Self.scale, anchor: .topLeading)
        .frame(width: Self.width, height: (Self.canvas.height * Self.scale).rounded(.up), alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Each sample course covers two periods, starting here.
    private func sampleStart(_ day: Int) -> Int { day == 2 ? 3 : 1 }

    private func sample(_ day: Int) -> NativeScheduleCourseBlock {
        let start = sampleStart(day)
        let course = NativeScheduleCourse(
            name: ["高等数学", "大学英语", "程序设计"][day - 1],
            location: "A10\(day)", startSlot: start, endSlot: start + 1
        )
        return NativeScheduleCourseBlock(id: "preview-\(day)", course: course,
                                        bigSlot: 1, startSlot: start, endSlot: start + 1)
    }
}
