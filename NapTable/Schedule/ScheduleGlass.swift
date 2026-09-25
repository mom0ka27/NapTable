import SwiftUI

// The glass surface treatment the CpuTime schedule UI is built from. Kept in its
// own file so the import and settings screens can use the same material instead
// of falling back to stock list chrome.

/// Native Liquid Glass is confined to controls. Course grids retain lightweight
/// gradients so scrolling does not create dozens of live blur surfaces.
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
}

extension ShapeStyle where Self == Color {
    /// 格子、表头这类小块表面的底色。数量多，不用实时模糊的材质。
    static func scheduleCellSurface(hasBackground: Bool, dark: Bool) -> Color {
        guard hasBackground else { return Color.appSecondaryGroupedBackground.opacity(0.86) }
        return dark ? Color.appSecondaryGroupedBackground.opacity(0.5) : Color.white.opacity(0.5)
    }
}

/// 学期选择器、自由时间入口这类单个的实心卡片：有背景图时换成磨砂材质。
struct ScheduleCardSurface: ShapeStyle {
    var hasBackground: Bool

    func resolve(in environment: EnvironmentValues) -> AnyShapeStyle {
        hasBackground ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color.appSecondaryGroupedBackground)
    }
}

struct ScheduleGlassBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scheduleHasBackgroundImage) private var hasBackground
    let cornerRadius: CGFloat
    var colors: [Color] = [.clear, .clear]
    var border: Color = Color.appSeparator.opacity(0.12)
    var lineWidth: CGFloat = 0.7

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(.scheduleCellSurface(hasBackground: hasBackground, dark: colorScheme == .dark))
            .overlay {
                shape.fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay {
                shape.fill(LinearGradient(
                    stops: [
                        .init(color: .white.opacity(colorScheme == .dark ? 0.08 : 0.32), location: 0),
                        .init(color: .white.opacity(0.02), location: 0.45),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            }
            .overlay { shape.strokeBorder(border, lineWidth: lineWidth) }
            .allowsHitTesting(false)
    }
}
