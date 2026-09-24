import Foundation

// MARK: - Schedule data model
//
// Ported from ../CPU-Web/ios_next (CpuTime) so the native schedule surface can be
// reused verbatim. These are the shapes the CpuTime UI renders; the adapter in
// `ScheduleStore.swift` fills them from NapTable's AppStore.

public enum NativeScheduleStoreError: LocalizedError, Equatable {
    case loaderUnavailable
    case webViewUnavailable
    case bridgeUnavailable
    case invalidResponse
    case unauthorized(String)
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .loaderUnavailable:
            return "课表服务尚未连接"
        case .webViewUnavailable:
            return "网页会话尚未准备好"
        case .bridgeUnavailable:
            return "暂时无法读取网页课表"
        case .invalidResponse:
            return "课表数据无法读取"
        case .unauthorized(let message):
            return message.trimmedNonEmpty ?? "教务授权已失效，请重新登录"
        case .server(let message):
            return message.trimmedNonEmpty ?? "课表服务暂时不可用"
        }
    }
}

public enum NativeScheduleSource: String, Codable, Sendable {
    case jwxt
    case graduate
    case cache
    case unknown

    public init(from decoder: Decoder) throws {
        let value = try String(from: decoder).lowercased()
        switch value {
        case "modern", "legacy", "undergraduate", "jwxt":
            self = .jwxt
        case "graduate":
            self = .graduate
        case "cache":
            self = .cache
        default:
            self = .unknown
        }
    }
}

public struct NativeScheduleAuth: Codable, Equatable, Sendable {
    public var authenticated: Bool
    public var identity: String?
    /// A non-reversible account fingerprint supplied by the web bridge. It
    /// scopes the on-disk timetable so a cold start never crosses accounts.
    public var account: String?

    public init(authenticated: Bool = false, identity: String? = nil, account: String? = nil) {
        self.authenticated = authenticated
        self.identity = identity
        self.account = account?.trimmedNonEmpty
    }
}

public struct NativeScheduleSemester: Codable, Identifiable, Equatable, Sendable {
    public let value: String
    public let label: String
    public let current: Bool

    public var id: String { value }

    /// Followed timetables are keyed `share:<code>` by ScheduleStore.
    public var isShared: Bool { value.hasPrefix("share:") }

    public init(value: String, label: String, current: Bool = false) {
        self.value = value
        self.label = label
        self.current = current
    }
}

public struct NativeScheduleWeek: Codable, Identifiable, Equatable, Sendable {
    public let value: String
    public let label: String
    public let current: Bool

    public var id: String { value }

    public init(value: String, label: String, current: Bool = false) {
        self.value = value
        self.label = label
        self.current = current
    }
}

public struct NativeScheduleCourse: Codable, Identifiable, Equatable, Sendable {
    /// Stable occurrence identity supplied by the trusted schedule bridge. It
    /// excludes mutable presentation fields such as room and teacher.
    public let liveActivitySourceID: String?
    public let nativeId: String?
    public let name: String
    public let teacher: String?
    public let weeks: String
    public let weekList: [Int]
    public let location: String?
    public let slotNote: String?
    public let startSlot: Int?
    public let endSlot: Int?
    public let sourceKey: String?
    public let customId: String?
    public let custom: Bool
    public let orphaned: Bool

    public var id: String {
        if let customId = customId?.trimmedNonEmpty { return "custom:\(customId)" }
        if let sourceKey = sourceKey?.trimmedNonEmpty { return sourceKey }
        return [name, teacher, location, weeks, startSlot.map(String.init), endSlot.map(String.init)]
            .compactMap { $0?.trimmedNonEmpty }
            .joined(separator: "|")
    }

