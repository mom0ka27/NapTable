import Foundation

// MARK: - Teaching slot table

/// The bell schedule. Mirrors the Flutter app's `Constant.CLASS_TIME_LIST` and
/// can be overridden per course table through `CourseTable.classTimeList`.
nonisolated struct ClassTime: Codable, Equatable, Hashable, Identifiable {
    var start: String
    var end: String

    var id: String { "\(start)-\(end)" }

    init(start: String, end: String) {
        self.start = start
        self.end = end
    }
}

nonisolated enum SchoolDefaults {
    /// `Config.MAX_CLASSES`
    static let maxClasses = 13
    /// `Config.MAX_WEEKS`
    static let maxWeeks = 25
    /// `Config.DEFAULT_WEEK_NUM`
    static let defaultWeekCount = 17
    /// `Config.HIDE_CLASS_COLOR`
    static let hiddenCourseColor = "#cccccc"
    /// `Config.default_class_table`
    static let defaultTableName = "默认课表"

    /// `Constant.CLASS_TIME_LIST`
    static let classTimeList: [ClassTime] = [
        ClassTime(start: "08:00", end: "08:50"),
        ClassTime(start: "09:00", end: "09:50"),
        ClassTime(start: "10:10", end: "11:00"),
        ClassTime(start: "11:10", end: "12:00"),
        ClassTime(start: "14:00", end: "14:50"),
        ClassTime(start: "15:00", end: "15:50"),
        ClassTime(start: "16:10", end: "17:00"),
        ClassTime(start: "17:10", end: "18:00"),
        ClassTime(start: "18:30", end: "19:20"),
        ClassTime(start: "19:30", end: "20:20"),
        ClassTime(start: "20:30", end: "21:20"),
        ClassTime(start: "21:30", end: "22:20"),
        ClassTime(start: "22:30", end: "23:59")
    ]

    /// `ColorUtil.colorList`
    static let colorList: [String] = [
        "#8AD297", "#F9A883", "#88CFCC", "#F19C99", "#F7C56B", "#D2A596",
        "#67BDDE", "#9CCF5A", "#9AB4CF", "#E593AD", "#E2C38A", "#B29FD2",
        "#E2C490", "#E2C490"
    ]
}

// MARK: - Course

