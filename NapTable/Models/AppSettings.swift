import Foundation
import SwiftUI

/// Preferences that belong to the timetable's *data*, and therefore travel with
/// the exported backup.
///
/// Everything that only changes how the grid is drawn — visible weekdays, row
/// height, card contents, background image — lives in
/// `NativeSchedulePreferences` instead, next to the surface that reads it. The
/// Flutter app's `SharedPreferences` carried a dozen more display flags here;
/// they were never read by this client and have been removed rather than left
/// as dead defaults. Unknown keys in an older saved file decode away silently.
struct AppSettings: Codable, Equatable {
    /// Number of teaching weeks available for swiping. Only used when the table
    /// is not bound to a school-provided term.
    var weekCount = SchoolDefaults.defaultWeekCount
    /// Light / dark / follow-system.
    var appearance = AppearancePreference.system
}

enum AppearancePreference: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var systemImage: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Everything the app persists. One JSON document keeps the timetable, the
/// settings and the id counters consistent with each other.
struct AppStateFile: Codable {
    var version = 1
    var settings = AppSettings()
    var tables: [CourseTable] = []
    var courses: [Course] = []
    var selectedTableId = 0
    var nextCourseId = 1
    var nextTableId = 1
    var nextCourseKey = 1
    /// Whether the bundled sample table has already been offered.
    var didSeedSample = false
}
