import Combine
import SwiftUI

/// One accent theme shared by the app, widgets, Live Activity and Dynamic Island.
@MainActor
final class NativeThemeSettings: ObservableObject {
    static let shared = NativeThemeSettings()

    @Published private(set) var theme: ScheduleLiveActivityTheme
    @Published private(set) var customColor: ScheduleLiveActivityRGB
    @Published private(set) var solidCourseColors: Bool

    private let defaults: UserDefaults?

    private init() {
        defaults = UserDefaults(suiteName: NextWidgetConfiguration.appGroup)
        theme = NextWidgetConfiguration.globalTheme
        customColor = NextWidgetConfiguration.globalCustomColor
        solidCourseColors = NextWidgetConfiguration.solidCourseColors
    }

    private var brandRGB: ScheduleLiveActivityRGB {
        theme == .custom ? customColor : theme.brandColor
    }

    var brandColor: Color {
        let value = brandRGB
        return Color(red: value.red, green: value.green, blue: value.blue)
    }

    /// 纯色模式下课程卡片用的主题色；彩色模式为 `nil`，按课名分色。
    var solidCourseColor: ScheduleLiveActivityRGB? {
        solidCourseColors ? brandRGB : nil
    }

    func setTheme(_ value: ScheduleLiveActivityTheme) {
        theme = value
        persist()
    }

    func setCustomColor(_ value: ScheduleLiveActivityRGB) {
        customColor = value.clamped
        theme = .custom
        persist()
    }

    func setSolidCourseColors(_ value: Bool) {
        solidCourseColors = value
        persist()
    }

    private func persist() {
        defaults?.set(theme.rawValue, forKey: NextWidgetConfiguration.globalThemeKey)
        defaults?.set(theme.rawValue, forKey: NextWidgetConfiguration.liveActivityThemeKey)
        if let data = try? JSONEncoder().encode(customColor) {
            defaults?.set(data, forKey: NextWidgetConfiguration.globalCustomColorKey)
            defaults?.set(data, forKey: NextWidgetConfiguration.liveActivityCustomColorKey)
        }
        defaults?.set(solidCourseColors, forKey: NextWidgetConfiguration.solidCourseColorsKey)
        defaults?.synchronize()
        reloadScheduleWidgetTimelines()

        #if os(iOS)
        NativeLiveActivityController.shared.refreshForThemeChange()
        #endif
    }
}
