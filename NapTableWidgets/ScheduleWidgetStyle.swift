import SwiftUI
import WidgetKit

/// Geometry shared by the extension's compact course surfaces. Minimal always
/// takes the caller's original geometry, font and colors.
struct ScheduleWidgetStylePalette {
    let style: ScheduleStyle
    let dark: Bool
    let theme: ThemePalette

    var courseRadius: CGFloat { CGFloat(style.layout.cornerRadius) }
    var courseBorderWidth: CGFloat { CGFloat(style.layout.borderWidth) }
    var accent: Color { style.styleAccent(dark: dark, fallback: theme.text(dark: dark)) }
    var courseFillOpacity: Double {
        switch style.layout.course {
        case .card: dark ? 0.18 : 0.12
        case .stripe: dark ? 0.10 : 0.06
        case .ink: 0
        case .departure: dark ? 0.10 : 0.06
        }
    }
}

extension View {
    func scheduleWidgetStyle(_ style: ScheduleStyle) -> some View {
        environment(\.scheduleStyle, style)
    }
}

extension ScheduleStyle {
    /// A root fontDesign cannot replace explicit font designs on Text. Keep
    /// every original font in minimal; apply the selected design at the leaf.
    func widgetFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size, weight: weight, design: self == .minimal ? design : fontDesign)
    }
}

/// Environment-aware colors leave accented/vibrant rendering to WidgetKit.
/// In particular, never paint dark paper ink into a tinted widget.
@propertyWrapper
struct WidgetStyleColors: DynamicProperty {
    @Environment(\.scheduleStyle) private var style
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetRenderingMode) private var renderingMode
    var wrappedValue: Self { self }
    private var styled: Bool { style != .minimal && renderingMode == .fullColor }
    private var dark: Bool { scheme == .dark }

    var primary: Color { styled ? style.inkColor(dark: dark) : WidgetPalette.primary }
    var secondary: Color { styled ? primary.opacity(0.75) : WidgetPalette.secondary }
    var muted: Color { styled ? primary.opacity(0.65) : WidgetPalette.muted }

    func accent(for theme: ScheduleWidgetTheme) -> Color {
        guard styled else { return style == .minimal ? WidgetPalette.accent(for: theme) : .primary }
        return style.styleAccent(dark: dark, fallback: ThemePalette.of(NextWidgetConfiguration.globalBrandColor).text(dark: dark))
    }

    /// A solid accent fill and the text on it. Outside minimal, `accent(for:)` is a text tier that
    /// turns light in dark mode, so white text would not hold on it: paper and board put their
    /// canvas color on the accent, grid and table use the theme's fill tier.
    func solidAccent(for theme: ScheduleWidgetTheme) -> (fill: Color, text: Color) {
        guard styled else { return (accent(for: theme), .white) }
        if let canvas = style.canvasColor(dark: dark) { return (accent(for: theme), canvas) }
        let palette = ThemePalette.of(NextWidgetConfiguration.globalBrandColor)
        return (palette.fill(dark: dark), palette.onFill(dark: dark))
    }

    func accent(for course: WidgetCourse, theme: ScheduleWidgetTheme, colorful: Bool, colorScheme: ColorScheme) -> Color {
        if style == .minimal {
            return WidgetPalette.accent(for: course, theme: theme, colorful: colorful, colorScheme: colorScheme)
        }
        guard renderingMode == .fullColor else { return .primary }
        return colorful ? ScheduleCourseTint.accent(for: course.displayName, scheme: colorScheme) : accent(for: theme)
    }

    func tint(for course: WidgetCourse, colorScheme: ColorScheme, theme: ScheduleWidgetTheme, colorful: Bool) -> Color {
        WidgetPalette.tint(for: course, colorScheme: colorScheme, theme: theme, colorful: colorful)
    }
}

/// Decorations stay inside existing row bounds so small widgets and merged
/// Live Activities keep their content budget. ActivityKit owns the outer shape.
struct WidgetCourseRule: View {
    @Environment(\.scheduleStyle) private var style
    let color: Color
    var body: some View {
        switch style.layout.grid {
        case .cells:
            RoundedRectangle(cornerRadius: style.layout.cornerRadius)
                .strokeBorder(color.opacity(0.65), lineWidth: style.layout.borderWidth)
        case .table:
            VStack { Spacer(minLength: 0); Rectangle().fill(color.opacity(0.3)).frame(height: 0.5) }
        case .sessions:
            VStack { Spacer(minLength: 0); Rectangle().fill(color.opacity(0.6)).frame(height: 2) }
        case .rows:
            if style == .paper {
                VStack { Spacer(minLength: 0); Rectangle().fill(color.opacity(0.3)).frame(height: 0.5) }
            }
        }
    }
}
