import SwiftUI

// NapTable targets both iOS and macOS. The timetable surface is shared, so the
// handful of UIKit-only spellings it needs are funnelled through this file
// instead of being sprinkled through every view.

#if canImport(UIKit)
import UIKit
typealias PlatformColor = UIColor
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformColor = NSColor
typealias PlatformImage = NSImage
#endif

extension View {
    /// 导入包含登录、识别和多步编辑，使用全屏页面避免下滑误关。
    @ViewBuilder
    func appImportPresentation<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented) {
            content().interactiveDismissDisabled()
        }
        #else
        sheet(isPresented: isPresented) {
            content().interactiveDismissDisabled()
        }
        #endif
    }

    @ViewBuilder
    func appImportPresentation<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        #if os(iOS)
        fullScreenCover(item: item) { value in
            content(value).interactiveDismissDisabled()
        }
        #else
        sheet(item: item) { value in
            content(value).interactiveDismissDisabled()
        }
        #endif
    }
}

extension Image {
    /// `Image(uiImage:)` has no AppKit spelling. The schedule settings page
    /// previews the user's chosen background, which is a `PlatformImage`.
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

extension Color {
    /// The global accent selected in NapTable settings. The timetable surface,
    /// settings UI and device controls all use this same color.
    static var cpuBrand: Color {
        let theme = NextWidgetConfiguration.globalTheme
        let value = theme == .custom ? NextWidgetConfiguration.globalCustomColor : theme.brandColor
        return Color(red: value.red, green: value.green, blue: value.blue)
    }

    /// Card / cell surface used by the grid, the editor and the settings list.
    static var appSecondaryGroupedBackground: Color {
        #if canImport(UIKit)
        return Color(uiColor: .secondarySystemGroupedBackground)
        #else
        return Color(nsColor: .controlBackgroundColor)
        #endif
    }

    /// Hairline used for cell borders and list separators.
    static var appSeparator: Color {
        #if canImport(UIKit)
        return Color(uiColor: .separator)
        #else
        return Color(nsColor: .separatorColor)
        #endif
    }

}

extension EnvironmentValues {
    /// 当前主题色。页面底色按它调出来；主题一换，环境跟着变，用到底色的
    /// 页面都会重画。`MyApp` 从 `NativeThemeSettings` 注入。
    @Entry var appThemeBrand: ScheduleLiveActivityRGB = NextWidgetConfiguration.globalBrandColor
    @Entry var appThemeBackgroundEnabled = true
}

/// 整页底色：关闭主题背景时使用系统默认颜色，开启时融入少量主题色。
struct AppBackgroundStyle: ShapeStyle {
    var grouped = false

    func resolve(in environment: EnvironmentValues) -> Color {
        guard environment.appThemeBackgroundEnabled else {
            #if canImport(UIKit)
            return Color(uiColor: grouped ? .systemGroupedBackground : .systemBackground)
            #else
            return Color(nsColor: .windowBackgroundColor)
            #endif
        }
        let dark = environment.colorScheme == .dark
        let base = dark ? 0.0 : 1.0
        let amount = dark ? 0.10 : 0.05
        let brand = environment.appThemeBrand.clamped
        return Color(
            red: base * (1 - amount) + brand.red * amount,
            green: base * (1 - amount) + brand.green * amount,
            blue: base * (1 - amount) + brand.blue * amount
        )
    }
}

extension ShapeStyle where Self == AppBackgroundStyle {
    static var appBackground: AppBackgroundStyle { AppBackgroundStyle() }
    static var appGroupedBackground: AppBackgroundStyle { AppBackgroundStyle(grouped: true) }
}

extension View {
    /// 设置、导入等 Form / List 页面的底色跟随主题背景偏好。
    func appListBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(.appGroupedBackground)
    }

    /// 顶部滚动边缘用柔和的渐隐（iOS 26 / macOS 26 起才有）；更早的系统保持原样。
    @ViewBuilder
    func appSoftTopScrollEdge() -> some View {
        #if os(visionOS)
        self
        #else
        if #available(iOS 26.0, macOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
        #endif
    }