    public init(
        liveActivitySourceID: String? = nil,
        nativeId: String? = nil,
        name: String,
        teacher: String? = nil,
        weeks: String = "",
        weekList: [Int] = [],
        location: String? = nil,
        slotNote: String? = nil,
        startSlot: Int? = nil,
        endSlot: Int? = nil,
        sourceKey: String? = nil,
        customId: String? = nil,
        custom: Bool = false,
        orphaned: Bool = false
    ) {
        self.liveActivitySourceID = liveActivitySourceID
        self.nativeId = nativeId?.trimmedNonEmpty
        self.name = name
        self.teacher = teacher?.trimmedNonEmpty
        self.weeks = weeks
        self.weekList = weekList
        self.location = location?.trimmedNonEmpty
        self.slotNote = slotNote?.trimmedNonEmpty
        self.startSlot = startSlot
        self.endSlot = endSlot
        self.sourceKey = sourceKey?.trimmedNonEmpty
        self.customId = customId?.trimmedNonEmpty
        self.custom = custom
        self.orphaned = orphaned
    }

    private enum CodingKeys: String, CodingKey {
        case liveActivitySourceID, nativeId, name, teacher, weeks, weekList, location, slotNote, startSlot, endSlot
        case sourceKey, customId, custom, orphaned
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            liveActivitySourceID: try values.decodeIfPresent(String.self, forKey: .liveActivitySourceID),
            nativeId: try values.decodeIfPresent(String.self, forKey: .nativeId),
            name: try values.decodeIfPresent(String.self, forKey: .name) ?? "课程",
            teacher: try values.decodeIfPresent(String.self, forKey: .teacher),
            weeks: try values.decodeIfPresent(String.self, forKey: .weeks) ?? "",
            weekList: try values.decodeIfPresent([Int].self, forKey: .weekList) ?? [],
            location: try values.decodeIfPresent(String.self, forKey: .location),
            slotNote: try values.decodeIfPresent(String.self, forKey: .slotNote),
            startSlot: try values.decodeIfPresent(Int.self, forKey: .startSlot),
            endSlot: try values.decodeIfPresent(Int.self, forKey: .endSlot),
            sourceKey: try values.decodeIfPresent(String.self, forKey: .sourceKey),
            customId: try values.decodeIfPresent(String.self, forKey: .customId),
            custom: try values.decodeIfPresent(Bool.self, forKey: .custom) ?? false,
            orphaned: try values.decodeIfPresent(Bool.self, forKey: .orphaned) ?? false
        )
    }
}

public struct NativeSchedulePeriod: Codable, Equatable, Sendable {
    public let number: Int
    public let startTime: String
    public let endTime: String

    /// Compatibility table for a deployed web bridge that predates the
    /// `periods` field. Keep this aligned with the web schedule slots.
    public static let bundledTimetable = [
        NativeSchedulePeriod(number: 1, startTime: "08:00", endTime: "08:45"),
        NativeSchedulePeriod(number: 2, startTime: "08:55", endTime: "09:40"),
        NativeSchedulePeriod(number: 3, startTime: "09:55", endTime: "10:40"),
        NativeSchedulePeriod(number: 4, startTime: "10:50", endTime: "11:35"),
        NativeSchedulePeriod(number: 5, startTime: "13:30", endTime: "14:15"),
        NativeSchedulePeriod(number: 6, startTime: "14:25", endTime: "15:10"),
        NativeSchedulePeriod(number: 7, startTime: "15:25", endTime: "16:10"),
        NativeSchedulePeriod(number: 8, startTime: "16:20", endTime: "17:05"),
        NativeSchedulePeriod(number: 9, startTime: "18:30", endTime: "19:15"),
        NativeSchedulePeriod(number: 10, startTime: "19:25", endTime: "20:10"),
        NativeSchedulePeriod(number: 11, startTime: "20:20", endTime: "21:05")
    ]

    /// Older bridges may report the former twelfth-slot marker. Clamp it to
    /// the last real period before native or Watch code looks up times.
    static func normalizedRange(
        bigSlot: Int,
        startSlot: Int?,
        endSlot: Int?,
        periods: [NativeSchedulePeriod]
    ) -> (start: Int, end: Int) {
        let available = periods.map(\.number)
        let minimum = available.min() ?? 1
        let maximum = available.max() ?? minimum
        let fallbackStart = min(max(bigSlot * 2 - 1, minimum), maximum)
        let fallbackEnd = min(max(bigSlot * 2, fallbackStart), maximum)
        let start = min(max(startSlot ?? fallbackStart, minimum), maximum)
        let end = min(max(endSlot ?? fallbackEnd, start), maximum)
        return (start, end)
    }

