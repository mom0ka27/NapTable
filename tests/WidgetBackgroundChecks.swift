import Foundation

// Standalone checks compile the storage contract without the app target.
enum NextWidgetConfiguration { static let appGroup = "test.naptable.widget-background" }

@main
struct WidgetBackgroundChecks {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "naptable.widget-background-checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let store = ScheduleWidgetBackgroundStore(directory: directory, defaults: defaults)
        precondition(store.visibleImageURL(dark: false) == nil)
        let light = Data("light-crop".utf8), dark = Data("dark-crop".utf8)
        let source = Data("original".utf8)
        let placement = ScheduleWidgetBackgroundStore.Placement(scale: 2, offsetX: 0.2, offsetY: -0.1)
        try store.save(cropped: light, source: source, placement: placement, dark: false)
        precondition(store.hasImage(dark: false) && !store.hasImage(dark: true))
        precondition(store.visibleImageURL(dark: false) == nil, "Locked users must not see Pro backgrounds")
        defaults.set(true, forKey: ScheduleWidgetBackgroundStore.entitlementKey)
        precondition(store.visibleImageURL(dark: true) == store.imageURL(dark: false), "Dark mode follows the sole photo")
        try store.save(cropped: dark, source: source, placement: .init(), dark: true)
        let savedDark = try Data(contentsOf: store.visibleImageURL(dark: true)!)
        let savedLight = try Data(contentsOf: store.visibleImageURL(dark: false)!)
        precondition(savedDark == dark && savedLight == light)
        let reopened = ScheduleWidgetBackgroundStore(directory: directory, defaults: defaults)
        precondition(reopened.settings.lightPlacement == placement)
        precondition(reopened.sourceData(dark: false) == source)
        var settings = reopened.settings
        settings.enabled = false
        settings.lightOpacity = 5
        settings.darkOpacity = -2
        try reopened.saveSettings(settings)
        precondition(reopened.visibleImageURL(dark: false) == nil)
        precondition(reopened.hasImage(dark: false), "Hiding must retain the photo")
        precondition(reopened.settings.opacity(dark: false) == 1 && reopened.settings.opacity(dark: true) == 0.1)
        settings.enabled = true
        try reopened.saveSettings(settings)
        try reopened.remove(dark: true)
        precondition(reopened.visibleImageURL(dark: true) == reopened.imageURL(dark: false))
        defaults.set(Date().addingTimeInterval(-60).timeIntervalSince1970, forKey: ScheduleWidgetBackgroundStore.expiryKey)
        precondition(reopened.visibleImageURL(dark: false) == nil, "Trial expiry applies even without reopening the app")
        defaults.removeObject(forKey: ScheduleWidgetBackgroundStore.expiryKey)
        precondition(reopened.visibleImageURL(dark: false) != nil)
        defaults.set(false, forKey: ScheduleWidgetBackgroundStore.entitlementKey)
        precondition(reopened.visibleImageURL(dark: false) == nil && reopened.hasImage(dark: false))
        try reopened.remove(dark: false)
        precondition(!reopened.hasImage(dark: false) && reopened.sourceData(dark: false) == nil)
        print("PASS: widget background storage, light/dark fallback, placement, opacity, hiding, entitlement and removal")
    }
}