    /// `.navigationBarTitleDisplayMode(.inline)` is unavailable on macOS; on the
    /// Mac the window title bar already keeps the title compact.
    @ViewBuilder
    func appInlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// `.presentationDetents` is iOS-only.
    @ViewBuilder
    func appSheetDetents(_ detents: Set<PresentationDetent>) -> some View {
        #if os(iOS)
        self.presentationDetents(detents)
        #else
        self
        #endif
    }

    /// `.textInputAutocapitalization` is iOS-only; the Mac has no software
    /// keyboard to steer, so the field just keeps whatever the user types.
    @ViewBuilder
    func appUppercasedInput() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.characters)
        #else
        self
        #endif
    }

    @ViewBuilder
    func appDragIndicatorVisible() -> some View {
        #if os(iOS)
        self.presentationDragIndicator(.visible)
        #else
        self
        #endif
    }

    /// `.tabViewStyle(.page)` (the native horizontal pager the 4.0 timetable
    /// uses for weeks and days) exists only on iOS. On the Mac the pages fall
    /// back to the default tab style, where the week/day steppers stay the
    /// navigation.
    @ViewBuilder
    func appPageTabViewStyle() -> some View {
        #if os(iOS)
        self.tabViewStyle(.page(indexDisplayMode: .never))
        #else
        self
        #endif
    }
}

extension ToolbarItemPlacement {
    /// `.topBarLeading` is iOS-only; on the Mac the leading toolbar slot is the
    /// cancellation action.
    static var appLeading: ToolbarItemPlacement {
        #if os(iOS)
        return .topBarLeading
        #else
        return .cancellationAction
        #endif
    }

    /// `.topBarTrailing` is iOS-only; on the Mac the trailing toolbar slot is
    /// the confirmation action.
    static var appTrailing: ToolbarItemPlacement {
        #if os(iOS)
        return .topBarTrailing
        #else
        return .confirmationAction
        #endif
    }
}

/// `#if os(iOS)` guards in view bodies are noise; this keeps a single source of
/// truth for "this is a phone-sized touch surface".
enum PlatformSurface {
    static var isCompactTouch: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }
}

// MARK: - Sharing

extension View {
    /// Render a view to PNG data. CpuTime shares the timetable by rendering the
    /// live grid to an image; the renderer's scale differs per platform.
    @MainActor
    func platformRenderedImageData(scale: CGFloat = 2) -> Data? {
        let renderer = ImageRenderer(content: self)
        #if os(visionOS)
        // `UIScreen` does not exist on visionOS; the renderer's own default
        // scale is the right value there.
        _ = scale
        return renderer.uiImage?.pngData()
        #elseif canImport(UIKit)
        renderer.scale = UIScreen.main.scale
        return renderer.uiImage?.pngData()
        #elseif canImport(AppKit)
        renderer.scale = scale
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
        #else
        return nil
        #endif
    }
}

/// Writes a share item to a temporary file and opens the system share sheet.
///
/// CpuTime's `NativeScheduleSharePresenter` drives `UIActivityViewController`
/// directly. NapTable targets the Mac and the Vision Pro as well, so each
/// platform gets its native presentation and the unsupported ones degrade to
/// writing the file (which stays in the temporary directory for the user).
@MainActor
enum PlatformSharePresenter {
    static func present(data: Data, fileName: String, mimeType: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            // A failed share must never replace a visible timetable with an error.
            return
        }
        present(items: [url])
    }

    static func present(text: String, fileName: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return
        }
        present(items: [url])
    }

    private static func present(items: [Any]) {
        #if os(iOS)
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first,
              let root = window.rootViewController else { return }
        let presenter = topViewController(root)
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.maxY - 20,
                width: 1,
                height: 1
            )
        }
        presenter.present(controller, animated: true)
        #elseif os(macOS)
        guard let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first,
              let view = window.contentView,
              let url = items.first as? URL else { return }
        NSSharingServicePicker(items: [url]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        #else
        _ = items
        #endif
    }

    #if os(iOS)
    private static func topViewController(_ controller: UIViewController) -> UIViewController {
        if let presented = controller.presentedViewController { return topViewController(presented) }
        if let navigation = controller as? UINavigationController, let visible = navigation.visibleViewController {
            return topViewController(visible)
        }
        if let tab = controller as? UITabBarController, let selected = tab.selectedViewController {
            return topViewController(selected)
        }
        return controller
    }
    #endif
}