    public init(number: Int, startTime: String, endTime: String) {
        self.number = number
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// The same edit payload used by the Web timetable. Keeping this contract in
/// the native target lets the iOS editor persist through the authenticated Web
/// session instead of maintaining a second, incompatible edit store.
public struct NativeScheduleCustomItem: Codable, Equatable, Sendable {
    public var id: String
    public var sourceKey: String?
    public var day: Int
    public var bigSlot: Int
    public var course: NativeScheduleCourse

    public init(id: String, sourceKey: String? = nil, day: Int, bigSlot: Int, course: NativeScheduleCourse) {
        self.id = id
        self.sourceKey = sourceKey
        self.day = day
        self.bigSlot = bigSlot
        self.course = course
    }
}

public struct NativeScheduleEditState: Codable, Equatable, Sendable {
    public var hidden: [String]
    public var custom: [NativeScheduleCustomItem]

    public init(hidden: [String] = [], custom: [NativeScheduleCustomItem] = []) {
        self.hidden = hidden
        self.custom = custom
    }
}

public struct NativeScheduleCell: Codable, Identifiable, Equatable, Sendable {
    public let day: Int
    public let bigSlot: Int
    public let courses: [NativeScheduleCourse]

    public var id: String { "\(day)-\(bigSlot)" }

    public init(day: Int, bigSlot: Int, courses: [NativeScheduleCourse] = []) {
        self.day = day
        self.bigSlot = bigSlot
        self.courses = courses
    }
}

public struct NativeCalendarWeek: Codable, Identifiable, Equatable, Sendable {
    public let week: Int
    public let days: [String]
    public let monday: String
    public let sunday: String

    public var id: Int { week }

    public init(week: Int, days: [String] = [], monday: String = "", sunday: String = "") {
        self.week = week
        self.days = days
        self.monday = monday
        self.sunday = sunday
    }
}

public struct NativeScheduleCalendar: Codable, Equatable, Sendable {
    public let source: NativeScheduleSource?
    public let semesters: [NativeScheduleSemester]
    public let currentSemester: String
    public let currentWeek: Int
    public let semesterStart: String
    public let semesterEnd: String
    public let weeks: [NativeCalendarWeek]
    /// NapTable 独有：`yyyy-MM-dd` -> 这一天的调休安排。CpuTime 没有这个概念，
    /// 课表按日期覆盖星期几就全靠它（见 `CalendarAdjustment`）。
    public let adjustments: [String: ResolvedCalendarAdjustment]

    public init(
        source: NativeScheduleSource? = nil,
        semesters: [NativeScheduleSemester] = [],
        currentSemester: String = "",
        currentWeek: Int = 0,
        semesterStart: String = "",
        semesterEnd: String = "",
        weeks: [NativeCalendarWeek] = [],
        adjustments: [String: ResolvedCalendarAdjustment] = [:]
    ) {
        self.source = source
        self.semesters = semesters
        self.currentSemester = currentSemester
        self.currentWeek = currentWeek
        self.semesterStart = semesterStart
        self.semesterEnd = semesterEnd
        self.weeks = weeks
        self.adjustments = adjustments
    }

    private enum CodingKeys: String, CodingKey {
        case source, semesters, currentSemester, currentWeek, semesterStart, semesterEnd, weeks
        case adjustments
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            source: try values.decodeIfPresent(NativeScheduleSource.self, forKey: .source),
            semesters: try values.decodeIfPresent([NativeScheduleSemester].self, forKey: .semesters) ?? [],
            currentSemester: try values.decodeIfPresent(String.self, forKey: .currentSemester) ?? "",
            currentWeek: try values.decodeFlexibleInt(forKey: .currentWeek) ?? 0,
            semesterStart: try values.decodeIfPresent(String.self, forKey: .semesterStart) ?? "",
            semesterEnd: try values.decodeIfPresent(String.self, forKey: .semesterEnd) ?? "",
            weeks: try values.decodeIfPresent([NativeCalendarWeek].self, forKey: .weeks) ?? [],
            adjustments: try values.decodeIfPresent([String: ResolvedCalendarAdjustment].self, forKey: .adjustments) ?? [:]
        )
    }
}

public struct NativeScheduleResult: Codable, Equatable, Sendable {
    public let source: NativeScheduleSource?
    public let semesters: [NativeScheduleSemester]
    public let weeks: [NativeScheduleWeek]
    public let currentSemester: String
    public let currentWeek: String
    public let cells: [NativeScheduleCell]

