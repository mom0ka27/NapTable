import Foundation

/// Shared files, rather than large UserDefaults values, let the app and widget
/// extension read the same background without copying photos into timelines.
struct ScheduleWidgetBackgroundStore {
    struct Placement: Codable, Equatable {
        var scale: Double = 1
        var offsetX: Double = 0
        var offsetY: Double = 0
    }

    struct Settings: Codable, Equatable {
        var enabled = true
        var lightOpacity = 0.18
        var darkOpacity = 0.28
        var lightPlacement = Placement()
        var darkPlacement = Placement()

        func opacity(dark: Bool) -> Double {
            let value = dark ? darkOpacity : lightOpacity
            return value.isFinite ? min(1, max(0.1, value)) : (dark ? 0.28 : 0.18)
        }
    }

    static let settingsKey = "naptable.widgetBackground.settings"
    static let entitlementKey = "naptable.widgetBackground.allowed"
    static let expiryKey = "naptable.widgetBackground.expiresAt"
    let directory: URL?
    let defaults: UserDefaults?

    init(directory: URL?, defaults: UserDefaults?) {
        self.directory = directory
        self.defaults = defaults
    }

    static var shared: Self {
        Self(directory: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: NextWidgetConfiguration.appGroup)?
            .appendingPathComponent("WidgetBackgrounds", isDirectory: true),
             defaults: UserDefaults(suiteName: NextWidgetConfiguration.appGroup))
    }

    var settings: Settings {
        guard let data = defaults?.data(forKey: Self.settingsKey),
              let value = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return value
    }

    func saveSettings(_ value: Settings) throws {
        guard let defaults else { throw CocoaError(.fileWriteUnknown) }
        defaults.set(try JSONEncoder().encode(value), forKey: Self.settingsKey)
        defaults.synchronize()
    }

    func imageURL(dark: Bool, source: Bool = false) -> URL? {
        directory?.appendingPathComponent("\(dark ? "dark" : "light")\(source ? "-source" : "").jpg")
    }

    func hasImage(dark: Bool) -> Bool {
        imageURL(dark: dark).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    func visibleImageURL(dark: Bool) -> URL? {
        guard defaults?.bool(forKey: Self.entitlementKey) == true, settings.enabled else { return nil }
        if let expiry = defaults?.object(forKey: Self.expiryKey) as? Double,
           expiry <= Date().timeIntervalSince1970 { return nil }
        return hasImage(dark: dark) ? imageURL(dark: dark)
            : (hasImage(dark: !dark) ? imageURL(dark: !dark) : nil)
    }

    func sourceData(dark: Bool) -> Data? {
        guard let url = imageURL(dark: dark) else { return nil }
        return imageURL(dark: dark, source: true).flatMap { try? Data(contentsOf: $0) }
            ?? (try? Data(contentsOf: url))
    }

    func save(cropped: Data, source: Data, placement: Placement, dark: Bool) throws {
        guard let directory, let url = imageURL(dark: dark),
              let sourceURL = imageURL(dark: dark, source: true) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try source.write(to: sourceURL, options: .atomic)
        try cropped.write(to: url, options: .atomic)
        var value = settings
        if dark { value.darkPlacement = placement } else { value.lightPlacement = placement }
        try saveSettings(value)
    }

    func remove(dark: Bool) throws {
        for source in [false, true] {
            if let url = imageURL(dark: dark, source: source), FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        var value = settings
        if dark { value.darkPlacement = Placement() } else { value.lightPlacement = Placement() }
        try saveSettings(value)
    }
}
