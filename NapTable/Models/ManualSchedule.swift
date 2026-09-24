import Foundation

// MARK: - 手动创建课表的草稿

/// 学校不在列表里时，用户自己一步步填出来的课表：学期、节次、课程。
///
/// 整个向导只改这份草稿，最后一步才由 `AppStore.installManualSchedule` 写进库，
/// 中途退出不会留下半张课表。
nonisolated struct ManualScheduleDraft: Equatable {
    var name: String
    /// 第一周的星期一，`yyyy-MM-dd`。
    var semesterStartMonday: String
    var weekCount: Int
    var classTimes: [ClassTime]
    var courses: [ManualCourseDraft]

    init(
        name: String = "",
        semesterStartMonday: String = WeekCalculator.format(WeekCalculator.monday(of: Date())),
        weekCount: Int = SchoolDefaults.defaultWeekCount,
        classTimes: [ClassTime] = SchoolDefaults.classTimeList,
        courses: [ManualCourseDraft] = []
    ) {
        self.name = name
        self.semesterStartMonday = semesterStartMonday
        self.weekCount = weekCount
        self.classTimes = classTimes
        self.courses = courses
    }

    static let weekCountRange = 1...40
    static let maxPeriods = 20

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 节次表的第一个问题，给向导直接显示；没问题是 `nil`。
    var classTimesProblem: String? {
        ClassTimeValidator.problem(in: classTimes)
    }

    /// 同一时间撞在一起的课，给用户一句提醒。课表能并排画出来，所以不拦着保存，
    /// 但多半是填错了周次或节次。
    var overlapWarnings: [String] {
        struct Slot { let name: String; let meeting: ManualMeetingDraft; let weeks: Set<Int> }
        let slots = courses.flatMap { course in
            course.meetings.map { Slot(name: course.trimmedName, meeting: $0, weeks: Set($0.weeks(weekCount: weekCount))) }
        }
        var warnings: [String] = []
        for i in slots.indices {
            for j in slots.indices where j > i {
                let a = slots[i], b = slots[j]
                guard a.meeting.weekday == b.meeting.weekday,
                      a.meeting.startPeriod <= b.meeting.endPeriod,
                      b.meeting.startPeriod <= a.meeting.endPeriod else { continue }
                let shared = a.weeks.intersection(b.weeks)
                guard !shared.isEmpty else { continue }
                let day = WeekCalculator.weekdayName(a.meeting.weekday)
                warnings.append("「\(a.name)」和「\(b.name)」\(WeekSeries.summary(Array(shared))) \(day)时间重叠")
            }
        }
        return warnings
    }

    /// 课程写进库时的行：一门课的每个上课时间一行，同一门课共用 `courseKey`。
    func courseRows(tableId: Int) -> [[Course]] {
        courses.map { $0.rows(tableId: tableId, weekCount: weekCount) }
    }
}

/// 一门课：名字、老师，以及一个或多个上课时间（比如周一 1-2 节 + 周三 3-4 节）。
nonisolated struct ManualCourseDraft: Identifiable, Equatable {
    var id = UUID()
    var name: String = ""
    var teacher: String = ""
    var meetings: [ManualMeetingDraft] = [ManualMeetingDraft()]

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 保存前的检查。`nil` 表示可以保存。
    func problem(periodCount: Int, weekCount: Int) -> String? {
        if trimmedName.isEmpty { return "请填写课程名称" }
        if meetings.isEmpty { return "至少要有一个上课时间" }
        for (index, meeting) in meetings.enumerated() {
            let label = meetings.count > 1 ? "第 \(index + 1) 个上课时间：" : ""
            if let problem = meeting.problem(periodCount: periodCount, weekCount: weekCount) {
                return label + problem
            }
        }
        return nil
    }

    func rows(tableId: Int, weekCount: Int) -> [Course] {
        meetings.map { meeting in
            Course(
                tableId: tableId,
                name: trimmedName,
                weeks: meeting.weeks(weekCount: weekCount),
                weekTime: meeting.weekday,
                startTime: meeting.startPeriod,
                timeCount: max(0, meeting.endPeriod - meeting.startPeriod),
                importType: ImportKind.manual,
                classroom: meeting.classroom.trimmedNilIfEmpty,
                teacher: teacher.trimmedNilIfEmpty
            )
        }
    }
}

