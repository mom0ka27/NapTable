#if os(iOS) || LIVE_ACTIVITY_CHECKS
import Foundation

/// v2 uses explicit Unix seconds throughout; legacy attributes retain their Date codec.
nonisolated struct LiveActivityPlan: Codable, Equatable {
    struct Item: Codable, Equatable {
        var occurrenceId: String
        var supersedes: [String]
        var dateKey: String
        var startPeriod: Int
        var endPeriod: Int
    }
    struct BusyInterval: Codable, Equatable { var start: Double; var end: Double }
    var protocolVersion = 2
    var planRevision: Int
    var scheduleScope: String
    var schoolID: String
    var scheduleId = "default"
    var scheduleVersion: String
    var coverageStart: Double
    var coverageEndExclusive: Double
    var leadMinutes: Int
    var items: [Item]
    var busyIntervals: [BusyInterval]
    /// Only sent as `"token"`; a channel plan omits the key so its body and
    /// digest stay exactly what older builds uploaded.
    var pushMode: String? = nil
}

nonisolated struct LiveActivityMapping: Codable, Equatable {
    struct Period: Codable, Equatable { var number: Int; var start: String; var end: String }
    var schoolID: String
    var scheduleId: String
    var scheduleVersion: String
    var periods: [Period]
    var timeZone: String
    var channels: [String: String]
    var status: String
    var issuedAt: Double
    var createBefore: Double
    var broadcastUntil: Double
}

nonisolated struct LiveActivityOccurrence: Codable, Equatable {
    struct Frame: Codable, Equatable {
        var from: Double
        var until: Double
        var state: ScheduleLiveActivityAttributes.ContentState
    }
    var item: LiveActivityPlan.Item
    var sourceID: String
    var start: Double
    var end: Double
    var reminder: Double
    var frames: [Frame]

    func state(at date: Date) -> ScheduleLiveActivityAttributes.ContentState? {
        let instant = date.timeIntervalSince1970
        return frames.first { $0.from <= instant && instant < $0.until }?.state
    }

    /// When the display changes after the activity first renders: every frame
    /// start but the first (class start, per-period breaks, the reader's own
    /// course joining or leaving), plus the end of a frame followed by a gap.
    /// Token mode asks the server for a push at each of these. Instants more
    /// than a minute before `now` are dropped, as the server refuses them.
    func refreshAt(after now: Double = -.infinity) -> [Double] {
        let gaps = zip(frames, frames.dropFirst()).filter { $0.until != $1.from }.map { $0.0.until }
        return Set(frames.dropFirst().map(\.from) + gaps).filter { $0 >= now - 60 && $0 < end }.sorted()
    }
}

/// One token-mode activity as the server should know it: its token and the
/// instants to push at, never any course content.
nonisolated struct LiveActivityTokenRegistration: Equatable {
    var occurrenceId: String
    var token: String
    var dateKey: String
    var refreshAt: [Double]
    var end: Double
    /// Built from the unfiltered refresh list, so boundaries passing by do not
    /// make an unchanged registration look new.
    var signature: String
}

nonisolated struct LiveActivityDisplaySnapshot: Codable, Equatable {
    var scope: String
    var scheduleVersion: String
    var occurrences: [LiveActivityOccurrence]
    static let key = "naptable.liveActivity.v2.display"

    func resolve(attributes: ScheduleLiveActivityAttributes, at date: Date) -> ScheduleLiveActivityAttributes.ContentState? {
        guard attributes.protocolVersion == 2, attributes.scheduleScope == scope,
              attributes.scheduleVersion == scheduleVersion,
              let occurrence = occurrences.first(where: { $0.item.occurrenceId == attributes.occurrenceId && $0.item.dateKey == attributes.dateKey }) else { return nil }
        // ActivityKit may prepare a scheduled activity's view at registration,
        // before the reminder window. Render its initial frame in that case so
        // the cached view does not say there are no classes when it wakes up.
        // Keep state(at:) strict for scheduling and preserve the end boundary.
        return occurrence.state(at: max(date, Date(timeIntervalSince1970: occurrence.reminder)))
    }

    static func load() -> Self? {
        guard let data = UserDefaults(suiteName: NextWidgetConfiguration.appGroup)?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    static func resolveStored(attributes: ScheduleLiveActivityAttributes, at date: Date) -> ScheduleLiveActivityAttributes.ContentState? {
        guard let current = load(), current.scope == attributes.scheduleScope else { return nil }
        if current.scheduleVersion == attributes.scheduleVersion { return current.resolve(attributes: attributes, at: date) }
        let archives = UserDefaults(suiteName: NextWidgetConfiguration.appGroup)?.data(forKey: key + ".versions")
            .flatMap { try? JSONDecoder().decode([Self].self, from: $0) } ?? []
        return archives.first { $0.scope == attributes.scheduleScope && $0.scheduleVersion == attributes.scheduleVersion }?.resolve(attributes: attributes, at: date)
    }

    func save() throws {
        let data = try JSONEncoder().encode(self)
        guard let defaults = UserDefaults(suiteName: NextWidgetConfiguration.appGroup) else {
            throw NSError(domain: "LiveActivity", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法保存实时活动本地快照"])
        }
        // Keep the old clock's local display for already-active instances.
        // Scope validation above prevents an old selected table from reappearing.
        var archives = defaults.data(forKey: Self.key + ".versions").flatMap { try? JSONDecoder().decode([Self].self, from: $0) } ?? []
        if let previous = Self.load(), previous.scope == scope, previous.scheduleVersion != scheduleVersion {
            archives.removeAll { $0.scheduleVersion == previous.scheduleVersion }
            archives.append(previous)
        }
        let current = Date().timeIntervalSince1970
        archives = archives.filter { $0.scope == scope }.map { snapshot in
            var retained = snapshot
            retained.occurrences = snapshot.occurrences.filter { $0.end > current && $0.reminder < current + 8 * 86400 }
            return retained
        }.filter { !$0.occurrences.isEmpty }
        defaults.set(try JSONEncoder().encode(archives), forKey: Self.key + ".versions")
        // One replacement publishes the whole scope atomically to the widget.
        defaults.set(data, forKey: Self.key)
    }
}
#endif
