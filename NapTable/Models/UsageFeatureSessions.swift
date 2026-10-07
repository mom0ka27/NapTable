import Foundation

/// Only random interval IDs leave the device, never image paths or local timestamps.
enum UsageFeatureSessions {
    static let storageKey = "naptable.usage.featureSessions"

    static func observe(_ states: [String: Bool], defaults: UserDefaults) -> [String: String] {
        var sessions = defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
        let previous = sessions
        var report: [String: String] = [:]
        for (key, active) in states {
            if active {
                let session = sessions[key] ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                sessions[key] = session
                report[key] = session
            } else {
                sessions.removeValue(forKey: key)
                report[key] = ""
            }
        }
        // Missing keys mean unknown (e.g. WidgetKit failed), never disabled.
        if sessions != previous { defaults.set(sessions, forKey: storageKey) }
        return report
    }
}
