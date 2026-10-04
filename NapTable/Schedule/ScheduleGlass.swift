import SwiftUI

// Surface styles for the schedule UI, kept in one file so the import and
// settings screens can use the same treatment instead of stock list chrome.
//
// Liquid Glass is a control layer: it belongs to the few buttons that float
// above the timetable, never to the timetable itself. Cells, cards and course
// blocks are flat fills, so the grid reads as content and scrolling does not
// create dozens of live blur surfaces.

/// Native Liquid Glass for a floating control (or one group of them).
struct ScheduleGlassControl: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let cornerRadius: CGFloat
    var tint: Color? = nil
    var interactive = true

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.appSecondaryGroupedBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Color.appSeparator.opacity(0.22), lineWidth: 0.7)
                    }
            }
        } else {
#if compiler(>=6.2)
            // Liquid Glass exists on macOS as well, but this target's macOS
            // deployment target is older than 26.0, so the guard has to name
            // the platform: an iOS-only `#available` cannot prove availability
            // on the Mac and the build fails there.
            #if os(iOS)
            if #available(iOS 26.0, *) {
                content.glassEffect(
                    .regular.tint(tint).interactive(interactive && isEnabled && !reduceMotion),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
            } else {
                legacyMaterial(content)
            }
            #else
            legacyMaterial(content)
            #endif
#else
            legacyMaterial(content)
#endif
        }
    }

    func legacyMaterial(_ content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.thinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(tint ?? .clear)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(LinearGradient(
                            colors: [.white.opacity(0.35), Color.appSeparator.opacity(0.15)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ), lineWidth: 0.7)
                }
        }
    }
}

extension EnvironmentValues {
    /// 课表页铺了背景图。格子和卡片的底色要跟着变透，否则一块块白底会盖在
    /// 图上，看起来像贴了纸。
    @Entry var scheduleHasBackgroundImage = false
    /// 当前外观下背景图的不透明度。周视图面板按它决定压多少，见 `schedulePanelSurface`。
    @Entry var scheduleBackgroundOpacity: Double = 0
}

/// 课表页与设置列表共用背景偏好，关闭主题背景时使用系统分组背景色。
struct ScheduleCanvasStyle: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color {
        AppBackgroundStyle(grouped: true).resolve(in: environment)
    }
}

extension ShapeStyle where Self == ScheduleCanvasStyle {
    static var scheduleCanvas: ScheduleCanvasStyle { ScheduleCanvasStyle() }
}

extension ShapeStyle where Self == Color {
    /// 空格子、表头这类小块表面的底色。数量多，只用平涂，不加渐变和高光。
    static func scheduleCellSurface(hasBackground: Bool, dark: Bool) -> Color {
        if hasBackground { return dark ? Color.white.opacity(0.08) : Color.white.opacity(0.55) }
        return dark ? Color.white.opacity(0.05) : Color.white
    }

    /// 周视图那一整块面板的底色。有背景图时不用磨砂：面板几乎盖住整张图，
    /// 磨砂会把主体糊成一片颜色。只铺一层淡平涂，图片越实压得越多，
    /// 节次和日期文字始终读得清，图片主体也照样看得见。
    static func schedulePanelSurface(hasBackground: Bool, dark: Bool, imageOpacity: Double) -> Color {
        guard hasBackground else { return dark ? Color.white.opacity(0.09) : Color.white.opacity(0.96) }
        let veil = 0.14 + 0.32 * min(1, max(0, imageOpacity))
        return dark ? Color.black.opacity(veil) : Color.white.opacity(veil)
    }

    /// 格子和卡片外面那圈细边：浅色是带一点蓝的浅灰，深色是一层淡白。
    static func scheduleCellBorder(dark: Bool) -> Color {
        dark ? Color.white.opacity(0.12) : Color(red: 0.14, green: 0.18, blue: 0.28).opacity(0.14)
    }
}

/// 自由时间入口、月历这类单个卡片的底色：平时和格子一样是白底，有背景图时换成
/// 磨砂材质，文字才压得住图。
struct ScheduleCardSurface: ShapeStyle {
    var hasBackground: Bool

    func resolve(in environment: EnvironmentValues) -> AnyShapeStyle {
        if hasBackground { return AnyShapeStyle(.regularMaterial) }
        return AnyShapeStyle(environment.colorScheme == .dark ? Color.white.opacity(0.07) : Color.white)
    }
}

/// 课表上的一块内容表面：平涂加一圈细边。格子、表头、周次导航和卡片都用它，
/// 整页只有这一种描边语言，不再叠渐变、高光和投影。
struct ScheduleSurface: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scheduleHasBackgroundImage) private var hasBackground
    @Environment(\.scheduleBackgroundOpacity) private var backgroundOpacity
    let cornerRadius: CGFloat
    /// 单独的一块卡片。有背景图时用磨砂材质；成片的格子不用实时模糊。
    var isCard = false
    /// 周视图的整块面板。有背景图时只是一层淡平涂，不模糊，见 `schedulePanelSurface`。
    var isPanel = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if isPanel {
                shape.fill(.schedulePanelSurface(hasBackground: hasBackground, dark: colorScheme == .dark,
                                                 imageOpacity: backgroundOpacity))
            } else if isCard {
                shape.fill(ScheduleCardSurface(hasBackground: hasBackground))
            } else {
                shape.fill(.scheduleCellSurface(hasBackground: hasBackground, dark: colorScheme == .dark))
            }
        }
        .overlay { shape.strokeBorder(.scheduleCellBorder(dark: colorScheme == .dark), lineWidth: 1) }
        .allowsHitTesting(false)
    }
}