    public init(
        source: NativeScheduleSource? = nil,
        semesters: [NativeScheduleSemester] = [],
        weeks: [NativeScheduleWeek] = [],
        currentSemester: String = "",
        currentWeek: String = "",
        cells: [NativeScheduleCell] = []
    ) {
        self.source = source
        self.semesters = semesters
        self.weeks = weeks
        self.currentSemester = currentSemester
        self.currentWeek = currentWeek
        self.cells = cells
    }

    private enum CodingKeys: String, CodingKey {
        case source, semesters, weeks, currentSemester, currentWeek, cells
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            source: try values.decodeIfPresent(NativeScheduleSource.self, forKey: .source),
            semesters: try values.decodeIfPresent([NativeScheduleSemester].self, forKey: .semesters) ?? [],
            weeks: try values.decodeIfPresent([NativeScheduleWeek].self, forKey: .weeks) ?? [],
            currentSemester: try values.decodeIfPresent(String.self, forKey: .currentSemester) ?? "",
            currentWeek: try values.decodeFlexibleString(forKey: .currentWeek) ?? "",
            cells: try values.decodeIfPresent([NativeScheduleCell].self, forKey: .cells) ?? []
        )
    }
}

public enum NativeScheduleState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case stale
    case unauthorized
    case failed
}

/// A lightweight native equivalent of Web's official timetable change notice.
/// The detailed edit state remains owned by the Web bridge; this value only
/// carries enough information for the native surface to prompt a re-check.
public struct NativeScheduleChangeNotice: Identifiable, Equatable, Sendable {
    public let id: String
    public let semester: String
    public let changedCount: Int
    public let details: [String]

    public init(id: String, semester: String, changedCount: Int, details: [String]) {
        self.id = id
        self.semester = semester
        self.changedCount = changedCount
        self.details = details
    }
}


// MARK: - Codable compatibility helpers

extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

extension KeyedDecodingContainer {
    func decodeFlexibleString(forKey key: Key) throws -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return String(Int(value)) }
        return nil
    }

    func decodeFlexibleInt(forKey key: Key) throws -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return Int(value.trimmedNonEmpty ?? "") }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        return nil
    }
}

// MARK: - Bell schedule row

/// One row of the timetable grid. The CpuTime surface hard-codes eleven rows;
/// NapTable's bell schedule is per course-table (13 by default, and some schools
/// ship 15), so the rows are filled in by `NativeScheduleStore` from the
/// selected table before the surface renders.
struct ScheduleSlot: Identifiable, Equatable {
    let number: Int
    let start: String
    let end: String

    var id: Int { number }

    static let fallback: [ScheduleSlot] = [
        ScheduleSlot(number: 1, start: "08:00", end: "08:45"),
        ScheduleSlot(number: 2, start: "08:55", end: "09:40"),
        ScheduleSlot(number: 3, start: "09:55", end: "10:40"),
        ScheduleSlot(number: 4, start: "10:50", end: "11:35"),
        ScheduleSlot(number: 5, start: "13:30", end: "14:15"),
        ScheduleSlot(number: 6, start: "14:25", end: "15:10"),
        ScheduleSlot(number: 7, start: "15:25", end: "16:10"),
        ScheduleSlot(number: 8, start: "16:20", end: "17:05"),
        ScheduleSlot(number: 9, start: "18:30", end: "19:15"),
        ScheduleSlot(number: 10, start: "19:25", end: "20:10"),
        ScheduleSlot(number: 11, start: "20:20", end: "21:05")
    ]

    static var all: [ScheduleSlot] = fallback
}