/// A single course meeting. This is the Flutter app's `Course` row: the same
/// course name can produce several rows when it meets on different days or in
/// different week ranges, and overlapping rows are merged by `ScheduleLogic`.
nonisolated struct Course: Codable, Identifiable, Equatable, Hashable {
    /// Row identity. Assigned by the store; never reused.
    var id: Int
    /// Owning `CourseTable.id`.
    var tableId: Int
    var name: String
    /// Week numbers (1-based) in which this meeting happens. Serialised the same
    /// way the Flutter app stored it: a `[1,2,3]` style string.
    var weeks: [Int]
    /// 1 = Monday … 7 = Sunday. `0` marks a free-time course with no fixed slot.
    var weekTime: Int
    /// 1-based first teaching slot.
    var startTime: Int
    /// Slots occupied *after* `startTime` (mirrors the Flutter app: a 2-slot
    /// course stores `timeCount = 1`).
    var timeCount: Int
    var importType: Int
    var classroom: String?
    var classNumber: String?
    var teacher: String?
    var testTime: String?
    var testLocation: String?
    var link: String?
    var info: String?
    /// Explicit `#RRGGBB` override. Imported courses leave this empty and get a
    /// colour from the pool.
    var color: String?
    /// Stable identity of the course this row belongs to. Imported rows from the
    /// same course share it; hand-written rows get their own.
    var courseKey: Int?
    /// 导入时让位给同一时段另一节课的行。它留在课表里，但不参与显示、分享和
    /// 通知，之后可以在「隐藏的课程」里恢复。旧存档没有这个键，所以用可选值。
    var hidden: Bool?

    init(
        id: Int = 0,
        tableId: Int,
        name: String,
        weeks: [Int],
        weekTime: Int,
        startTime: Int,
        timeCount: Int,
        importType: Int,
        classroom: String? = nil,
        classNumber: String? = nil,
        teacher: String? = nil,
        testTime: String? = nil,
        testLocation: String? = nil,
        link: String? = nil,
        info: String? = nil,
        color: String? = nil,
        courseKey: Int? = nil,
        hidden: Bool? = nil
    ) {
        self.id = id
        self.tableId = tableId
        self.name = name
        self.weeks = weeks
        self.weekTime = weekTime
        self.startTime = startTime
        self.timeCount = timeCount
        self.importType = importType
        self.classroom = classroom
        self.classNumber = classNumber
        self.teacher = teacher
        self.testTime = testTime
        self.testLocation = testLocation
        self.link = link
        self.info = info
        self.color = color
        self.courseKey = courseKey
        self.hidden = hidden
    }

    /// 让位给别的课、暂时不显示的行。
    var isHidden: Bool { hidden == true }

    /// `Constant.ADD_MANUALLY`
    var isManual: Bool { importType == ImportKind.manual }
    /// `Constant.ADD_BY_IMPORT`
    var isImported: Bool { importType == ImportKind.imported }
    /// `Constant.ADD_BY_LECTURE`
    var isLecture: Bool { importType == ImportKind.lecture }

    /// Courses without a usable fixed slot are shown in the free-time area.
    /// Imported payloads use either `weekday == 0` or a missing start period
    /// for this case; a valid class always starts at period 1 or later.
    var isFreeTime: Bool { weekTime == 0 || startTime <= 0 }

    /// Inclusive last slot. A course with `timeCount = 0` occupies one slot.
    /// 饱和加法：解码时已经钳过范围，这里再兜一层，坏数据最多画错，不会溢出崩溃。
    var endTime: Int {
        let (sum, overflow) = startTime.addingReportingOverflow(max(0, timeCount))
        return overflow ? Int.max : sum
    }

    var displayClassroom: String {
        let value = classroom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "未知地点" : value
    }

    func contains(week: Int) -> Bool { weeks.contains(week) }

    /// 把各字段钳进 `CourseLimits`。分享、存档和 App Group 里的缓存都可能带着
    /// 越界的值（恶意分享的 `time_count = Int.max` 会让按节次循环的代码溢出或
    /// 卡死），所以每条解码路径都经过这里。
    func clamped() -> Course {
        var value = self
        if !CourseLimits.weekdays.contains(value.weekTime) { value.weekTime = 0 }
        value.startTime = min(max(value.startTime, 0), CourseLimits.slots.upperBound)
        value.timeCount = min(max(value.timeCount, 0), CourseLimits.maxTimeCount)
        var seen = Set<Int>()
        value.weeks = value.weeks.filter { CourseLimits.weeks.contains($0) && seen.insert($0).inserted }
        return value
    }
}

/// 课程字段的合法范围，比任何真实课表都宽，只用来挡住坏数据。
nonisolated enum CourseLimits {
    /// 节次。`startTime = 0` 另有含义（自由时间），所以不在这个范围里也保留。
    static let slots = 1...64
    /// `timeCount` 是起始节之后再占的节数（见 `Course.timeCount`），0 表示只占一节。
    static let maxTimeCount = 32
    static let weeks = 1...40
    /// 1 = 周一 … 7 = 周日，0 是自由时间。
    static let weekdays = 0...7
}

