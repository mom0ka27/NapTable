import Foundation

@main
struct ScheduleStyleChecks {
    static func main() {
        let suite = "naptable.style-checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(ScheduleStyle.load(from: defaults) == .minimal)
        precondition(ScheduleStyle.load(from: nil) == .minimal)
        defaults.set("future-style", forKey: ScheduleStyle.storageKey)
        precondition(ScheduleStyle.load(from: defaults) == .minimal)
        defaults.set("blue", forKey: "scheduleGlobalTheme")
        for style in ScheduleStyle.allCases {
            defaults.set(style.rawValue, forKey: ScheduleStyle.storageKey)
            precondition(ScheduleStyle.load(from: defaults) == style)
            precondition(defaults.string(forKey: "scheduleGlobalTheme") == "blue")
            let data = try! JSONEncoder().encode(style)
            precondition(try! JSONDecoder().decode(ScheduleStyle.self, from: data) == style)
        }
        print("PASS: style persistence, unknown/missing defaults, color independence, Codable round-trip")
    }
}
