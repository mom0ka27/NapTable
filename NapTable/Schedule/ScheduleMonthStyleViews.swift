import SwiftUI

/// 月历预览与当天完整清单共用的非简约课程行。交互和权限由调用方保留。
struct ScheduleMonthStyledCourseRow: View {
    let block: NativeScheduleCourseBlock
    let metadata: String
    var compact = false

    @Environment(\.scheduleStyle) private var style
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scheduleHasBackgroundImage) private var hasBackground
    @ObservedObject private var themeSettings = NativeThemeSettings.shared

    private var ink: Color { style.inkColor(dark: colorScheme == .dark) }
    private var paper: Color { style.canvasColor(dark: colorScheme == .dark) ?? .clear }
    private var swatch: ScheduleCourseTint.Swatch {
        ScheduleCourseTint.swatch(for: block.course.name, solid: themeSettings.solidCourseColor)
    }
    private var accent: Color { swatch.accent(scheme: colorScheme) }
    private var start: String {
        ScheduleSlot.all.first(where: { $0.number == block.startSlot })?.start ?? "--:--"
    }
    private var end: String {
        ScheduleSlot.all.first(where: { $0.number == block.endSlot })?.end ?? start
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize && !compact {
                VStack(alignment: .leading, spacing: 10) {
                    times
                    course
                }
            } else {
                HStack(spacing: 10) {
                    times
                    Rectangle()
                        .fill(accent)
                        .frame(width: style == .paper ? 2 : 3)
                        .padding(.vertical, 10)
                        .accessibilityHidden(true)
                    course
                }
            }
        }
        .padding(.horizontal, style == .paper ? 0 : 10)
        .padding(.vertical, compact ? 5 : 12)
        .frame(maxWidth: .infinity, maxHeight: compact ? .infinity : nil, alignment: .leading)
        .foregroundStyle(ink)
        .background {
            if style == .grid {
                RoundedRectangle(cornerRadius: style.layout.cornerRadius)
                    .fill(NativeScheduleCourseCard.fill(for: swatch, dark: colorScheme == .dark, hasBackground: hasBackground))
            } else if style == .table {
                ink.opacity(colorScheme == .dark ? 0.06 : 0.035)
            }
        }
        .overlay {
            if style == .grid {
                RoundedRectangle(cornerRadius: style.layout.cornerRadius)
                    .strokeBorder(accent, lineWidth: style.layout.borderWidth)
            }
        }
        .overlay(alignment: .bottom) {
            if style != .grid {
                Rectangle().fill(ink.opacity(contrast == .increased ? 0.6 : 0.24))
                    .frame(height: style == .board ? 1.5 : 0.6)
            }
        }
        .contentShape(Rectangle())
    }

    private var times: some View {
        VStack(alignment: style == .board ? .leading : .trailing, spacing: 3) {
            Text(start)
                .font(.system(compact ? .caption : .subheadline, design: style.fontDesign).weight(.semibold))
            Text(end)
                .font(.system(.caption2, design: style.fontDesign))
        }
        .monospacedDigit()
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(style == .board ? paper : ink)
        .padding(.horizontal, style == .board ? 6 : 0)
        .padding(.vertical, style == .board ? 6 : 0)
        .background(style == .board ? ink : Color.clear)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(start) 至 \(end)")
    }

    private var course: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(block.course.name)
                .font(.system(compact ? .subheadline : .body, design: style.fontDesign).weight(.semibold))
                .lineLimit(compact ? 1 : nil)
            Text(style == .grid && block.course.location?.trimmedNonEmpty != nil ? "@" + metadata : metadata)
                .font(.system(compact ? .caption2 : .footnote, design: style.fontDesign))
                .foregroundStyle(ink.opacity(contrast == .increased ? 0.9 : 0.74))
                .lineLimit(compact ? 1 : nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