// 存档约定：`Course`、`CourseTable`、`AppStateFile` 以后新增的字段一律用可选类型
// （或者像这里一样手写 `decodeIfPresent` 给默认值）。合成的 `Decodable` 遇到缺键的
// 非可选字段会让整份存档解码失败，旧版本写的文件就会被当成损坏的。
extension Course {
    private enum CodingKeys: String, CodingKey {
        case id, tableId, name, weeks, weekTime, startTime, timeCount, importType
        case classroom, classNumber, teacher, testTime, testLocation, link, info, color, courseKey, hidden
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(Int.self, forKey: .id),
            tableId: try c.decode(Int.self, forKey: .tableId),
            name: try c.decode(String.self, forKey: .name),
            weeks: try c.decodeIfPresent([Int].self, forKey: .weeks) ?? [],
            weekTime: try c.decodeIfPresent(Int.self, forKey: .weekTime) ?? 0,
            startTime: try c.decodeIfPresent(Int.self, forKey: .startTime) ?? 0,
            timeCount: try c.decodeIfPresent(Int.self, forKey: .timeCount) ?? 0,
            importType: try c.decodeIfPresent(Int.self, forKey: .importType) ?? ImportKind.imported,
            classroom: try c.decodeIfPresent(String.self, forKey: .classroom),
            classNumber: try c.decodeIfPresent(String.self, forKey: .classNumber),
            teacher: try c.decodeIfPresent(String.self, forKey: .teacher),
            testTime: try c.decodeIfPresent(String.self, forKey: .testTime),
            testLocation: try c.decodeIfPresent(String.self, forKey: .testLocation),
            link: try c.decodeIfPresent(String.self, forKey: .link),
            info: try c.decodeIfPresent(String.self, forKey: .info),
            color: try c.decodeIfPresent(String.self, forKey: .color),
            courseKey: try c.decodeIfPresent(Int.self, forKey: .courseKey),
            hidden: try c.decodeIfPresent(Bool.self, forKey: .hidden)
        )
        self = clamped()
    }
}

nonisolated enum ImportKind {
    static let manual = 0
    static let imported = 1
    static let lecture = 2
}

// MARK: - Course table

/// A named timetable. The Flutter app allowed several of these and stored the
/// bell schedule and semester anchor alongside the name.
nonisolated struct CourseTable: Codable, Identifiable, Equatable, Hashable {
    var id: Int
    var name: String
    /// Per-table bell schedule override. Empty means `SchoolDefaults`.
    var classTimeList: [ClassTime]
    /// ISO `yyyy-MM-dd` of the Monday of week 1, when known.
    var semesterStartMonday: String
    var schoolID: String?
    var termID: String?
    var termVersion: Int?
    var termWeekCount: Int?
    var termTimezone: String?
    /// `false` marks a server share snapshot whose calendar must remain frozen.
    /// Optional keeps old on-disk tables decodable; nil follows current terms.
    var serviceConfigurationUpdatesEnabled: Bool?
    /// 这个学期的调休安排（补班改上哪天的课、哪天放假）。服务端按学期下发，
    /// 旧的存档里没有这个键，所以用可选类型解码。
    var calendarAdjustments: [CalendarAdjustment]?
    /// 是否按服务端的统一假期安排（国务院放假调休）调整课程。`false` 时这张课表
    /// 无视所有放假、补班，照常按星期几显示；`nil`（旧存档）当作开启。
    var unifiedHolidaysEnabled: Bool?

    init(
        id: Int = 0,
        name: String,
        classTimeList: [ClassTime] = [],
        semesterStartMonday: String = "",
        schoolID: String? = nil,
        termID: String? = nil,
        termVersion: Int? = nil,
        termWeekCount: Int? = nil,
        termTimezone: String? = nil,
        serviceConfigurationUpdatesEnabled: Bool? = nil,
        calendarAdjustments: [CalendarAdjustment]? = nil,
        unifiedHolidaysEnabled: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.classTimeList = classTimeList
        self.semesterStartMonday = semesterStartMonday
        self.schoolID = schoolID
        self.termID = termID
        self.termVersion = termVersion
        self.termWeekCount = termWeekCount
        self.termTimezone = termTimezone
        self.serviceConfigurationUpdatesEnabled = serviceConfigurationUpdatesEnabled
        self.calendarAdjustments = calendarAdjustments
        self.unifiedHolidaysEnabled = unifiedHolidaysEnabled
    }

    /// 日期 -> 调休，换算到 `anchor`（第一周周一）对应的教学周上。锚点由调用方
    /// 给：课表自己没填时，`AppStore` 用的是内置校历里的那个。
    func calendarAdjustmentIndex(anchor: String) -> [String: ResolvedCalendarAdjustment] {
        CalendarAdjustmentResolver.index(calendarAdjustments ?? [], semesterStartMonday: anchor)
    }

    /// The bell schedule actually used for rendering.
    var effectiveClassTimeList: [ClassTime] {
        classTimeList.isEmpty ? SchoolDefaults.classTimeList : classTimeList
    }

    var maxClasses: Int {
        max(SchoolDefaults.maxClasses, effectiveClassTimeList.count)
    }
}

