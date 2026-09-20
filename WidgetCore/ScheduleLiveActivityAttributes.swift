#if os(iOS) || LIVE_ACTIVITY_CHECKS
import ActivityKit
import Foundation

/// Shared wire model for the iPhone Live Activity and its WidgetKit view.
/// This file is compiled into both the app and the widget extension, exactly as
/// in `../CPU-Web/ios_next` (CpuTime) `CPUWebWidgets/ScheduleLiveActivityAttributes.swift`.
nonisolated public struct ScheduleLiveActivityAttributes: ActivityAttributes, Equatable {
    public struct ContentState: Codable, Hashable {
        public enum Phase: String, Codable, Hashable {
            case upcoming
            case inProgress
        }

        public let phase: Phase
        public let courseName: String
        public let teacher: String
        public let location: String
        /// Optional fields keep activities created by an older app version
        /// decodable while giving the Watch mirrored activity more context.
        public let periodLabel: String?
        public let dateLabel: String?
        /// The course's published week range (for example, "1-16周").
        /// Optional so activities created before this field was introduced
        /// remain decodable.
        public let weekRangeLabel: String?
        public let startDate: Date
        public let endDate: Date
        public let nextCourseName: String?
        public let nextCoursePeriod: String?
        public let nextCourseDateLabel: String?
        public let nextCourseWeekRangeLabel: String?
        public let nextCourseTeacher: String?
        public let nextCourseLocation: String?
        public let nextCourseStart: Date?
        public let nextCourseEnd: Date?
        public let sourceLabel: String?
        /// 调休说明，例如「国庆节放假」或「上周一的课」。空表示这天照常上课。
        /// Optional so an activity started before this field existed still
        /// decodes.
        public let adjustmentNote: String?
        public let updatedAt: Date
        /// Compact school broadcast marker. When present, the widget resolves
        /// the visible course from the timetable stored in the App Group.
        public let broadcastDateKey: String?
        public let broadcastPeriod: Int?
        public let broadcastPhase: String?
        public let broadcastTimestamp: Date?

        /// A persisted activity can render after its deadline. Keep its timer
        /// interval valid even when a late update arrives after the course ends.
        public var countdownInterval: ClosedRange<Date> {
            let deadline = phase == .inProgress ? endDate : startDate
            return min(updatedAt, deadline)...deadline
        }

        /// What the activity should show once this course is over: the next
        /// course of the same day, or `nil` when the school day is done.
        /// Drives both the stale render in the widget and the background
        /// reconcile in the app, so the two cannot drift apart.
        public var afterEndState: ContentState? {
            guard let name = nextCourseName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty,
                  let start = nextCourseStart,
                  let end = nextCourseEnd,
                  Self.isSameDay(start, endDate) else { return nil }
            return ContentState(
                phase: .upcoming,
                courseName: name,
                teacher: nextCourseTeacher ?? "",
                location: nextCourseLocation ?? "",
                periodLabel: nextCoursePeriod,
                dateLabel: nextCourseDateLabel ?? dateLabel,
                weekRangeLabel: nextCourseWeekRangeLabel,
                startDate: start,
                endDate: end,
                sourceLabel: sourceLabel,
                adjustmentNote: adjustmentNote,
                updatedAt: endDate
            )
        }

        /// 调休说明，去掉空白后为空就当没有。
        public var normalizedAdjustmentNote: String? {
            guard let value = adjustmentNote?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }

        /// A break can be hours long, where a minutes-only timer would read
        /// "138:20". A class period never needs the hours field.
        public var countdownShowsHours: Bool {
            let interval = countdownInterval
            return interval.upperBound.timeIntervalSince(interval.lowerBound) >= 3600
        }

        private static func isSameDay(_ lhs: Date, _ rhs: Date) -> Bool {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
            return calendar.isDate(lhs, inSameDayAs: rhs)
        }

        public init(
            phase: Phase,
            courseName: String,
            teacher: String = "",
            location: String = "",
            periodLabel: String? = nil,
            dateLabel: String? = nil,
            weekRangeLabel: String? = nil,
            startDate: Date,
            endDate: Date,
            nextCourseName: String? = nil,
            nextCoursePeriod: String? = nil,
            nextCourseDateLabel: String? = nil,
            nextCourseWeekRangeLabel: String? = nil,
            nextCourseTeacher: String? = nil,
            nextCourseLocation: String? = nil,
            nextCourseStart: Date? = nil,
            nextCourseEnd: Date? = nil,
            sourceLabel: String? = nil,
            adjustmentNote: String? = nil,
            updatedAt: Date = .now,
            broadcastDateKey: String? = nil,
            broadcastPeriod: Int? = nil,
            broadcastPhase: String? = nil,
            broadcastTimestamp: Date? = nil
        ) {
            self.phase = phase
            self.courseName = courseName
            self.teacher = teacher
            self.location = location
            self.periodLabel = periodLabel
            self.dateLabel = dateLabel
            self.weekRangeLabel = weekRangeLabel
            self.startDate = startDate
            self.endDate = endDate
            self.nextCourseName = nextCourseName
            self.nextCoursePeriod = nextCoursePeriod
            self.nextCourseDateLabel = nextCourseDateLabel
            self.nextCourseWeekRangeLabel = nextCourseWeekRangeLabel
            self.nextCourseTeacher = nextCourseTeacher
            self.nextCourseLocation = nextCourseLocation
            self.nextCourseStart = nextCourseStart
            self.nextCourseEnd = nextCourseEnd
            self.sourceLabel = sourceLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.adjustmentNote = adjustmentNote?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.updatedAt = updatedAt
            self.broadcastDateKey = broadcastDateKey
            self.broadcastPeriod = broadcastPeriod
            self.broadcastPhase = broadcastPhase
            self.broadcastTimestamp = broadcastTimestamp
        }

        // MARK: Wire format

        /// Instants are coded as Unix seconds instead of as `Date`.
        ///
        /// A Live Activity can also arrive as a push, and ActivityKit decodes
        /// that `content-state` with a `JSONDecoder` this app never gets to
        /// configure. Relying on the synthesised `Date` coding would mean
        /// betting on which date strategy ActivityKit picked; coding the
        /// instants explicitly removes the bet and keeps the JSON the push
        /// server relays readable.
        private enum CodingKeys: String, CodingKey {
            case phase, courseName, teacher, location, periodLabel, dateLabel, weekRangeLabel
            case startDate, endDate, nextCourseName, nextCoursePeriod, nextCourseDateLabel
            case nextCourseWeekRangeLabel, nextCourseTeacher, nextCourseLocation
            case nextCourseStart, nextCourseEnd, sourceLabel, adjustmentNote, updatedAt
            case broadcastDateKey, broadcastPeriod, broadcastPhase, broadcastTimestamp
        }

        /// An activity started by an earlier build outlives the app update that
        /// installs this one, and its stored content coded dates against
        /// Foundation's 2001 reference date. Those values are three decades
        /// smaller than a Unix timestamp for the same instant, so a threshold
        /// anywhere inside that gap tells the two apart.
        private static func instant(_ seconds: Double) -> Date {
            seconds < 1_000_000_000
                ? Date(timeIntervalSinceReferenceDate: seconds)
                : Date(timeIntervalSince1970: seconds)
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            phase = try values.decodeIfPresent(Phase.self, forKey: .phase) ?? .upcoming
            courseName = try values.decodeIfPresent(String.self, forKey: .courseName) ?? ""
            teacher = try values.decodeIfPresent(String.self, forKey: .teacher) ?? ""
            location = try values.decodeIfPresent(String.self, forKey: .location) ?? ""
            periodLabel = try values.decodeIfPresent(String.self, forKey: .periodLabel)
            dateLabel = try values.decodeIfPresent(String.self, forKey: .dateLabel)
            weekRangeLabel = try values.decodeIfPresent(String.self, forKey: .weekRangeLabel)
            let fallback = Date()
            startDate = try values.decodeIfPresent(Double.self, forKey: .startDate).map(Self.instant) ?? fallback
            endDate = try values.decodeIfPresent(Double.self, forKey: .endDate).map(Self.instant) ?? startDate
            nextCourseName = try values.decodeIfPresent(String.self, forKey: .nextCourseName)
            nextCoursePeriod = try values.decodeIfPresent(String.self, forKey: .nextCoursePeriod)
            nextCourseDateLabel = try values.decodeIfPresent(String.self, forKey: .nextCourseDateLabel)
            nextCourseWeekRangeLabel = try values.decodeIfPresent(String.self, forKey: .nextCourseWeekRangeLabel)
            nextCourseTeacher = try values.decodeIfPresent(String.self, forKey: .nextCourseTeacher)
            nextCourseLocation = try values.decodeIfPresent(String.self, forKey: .nextCourseLocation)
            nextCourseStart = try values.decodeIfPresent(Double.self, forKey: .nextCourseStart).map(Self.instant)
            nextCourseEnd = try values.decodeIfPresent(Double.self, forKey: .nextCourseEnd).map(Self.instant)
            sourceLabel = try values.decodeIfPresent(String.self, forKey: .sourceLabel)
            adjustmentNote = try values.decodeIfPresent(String.self, forKey: .adjustmentNote)
            updatedAt = try values.decodeIfPresent(Double.self, forKey: .updatedAt).map(Self.instant) ?? fallback
            broadcastDateKey = try values.decodeIfPresent(String.self, forKey: .broadcastDateKey)
            broadcastPeriod = try values.decodeIfPresent(Int.self, forKey: .broadcastPeriod)
            broadcastPhase = try values.decodeIfPresent(String.self, forKey: .broadcastPhase)
            broadcastTimestamp = try values.decodeIfPresent(Double.self, forKey: .broadcastTimestamp).map(Self.instant)
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(phase, forKey: .phase)
            try values.encode(courseName, forKey: .courseName)
            try values.encode(teacher, forKey: .teacher)
            try values.encode(location, forKey: .location)
            try values.encodeIfPresent(periodLabel, forKey: .periodLabel)
            try values.encodeIfPresent(dateLabel, forKey: .dateLabel)
            try values.encodeIfPresent(weekRangeLabel, forKey: .weekRangeLabel)
            try values.encode(startDate.timeIntervalSince1970, forKey: .startDate)
            try values.encode(endDate.timeIntervalSince1970, forKey: .endDate)
            try values.encodeIfPresent(nextCourseName, forKey: .nextCourseName)
            try values.encodeIfPresent(nextCoursePeriod, forKey: .nextCoursePeriod)
            try values.encodeIfPresent(nextCourseDateLabel, forKey: .nextCourseDateLabel)
            try values.encodeIfPresent(nextCourseWeekRangeLabel, forKey: .nextCourseWeekRangeLabel)
            try values.encodeIfPresent(nextCourseTeacher, forKey: .nextCourseTeacher)
            try values.encodeIfPresent(nextCourseLocation, forKey: .nextCourseLocation)
            try values.encodeIfPresent(nextCourseStart?.timeIntervalSince1970, forKey: .nextCourseStart)
            try values.encodeIfPresent(nextCourseEnd?.timeIntervalSince1970, forKey: .nextCourseEnd)
            try values.encodeIfPresent(sourceLabel, forKey: .sourceLabel)
            try values.encodeIfPresent(adjustmentNote, forKey: .adjustmentNote)
            try values.encode(updatedAt.timeIntervalSince1970, forKey: .updatedAt)
            try values.encodeIfPresent(broadcastDateKey, forKey: .broadcastDateKey)
            try values.encodeIfPresent(broadcastPeriod, forKey: .broadcastPeriod)
            try values.encodeIfPresent(broadcastPhase, forKey: .broadcastPhase)
            try values.encodeIfPresent(broadcastTimestamp?.timeIntervalSince1970, forKey: .broadcastTimestamp)
        }
    }

    public let semester: String
    public let dateKey: String
    public let week: Int

    public init(semester: String, dateKey: String, week: Int = 0) {
        self.semester = semester
        self.dateKey = dateKey
        self.week = week
    }

    /// The activity should open the exact timetable context represented by the
    /// island. Keeping the query in the shared model means the app and the
    /// widget extension cannot drift apart when a user taps the activity.
    public var deepLinkURL: URL {
        var components = URLComponents()
        components.scheme = "naptable"
        components.host = "schedule"
        components.queryItems = [
            URLQueryItem(name: "source", value: "live-activity"),
            URLQueryItem(name: "semester", value: semester.isEmpty ? nil : semester),
            URLQueryItem(name: "week", value: week > 0 ? String(week) : nil),
        ].filter { $0.value != nil }
        return components.url ?? URL(string: "naptable://schedule")!
    }
}
#endif