/// 一个上课时间：星期几、第几节到第几节、在哪、哪些周。
nonisolated struct ManualMeetingDraft: Identifiable, Equatable {
    var id = UUID()
    /// 1 = 周一 … 7 = 周日。
    var weekday: Int = 1
    var startPeriod: Int = 1
    var endPeriod: Int = 2
    var classroom: String = ""
    var firstWeek: Int = 1
    /// `nil` 表示「到最后一周」，学期总周数改了也跟着变。
    var lastWeek: Int?
    var kind: WeekSeries.Kind = .full
    /// `kind == .custom` 时逐周勾选的结果。
    var customWeeks: Set<Int> = []

    func resolvedLastWeek(weekCount: Int) -> Int {
        min(lastWeek ?? weekCount, weekCount)
    }

    func weeks(weekCount: Int) -> [Int] {
        if kind == .custom {
            return customWeeks.filter { (1...weekCount).contains($0) }.sorted()
        }
        return WeekSeries.make(from: max(1, firstWeek), to: resolvedLastWeek(weekCount: weekCount), kind: kind)
    }

    func problem(periodCount: Int, weekCount: Int) -> String? {
        if !(1...7).contains(weekday) { return "请选择星期" }
        if startPeriod < 1 || endPeriod > periodCount { return "节次超出了每天的 \(periodCount) 节" }
        if endPeriod < startPeriod { return "结束节次不能早于开始节次" }
        if kind != .custom, firstWeek > resolvedLastWeek(weekCount: weekCount) { return "起始周不能晚于结束周" }
        if weeks(weekCount: weekCount).isEmpty {
            return kind == .custom ? "请至少选一周" : "这个范围里没有\(kind.title)"
        }
        return nil
    }

    /// 「周一 第 1-2 节 · 第 1-16 周 单周」。
    func summary(weekCount: Int, classTimes: [ClassTime]) -> String {
        let day = WeekCalculator.weekdayName(weekday)
        let periods = startPeriod == endPeriod ? "第 \(startPeriod) 节" : "第 \(startPeriod)-\(endPeriod) 节"
        var time = ""
        if classTimes.indices.contains(startPeriod - 1), classTimes.indices.contains(endPeriod - 1) {
            time = " \(classTimes[startPeriod - 1].start)–\(classTimes[endPeriod - 1].end)"
        }
        return "\(day) \(periods)\(time) · \(weekSummary(weekCount: weekCount))"
    }

    func weekSummary(weekCount: Int) -> String {
        let list = weeks(weekCount: weekCount)
        guard !list.isEmpty else { return "没有周次" }
        switch kind {
        case .full, .custom:
            return WeekSeries.summary(list)
        case .single, .double:
            return "第 \(max(1, firstWeek))-\(resolvedLastWeek(weekCount: weekCount)) 周 \(kind.title)"
        }
    }
}

// MARK: - 节次时间

nonisolated enum ClassTimeValidator {
    /// 解析 `HH:mm`，返回当天第几分钟。
    static func minutes(_ value: String) -> Int? {
        let parts = value.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "：", with: ":")
            .split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute), parts[1].count == 2 else { return nil }
        return hour * 60 + minute
    }

    static func format(_ minutes: Int) -> String {
        let clamped = min(max(minutes, 0), 23 * 60 + 59)
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }

    static func problem(in list: [ClassTime]) -> String? {
        if list.isEmpty { return "至少要有一节课" }
        var previousEnd = -1
        for (index, time) in list.enumerated() {
            guard let start = minutes(time.start), let end = minutes(time.end) else {
                return "第 \(index + 1) 节的时间格式不对，应为 08:00 这样"
            }
            if end <= start { return "第 \(index + 1) 节的下课时间要晚于上课时间" }
            if start < previousEnd { return "第 \(index + 1) 节和上一节时间重叠了" }
            previousEnd = end
        }
        return nil
    }
}

/// 按「每节多长、课间多久、上午/下午/晚上从几点开始、各几节」生成节次表。
/// 大多数学校的作息都能这样描述出来，生成后再逐节微调。
nonisolated struct ClassTimeGenerator: Equatable {
    struct Block: Equatable, Identifiable {
        var id: String { title }
        var title: String
        /// 当天第几分钟开始。
        var start: Int
        var count: Int
    }

    var lessonMinutes = 45
    var breakMinutes = 10
    var blocks: [Block] = [
        Block(title: "上午", start: 8 * 60, count: 4),
        Block(title: "下午", start: 14 * 60, count: 4),
        Block(title: "晚上", start: 19 * 60, count: 3),
    ]

    var periodCount: Int { blocks.reduce(0) { $0 + max(0, $1.count) } }

    func make() -> [ClassTime] {
        var list: [ClassTime] = []
        for block in blocks where block.count > 0 {
            var start = block.start
            for _ in 0..<block.count {
                let end = start + lessonMinutes
                list.append(ClassTime(start: ClassTimeValidator.format(start), end: ClassTimeValidator.format(end)))
                start = end + breakMinutes
            }
        }
        return list
    }
}

private extension String {
    var trimmedNilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
