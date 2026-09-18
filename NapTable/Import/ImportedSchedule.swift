import Foundation

/// The contract every importer produces: a table name plus course rows using the
/// same field names the Flutter app's extractor scripts emitted
/// (`week_time`, `start_time`, `time_count`, `import_type`, …).
nonisolated struct ImportedSchedule: Equatable, Identifiable {
    /// Identity for the confirmation sheet; a parsed schedule is transient.
    let id = UUID()
    var name: String
    var courses: [Course]
    /// Optional per-import overrides. Empty means "keep what the table has".
    var classTimeList: [ClassTime]?
    var semesterStartMonday: String?
    var schoolID: String?
    var termID: String?
    var termVersion: Int?
    var termWeekCount: Int?
    var termTimezone: String?
    /// 学期的调休安排，跟着学期配置一起进课表。
    var calendarAdjustments: [CalendarAdjustment]?

    init(
        name: String,
        courses: [Course],
        classTimeList: [ClassTime]? = nil,
        semesterStartMonday: String? = nil,
        schoolID: String? = nil,
        termID: String? = nil,
        termVersion: Int? = nil,
        termWeekCount: Int? = nil,
        termTimezone: String? = nil,
        calendarAdjustments: [CalendarAdjustment]? = nil
    ) {
        self.name = name
        self.courses = courses
        self.classTimeList = classTimeList
        self.semesterStartMonday = semesterStartMonday
        self.schoolID = schoolID; self.termID = termID; self.termVersion = termVersion; self.termWeekCount = termWeekCount; self.termTimezone = termTimezone
        self.calendarAdjustments = calendarAdjustments
    }

    var isEmpty: Bool { courses.isEmpty }

    /// The identity is only there to drive a sheet, so equality compares the
    /// payload a caller would actually act on.
    static func == (lhs: ImportedSchedule, rhs: ImportedSchedule) -> Bool {
        lhs.name == rhs.name
            && lhs.courses == rhs.courses
            && lhs.classTimeList == rhs.classTimeList
            && lhs.semesterStartMonday == rhs.semesterStartMonday
            && lhs.schoolID == rhs.schoolID && lhs.termID == rhs.termID && lhs.termVersion == rhs.termVersion && lhs.termWeekCount == rhs.termWeekCount && lhs.termTimezone == rhs.termTimezone
            && lhs.calendarAdjustments == rhs.calendarAdjustments
    }
}

