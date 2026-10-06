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
                                .frame(width: 82, height: 54)
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

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(1...3, id: \.self) { day in
                NativeScheduleDayColumn(
                    day: day, dateText: "\(day + 5)", isToday: false,
                    adjustment: nil, columnWidth: 80, rowHeight: 32, slotCount: 4,
                    compactCards: true, showsDateHeader: true, isEditable: false,
                    blocks: [sample(day)], onCourseSelected: { _ in }, onEmptySlot: { _ in }
                )
            }
        }
        .padding(8)
        .background { ScheduleSurface(cornerRadius: 12, isPanel: true) }
        .environment(\.scheduleStyle, style)
        .environment(\.scheduleStaticRendering, true)
        .environment(\.dynamicTypeSize, .medium)
        .frame(width: 264, height: 210, alignment: .top)
        .scaleEffect(0.30, anchor: .topLeading)
        .frame(width: 82, height: 54, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func sample(_ day: Int) -> NativeScheduleCourseBlock {
        let start = day == 2 ? 3 : 1
        let course = NativeScheduleCourse(
            name: ["高等数学", "大学英语", "程序设计"][day - 1],
            location: "A10\(day)", startSlot: start, endSlot: start + 1
        )
        return NativeScheduleCourseBlock(id: "preview-\(day)", course: course,
                                        bigSlot: 1, startSlot: start, endSlot: start + 1)
    }
}
