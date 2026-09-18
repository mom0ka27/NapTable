import Combine
import SwiftUI

/// One accent theme shared by the app, widgets, Live Activity and Dynamic Island.
@MainActor
final class NativeThemeSettings: ObservableObject {
    static let shared = NativeThemeSettings()

    @Published private(set) var theme: ScheduleLiveActivityTheme
    @Published private(set) var customColor: ScheduleLiveActivityRGB

    private let defaults: UserDefaults?

    private init() {
        defaults = UserDefaults(suiteName: NextWidgetConfiguration.appGroup)
        theme = NextWidgetConfiguration.globalTheme
        customColor = NextWidgetConfiguration.globalCustomColor
    }

    var brandColor: Color {
        let value = theme == .custom ? customColor : theme.brandColor
        return Color(red: value.red, green: value.green, blue: value.blue)
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

    private func persist() {
        defaults?.set(theme.rawValue, forKey: NextWidgetConfiguration.globalThemeKey)
        defaults?.set(theme.rawValue, forKey: NextWidgetConfiguration.liveActivityThemeKey)
        if let data = try? JSONEncoder().encode(customColor) {
            defaults?.set(data, forKey: NextWidgetConfiguration.globalCustomColorKey)
            defaults?.set(data, forKey: NextWidgetConfiguration.liveActivityCustomColorKey)
        }
        defaults?.synchronize()
        reloadScheduleWidgetTimelines()

        #if os(iOS)
        NativeLiveActivityController.shared.refreshForThemeChange()
        #endif
    }
}