/// Port of `lib/Utils/CourseImportCodec.dart`: the single place where the loose
/// online JSON shape becomes a `Course`. Rows arrive with `tableId`/`id` unset;
/// `AppStore.install` fills those in.
nonisolated enum CoursePayloadCodec {
    static func decode(json: String) throws -> ImportedSchedule {
        guard let data = json.data(using: .utf8) else {
            throw ImportError.malformedPayload("返回内容不是有效的 UTF-8")
        }
        return try decode(data: data)
    }

    static func decode(data: Data) throws -> ImportedSchedule {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ImportError.malformedPayload("无法解析课表 JSON：\(error.localizedDescription)")
        }
        return try decode(object: object)
    }

    static func decode(object: Any) throws -> ImportedSchedule {
        guard var root = object as? [String: Any] else {
            throw ImportError.malformedPayload("课表 JSON 顶层不是对象")
        }
        // Some extractors hand back `{"data": {...}}` or a quoted string.
        if let nested = root["data"] as? [String: Any], root["courses"] == nil {
            root = nested
        }
        let rawCourses = try flattenCourses(root["courses"])
        let name = (root["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let classTimes = (root["class_time_list"] as? [[String: Any]])?.compactMap { item -> ClassTime? in
            guard let start = item["start"] as? String, let end = item["end"] as? String else { return nil }
            return ClassTime(start: start, end: end)
        }
        let startMonday = (root["semester_start_monday"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let schoolID = root["schoolID"] as? String ?? root["school_id"] as? String
        let termID = root["termID"] as? String ?? root["term_id"] as? String
        let termVersion = (root["termVersion"] as? NSNumber)?.intValue ?? (root["term_version"] as? NSNumber)?.intValue
        let termWeekCount = (root["termWeekCount"] as? NSNumber)?.intValue ?? (root["term_week_count"] as? NSNumber)?.intValue
        let termTimezone = root["termTimezone"] as? String ?? root["term_timezone"] as? String
        let adjustments = decodeAdjustments(root["calendar_adjustments"] ?? root["calendarAdjustments"] ?? root["adjustments"])
        return ImportedSchedule(
            name: (name?.isEmpty == false ? name! : defaultTableName()),
            courses: rawCourses.compactMap(makeCourse),
            classTimeList: (classTimes?.isEmpty == false) ? classTimes : nil,
            semesterStartMonday: (startMonday?.isEmpty == false) ? startMonday : nil
            , schoolID: schoolID, termID: termID, termVersion: termVersion, termWeekCount: termWeekCount, termTimezone: termTimezone,
            calendarAdjustments: adjustments
        )
    }

    /// 调休列表：服务端下发的对象数组，字段缺失或类型不对的行直接丢掉。
    static func decodeAdjustments(_ value: Any?) -> [CalendarAdjustment]? {
        guard let list = value as? [[String: Any]] else { return nil }
        let items = list.compactMap { item -> CalendarAdjustment? in
            guard let date = (item["date"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  WeekCalculator.parseDay(date) != nil else { return nil }
            let kind = CalendarAdjustment.Kind(rawValue: (item["kind"] as? String) ?? "") ?? .off
            let source = (item["source"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            // 调课却没说上哪天的课，等于什么都没说，按放假处理会误删课程，直接丢弃。
            if kind == .swap, source == nil || WeekCalculator.parseDay(source ?? "") == nil { return nil }
            return CalendarAdjustment(date: date, kind: kind, source: source, note: (item["note"] as? String) ?? "")
        }
        return items.isEmpty ? nil : items
    }

    static func defaultTableName() -> String {
        let formatter = DateFormatter()
        formatter.calendar = WeekCalculator.calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = WeekCalculator.calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "导入课表 " + formatter.string(from: Date())
    }

    /// The Flutter app tolerated `courses` being a list, a JSON string of a
    /// list, or a JSON string of a JSON string.
    private static func flattenCourses(_ value: Any?) throws -> [[String: Any]] {
        guard let value else { return [] }
        if let list = value as? [[String: Any]] { return list }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            if let data = trimmed.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                if let list = decoded as? [[String: Any]] { return list }
                if let inner = decoded as? String,
                   let innerData = inner.data(using: .utf8),
                   let second = try? JSONSerialization.jsonObject(with: innerData, options: [.fragmentsAllowed]),
                   let list = second as? [[String: Any]] {
                    return list
                }
            }
            throw ImportError.malformedPayload("courses 字段不是课程列表")
        }
        throw ImportError.malformedPayload("courses 字段缺失")
    }

    static func makeCourse(from map: [String: Any]) -> Course? {
        let name = string(map, "name")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return nil }
        let weeks = normalizeWeeks(map["weeks"])
        let rawWeekTime = integer(map, "week_time", "weekTime") ?? 0
        let startTime = integer(map, "start_time", "startTime") ?? 0
        var timeCount = integer(map, "time_count", "timeCount") ?? 0
        // Free-time rows carry no slots at all; a fixed row with no length still
        // has to occupy one.
        let weekTime = min(max(rawWeekTime, 0), 7)
        let hasFixedSlot = weekTime > 0 && startTime > 0
        if hasFixedSlot, timeCount < 0 { timeCount = 0 }
        return Course(
            tableId: 0,
            name: name,
            weeks: weeks,
            // A payload with a weekday but no start period is still a
            // free-time row. Preserve that distinction instead of turning it
            // into a fabricated first-period class.
            weekTime: hasFixedSlot ? weekTime : 0,
            startTime: hasFixedSlot ? max(startTime, 1) : 0,
            timeCount: timeCount,
            importType: integer(map, "import_type", "importType") ?? ImportKind.imported,
            classroom: string(map, "classroom"),
            classNumber: string(map, "class_number", "classNumber"),
            teacher: string(map, "teacher"),
            testTime: string(map, "test_time", "testTime"),
            testLocation: string(map, "test_location", "testLocation"),
            link: string(map, "link"),
            info: string(map, "info"),
            color: string(map, "color"),
            courseKey: integer(map, "course_id", "courseId")
        )
    }

    private static func string(_ map: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            guard let value = map[key] else { continue }
            if value is NSNull { continue }
            if let text = value as? String { return text }
            if let number = value as? NSNumber { return number.stringValue }
        }
        return nil
    }

    private static func integer(_ map: [String: Any], _ keys: String...) -> Int? {
        for key in keys {
            guard let value = map[key] else { continue }
            if value is NSNull { continue }
            if let number = value as? NSNumber { return number.intValue }
            if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        return nil
    }

    /// `CourseImportCodec._normalizeWeeks`
    static func normalizeWeeks(_ value: Any?) -> [Int] {
        if let list = value as? [Any] {
            return list.compactMap { item -> Int? in
                if let number = item as? NSNumber { return number.intValue }
                if let text = item as? String { return Int(text) }
                return nil
            }.filter { $0 > 0 }
        }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return []
        }
        if let data = text.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let list = decoded as? [Any] {
            return list.compactMap { item -> Int? in
                if let number = item as? NSNumber { return number.intValue }
                if let string = item as? String { return Int(string) }
                return nil
            }.filter { $0 > 0 }
        }
        return matches(in: text, pattern: "\\d+").compactMap { Int($0) }.filter { $0 > 0 }
    }

    private static func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let value = Range(match.range, in: text) else { return nil }
            return String(text[value])
        }
    }
}

/// Errors shown by the import screens.
nonisolated enum ImportError: LocalizedError, Equatable {
    case malformedPayload(String)
    case emptyResult(String)
    case network(String)
    case login(String)
    case captcha
    case password
    case username
    case cancelled
    case notReady(String)

    var errorDescription: String? {
        switch self {
        case .malformedPayload(let message): return message
        case .emptyResult(let message): return message
        case .network(let message): return message
        case .login(let message): return message
        case .captcha: return "验证码错误，请重新输入"
        case .password: return "密码错误"
        case .username: return "用户名错误"
        case .cancelled: return "已取消导入"
        case .notReady(let message): return message
        }
    }
}
