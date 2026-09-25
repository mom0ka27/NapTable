#if os(iOS) || LIVE_ACTIVITY_CHECKS
import Foundation

/// The server decides when each activity starts and ends; the phone decides
/// what it shows. Occurrences here are the app's own reading of today and
/// tomorrow, built from the local timetables, and exist only to render: an
/// activity is drawn from whatever local frame covers the moment within its
/// own time window, whatever the server called it.
nonisolated struct LiveActivityOccurrence: Codable, Equatable {
    struct Frame: Codable, Equatable {
        var from: Double
        var until: Double
        var state: ScheduleLiveActivityAttributes.ContentState
    }
    var dateKey: String
    var sourceID: String
    var start: Double
    var end: Double
    var reminder: Double
    var frames: [Frame]

    func state(at date: Date) -> ScheduleLiveActivityAttributes.ContentState? {
        let instant = date.timeIntervalSince1970
        return frames.first { $0.from <= instant && instant < $0.until }?.state
    }

    /// When the display next changes after `now`: a frame starting, or one
    /// ending into a gap. A local update goes stale then, so the system redraws.
    func nextChange(after now: Double) -> Double? {
        frames.flatMap { [$0.from, $0.until] }.filter { $0 > now }.min()
    }
}

/// One reminder the server handed to the phone's own reservations.
nonisolated struct LiveActivityClaim: Codable, Equatable {
    var occurrenceId: String
    var dateKey: String
    var reminder: Double
    var start: Double
    var end: Double
    var pushMode: String
    var scheduleScope: String
    var scheduleVersion: String
    var channel: String?
    var shared: [ScheduleLiveActivityAttributes.SharedCourse]

    /// The same attributes the server's own start would carry.
    func attributes(semester: String) -> ScheduleLiveActivityAttributes {
        .init(semester: semester, dateKey: dateKey, protocolVersion: 2, scheduleScope: scheduleScope, occurrenceId: occurrenceId,
              scheduleVersion: scheduleVersion, reservationStart: Date(timeIntervalSince1970: start), reservationEnd: Date(timeIntervalSince1970: end),
              broadcastChannel: pushMode == "token" ? nil : channel, reminderDate: Date(timeIntervalSince1970: reminder),
              pushMode: pushMode == "token" ? "token" : nil, shared: shared.isEmpty ? nil : shared)
    }
}

nonisolated struct LiveActivityDisplaySnapshot: Codable, Equatable {
    var scope: String
    /// Who the displayed timetable belongs to, when it is a followed share.
    var sourceLabel: String? = nil
    var occurrences: [LiveActivityOccurrence]
    static let key = "naptable.liveActivity.v2.display"

    /// What an activity shows at `date`: the local frame covering that moment
    /// within the activity's window. Rendered before the reminder (ActivityKit
    /// may prepare a scheduled activity's view at registration), it shows the
    /// opening frame; once the window closes, nothing.
    func resolve(attributes: ScheduleLiveActivityAttributes, at date: Date) -> ScheduleLiveActivityAttributes.ContentState? {
        guard attributes.protocolVersion == 2, attributes.scheduleScope == scope,
              let end = attributes.reservationEnd?.timeIntervalSince1970,
              let opening = (attributes.reminderDate ?? attributes.reservationStart)?.timeIntervalSince1970 else { return nil }
        let instant = max(date.timeIntervalSince1970, opening)
        guard instant < end else { return nil }
        let frames = occurrences.filter { $0.dateKey == attributes.dateKey && $0.reminder < end && $0.end > opening }
            .flatMap(\.frames).filter { $0.until > opening && $0.from < end }.sorted { $0.from < $1.from }
        // The server's reminder may lead the local one: count down with the next frame meanwhile.
        if let frame = frames.first(where: { $0.from <= instant && instant < $0.until }) ?? frames.first(where: { $0.from > instant }) {
            return frame.state
        }
        return shared(attributes, at: instant)
    }

    /// No local course in the window: the phone's copy of the share is older
    /// than the server's. The start push lists the share's classes itself.
    private func shared(_ attributes: ScheduleLiveActivityAttributes, at instant: Double) -> ScheduleLiveActivityAttributes.ContentState? {
        let classes = (attributes.shared ?? []).sorted { $0.start < $1.start }
        guard let course = classes.first(where: { $0.start <= instant && instant < $0.end }) ?? classes.first(where: { $0.start > instant }) else { return nil }
        let running = course.start <= instant
        return .init(phase: running ? .inProgress : .upcoming, courseName: course.name ?? "", teacher: course.teacher ?? "", location: course.location ?? "",
                     periodLabel: course.first == course.last ? "第 \(course.first) 节" : "第 \(course.first)–\(course.last) 节", dateLabel: attributes.dateKey,
                     startDate: Date(timeIntervalSince1970: course.start), endDate: Date(timeIntervalSince1970: course.end),
                     sourceLabel: sourceLabel, updatedAt: Date(timeIntervalSince1970: running ? course.start : instant))
    }

    /// When an activity's display next changes after `date`, for its stale date.
    func nextChange(attributes: ScheduleLiveActivityAttributes, after date: Date) -> Date? {
        guard let end = attributes.reservationEnd?.timeIntervalSince1970 else { return nil }
        let now = date.timeIntervalSince1970
        let next = occurrences.filter { $0.dateKey == attributes.dateKey }.compactMap { $0.nextChange(after: now) }.filter { $0 < end }.min()
        return Date(timeIntervalSince1970: next ?? end)
    }

    static func load() -> Self? {
        guard let data = UserDefaults(suiteName: NextWidgetConfiguration.appGroup)?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    static func resolveStored(attributes: ScheduleLiveActivityAttributes, at date: Date) -> ScheduleLiveActivityAttributes.ContentState? {
        load()?.resolve(attributes: attributes, at: date)
    }

    func save() throws {
        guard let defaults = UserDefaults(suiteName: NextWidgetConfiguration.appGroup) else {
            throw NSError(domain: "LiveActivity", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法保存实时活动本地快照"])
        }
        // One replacement publishes the whole scope atomically to the widget.
        defaults.set(try JSONEncoder().encode(self), forKey: Self.key)
        defaults.removeObject(forKey: Self.key + ".versions")
    }
}
#endif