// MARK: - Week series helpers

/// Port of the Flutter app's `_getWeekSeries` helpers, shared by the manual
/// editor and every importer.
nonisolated enum WeekSeries {
    static func full(from start: Int, to end: Int) -> [Int] {
        guard start <= end else { return [] }
        return Array(start...end)
    }

    static func single(from start: Int, to end: Int) -> [Int] {
        guard start <= end else { return [] }
        var value = start
        if value % 2 == 0 { value += 1 }
        return stride(from: value, through: end, by: 2).map { $0 }
    }

    static func double(from start: Int, to end: Int) -> [Int] {
        guard start <= end else { return [] }
        var value = start
        if value % 2 == 1 { value += 1 }
        return stride(from: value, through: end, by: 2).map { $0 }
    }

    /// `Constant.WEEK_TYPES`: 全部 / 单周 / 双周, plus the explicit week list the
    /// editor offers for irregular ranges.
    enum Kind: String, CaseIterable, Identifiable {
        case full
        case single
        case double
        case custom

        var id: String { rawValue }

        var title: String {
            switch self {
            case .full: return "全部"
            case .single: return "单周"
            case .double: return "双周"
            case .custom: return "指定"
            }
        }

        var constant: Int {
            switch self {
            case .full: return 0
            case .single: return 1
            case .double: return 2
            case .custom: return 3
            }
        }

        init(constant: Int) {
            switch constant {
            case 1: self = .single
            case 2: self = .double
            case 3: self = .custom
            default: self = .full
            }
        }
    }

    static func make(from start: Int, to end: Int, kind: Kind) -> [Int] {
        switch kind {
        case .full: return full(from: start, to: end)
        case .single: return single(from: start, to: end)
        case .double: return double(from: start, to: end)
        // A custom list has no range to expand; the caller supplies the values.
        case .custom: return full(from: start, to: end)
        }
    }

    /// Renders a week list as a compact summary (`第 1-5 周`, `第 1,3,5 周`).
    static func summary(_ weeks: [Int]) -> String {
        let sorted = Set(weeks).sorted()
        guard !sorted.isEmpty else { return "全部周" }
        var ranges: [String] = []
        var start = sorted[0]
        var previous = sorted[0]
        for value in sorted.dropFirst() {
            if value == previous + 1 {
                previous = value
                continue
            }
            ranges.append(start == previous ? "\(start)" : "\(start)-\(previous)")
            start = value
            previous = value
        }
        ranges.append(start == previous ? "\(start)" : "\(start)-\(previous)")
        return "第 " + ranges.joined(separator: ",") + " 周"
    }

    /// Picks the series a stored week list came from, so editing a course shows
    /// the same choice the user originally made.
    static func detectKind(_ weeks: [Int]) -> Kind {
        let sorted = Set(weeks).sorted()
        guard let first = sorted.first, let last = sorted.last else { return .full }
        if sorted.count == 1 { return .custom }
        if sorted == full(from: first, to: last) { return .full }
        if sorted == single(from: first, to: last) { return .single }
        if sorted == double(from: first, to: last) { return .double }
        return .custom
    }
}
