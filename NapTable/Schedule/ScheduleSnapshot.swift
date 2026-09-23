import Foundation

/// One resolved timetable payload plus the surrounding metadata the companion
/// features need (widget, Live Activity, calendar import).
///
/// Ported from `../CPU-Web/ios_next` (CpuTime) `NativeScheduleSnapshot`. CpuTime
/// assembles it from its Web bridge; NapTable has no network step, so the store
/// builds the same shape directly out of `AppStore`.
///
/// `completeSemester` is always true here: NapTable holds the whole table, never
/// a single week fetched from 教务, so a week filter is a view concern only.
public struct NativeScheduleSnapshot: Codable, Equatable, Sendable {
    public let scheduleScope: String?
    public let version: Int
    public let completeSemester: Bool
    /// True when a newer selection superseded this request before it could
    /// produce a usable schedule. A normal race outcome, not an error.
    public let cancelled: Bool
    public let source: NativeScheduleSource
    public let fetchedAt: Date?
    public let periods: [NativeSchedulePeriod]
    public let data: NativeScheduleResult?
    public let calendar: NativeScheduleCalendar?
    public let auth: NativeScheduleAuth
    public let sourceLabel: String?
    /// Identifies the school's broadcast channel. It is metadata only; the
    /// timetable itself remains local to the device.
    public let schoolID: String?
    public let termID: String?
    public let timeZone: String?
    public let error: String?

    public init(
        scheduleScope: String? = nil,
        version: Int = 1,
        completeSemester: Bool = false,
        cancelled: Bool = false,
        source: NativeScheduleSource = .unknown,
        fetchedAt: Date? = nil,
        periods: [NativeSchedulePeriod] = [],
        data: NativeScheduleResult? = nil,
        calendar: NativeScheduleCalendar? = nil,
        auth: NativeScheduleAuth = NativeScheduleAuth(),
        sourceLabel: String? = nil,
        schoolID: String? = nil,
        termID: String? = nil,
        timeZone: String? = nil,
        error: String? = nil
    ) {
        self.scheduleScope = scheduleScope
        self.version = version
        self.completeSemester = completeSemester
        self.cancelled = cancelled
        self.source = source
        self.fetchedAt = fetchedAt
        self.periods = periods.isEmpty ? NativeSchedulePeriod.bundledTimetable : periods
        self.data = data
        self.calendar = calendar
        self.auth = auth
        self.sourceLabel = sourceLabel?.trimmedNonEmpty
        self.schoolID = schoolID?.trimmedNonEmpty
        self.termID = termID?.trimmedNonEmpty
        self.timeZone = timeZone?.trimmedNonEmpty
        self.error = error?.trimmedNonEmpty
    }
}
