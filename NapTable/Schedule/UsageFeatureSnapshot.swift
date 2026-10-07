import Foundation
import WidgetKit
#if os(iOS)
import ActivityKit
#endif

@MainActor enum UsageFeatureSnapshot {
    static let widgetKeys = ["widget.upcoming.small", "widget.upcoming.medium", "widget.upcoming.large",
                             "widget.upcoming.inline", "widget.upcoming.circular", "widget.upcoming.rectangular",
                             "widget.twoday.large"]

    static func settings(widgets: [String: Bool] = [:]) -> [String: Bool] {
        let style = NativeThemeSettings.shared.style
        var states = Dictionary(uniqueKeysWithValues: ScheduleStyle.allCases.map { ("style." + $0.rawValue, $0 == style) })
        let preferences = NativeSchedulePreferences.shared
        let light = preferences.backgroundImage != nil
        let dark = preferences.backgroundImageDark != nil
        states["background"] = preferences.backgroundEnabled && (light || dark)
        states["separateBackgrounds"] = preferences.backgroundEnabled && light && dark
        let background = ScheduleWidgetBackgroundStore.shared
        if !background.settings.enabled || (!background.hasImage(dark: false) && !background.hasImage(dark: true)) {
            states["widgetBackground"] = false
        } else if !widgets.isEmpty {
            let hasHomeWidget = widgets.contains { key, active in
                active && (key.hasSuffix(".small") || key.hasSuffix(".medium") || key.hasSuffix(".large"))
            }
            let purchases = PurchaseManager.shared
            if !hasHomeWidget {
                states["widgetBackground"] = false
            } else if purchases.accessMode == .beta || (purchases.accessMode == .paid && purchases.state != .loading && purchases.state != .unavailable) {
                states["widgetBackground"] = purchases.allowsProFeatures && background.visibleImageURL(dark: false) != nil
            }
        }
        #if os(iOS)
        if #available(iOS 18.0, *) {
            let purchases = PurchaseManager.shared
            if !NativeLiveActivityController.shared.isEnabled || !ActivityAuthorizationInfo().areActivitiesEnabled {
                states["liveActivity"] = false
            } else if purchases.accessMode == .beta {
                states["liveActivity"] = purchases.allowsLiveActivities
            } else if purchases.accessMode == .paid && purchases.state != .loading && purchases.state != .unavailable {
                states["liveActivity"] = purchases.allowsLiveActivities
            }
            // A pending/failed entitlement lookup is unknown, not a user disabling the feature.
        } else {
            states["liveActivity"] = false
        }
        #else
        states["liveActivity"] = false
        #endif
        return states
    }

    static func widgets() async -> [String: Bool] {
        #if os(iOS)
        let keys: Set<String>? = await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { result in
                switch result {
                case .failure: continuation.resume(returning: nil)
                case .success(let widgets):
                    continuation.resume(returning: Set(widgets.compactMap { widget in
                        let kind: String
                        switch widget.kind {
                        case "com.niyiwei.naptable.widget.upcoming": kind = "upcoming"
                        case "com.niyiwei.naptable.widget.twoday": kind = "twoday"
                        default: return nil
                        }
                        let family: String
                        switch widget.family {
                        case .systemSmall: family = "small"
                        case .systemMedium: family = "medium"
                        case .systemLarge: family = "large"
                        case .accessoryInline: family = "inline"
                        case .accessoryCircular: family = "circular"
                        case .accessoryRectangular: family = "rectangular"
                        default: return nil
                        }
                        return "widget.\(kind).\(family)"
                    }))
                }
            }
        }
        guard let keys else { return [:] }
        return Dictionary(uniqueKeysWithValues: widgetKeys.map { ($0, keys.contains($0)) })
        #else
        return Dictionary(uniqueKeysWithValues: widgetKeys.map { ($0, false) })
        #endif
    }
}
