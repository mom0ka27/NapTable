import Foundation

/// The `complete.json` the Flutter app fetched from
/// `UPDATE_ROOT/complete.json` on every launch.
///
/// NapTable ships a snapshot instead of downloading it, so a first run still
/// works offline. One thing in that file is still useful here: the global
/// semester anchor, used when the selected school does not ship its own
/// calendar.
///
/// Snapshot of
/// `https://cdn.idealclover.cn/Projects/wheretosleepinnju/production/complete.json`
/// taken 2026-09-14 (`semester_start_monday: 2026-08-24`). It goes stale every
/// semester, exactly like the copy checked into the Flutter repository.
nonisolated enum BundledConfig {
    struct Complete: Decodable, Equatable {
        var title: String?
        var content: String?
        var semesterStartMonday: String?
        var delay: Int?

        private enum CodingKeys: String, CodingKey {
            case title, content, delay
            case semesterStartMonday = "semester_start_monday"
        }
    }

    /// `nil` when the resource is missing or malformed.
    static let complete: Complete? = loadComplete()

    /// Fallback for a school whose entry carries no `semesterStartMonday`.
    static var fallbackSemesterStartMonday: String? {
        let value = complete?.semesterStartMonday?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private static func loadComplete() -> Complete? {
        // Synchronized groups usually flatten resources into the bundle root,
        // but a folder reference would keep the `Resources` directory.
        let url = Bundle.main.url(forResource: "complete", withExtension: "json")
            ?? Bundle.main.url(forResource: "complete", withExtension: "json", subdirectory: "Resources")
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Complete.self, from: data)
    }
}
