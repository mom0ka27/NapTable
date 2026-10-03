import Foundation

nonisolated struct CloudCaringSelection: Codable, Equatable {
    var code: String?
}

/// Decode old documents only. This payload is discarded before merging or
/// saving, and never reads or changes the device's Live Activity preferences.
nonisolated struct LegacyCloudNotificationPreferences: Codable, Equatable {
    var enabled: Bool
    var leadMinutes: Int
    var sharedLeadMinutes: Int?
    var perPeriod: Bool
}
