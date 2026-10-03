import Foundation

/// 编辑一门课的多个安排。每组可以选择不同的周次和不连续节次。
nonisolated struct CourseScheduleDraft {
    var name: String
    var teacher: String
    var note: String
    var displayPriority: Int?
    var meetings: [CourseScheduleMeeting]
    let originals: [Course]

    init(courses: [Course], defaultDay: Int = 1, defaultWeek: Int = 1, defaultSlot: Int = 1) {
        originals = courses
        name = courses.first?.name ?? ""
        teacher = courses.first?.teacher ?? ""
        note = courses.first?.info ?? ""
        displayPriority = courses.compactMap(\.displayPriority).max()
        meetings = courses.map(CourseScheduleMeeting.init)
        if meetings.isEmpty {
            meetings = [CourseScheduleMeeting(day: defaultDay, weeks: [defaultWeek], slots: [defaultSlot])]
        }
    }

    func problem(weekCount: Int, slotCount: Int) -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写课程名称" }
        if meetings.isEmpty { return "请至少添加一组上课安排" }
        for (index, meeting) in meetings.enumerated() {
            let prefix = "第 \(index + 1) 组安排："
            if meeting.weeks.isEmpty { return prefix + "请至少选择一周" }
            if meeting.weeks.contains(where: { !(1...max(1, weekCount)).contains($0) }) {
                return prefix + "周次超出了本课表的范围"
            }
            if !meeting.isFreeTime {
                if !(1...7).contains(meeting.day) { return prefix + "请选择星期" }
                if meeting.slots.isEmpty { return prefix + "请至少选择一节" }
                if meeting.slots.contains(where: { !(1...max(1, slotCount)).contains($0) }) {
                    return prefix + "节次超出了本课表的范围"
                }
            }
        }
        return nil
    }

    /// 不连续节次拆成连续的课程行；周次、导入元数据和课程身份均保留。
    func rows(tableID: Int) -> [Course] {
        meetings.flatMap { meeting in
            meeting.ranges.map { range in
                var row = meeting.original ?? originals.first ?? Course(
                    tableId: tableID, name: "", weeks: [], weekTime: 1,
                    startTime: 1, timeCount: 0, importType: ImportKind.manual
                )
                row.id = 0 // 写库时只为每个原始安排的第一段保留原 id。
                row.tableId = tableID
                row.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if teacher != (originals.first?.teacher ?? "") { row.teacher = teacher.trimmedNonEmpty }
                if note != (originals.first?.info ?? "") { row.info = note.trimmedNonEmpty }
                if meeting.original == nil || meeting.classroom != (meeting.original?.classroom ?? "") {
                    row.classroom = meeting.classroom.trimmedNonEmpty
                }
                row.weeks = meeting.weeks.sorted()
                row.weekTime = meeting.isFreeTime ? 0 : meeting.day
                row.startTime = meeting.isFreeTime ? 0 : range.lowerBound
                row.timeCount = meeting.isFreeTime ? 0 : range.upperBound - range.lowerBound
                row.hidden = meeting.hidden ? true : nil
                row.displayPriority = displayPriority
                return row
            }
        }
    }
}

nonisolated struct CourseScheduleMeeting: Identifiable {
    let id = UUID()
    var original: Course?
    var day: Int = 1
    var weeks: Set<Int> = []
    var slots: Set<Int> = []
    var classroom: String = ""
    var isFreeTime = false
    var hidden = false

    init(day: Int = 1, weeks: Set<Int> = [], slots: Set<Int> = []) {
        self.day = max(1, day)
        self.weeks = weeks
        self.slots = slots
        self.isFreeTime = day == 0
    }

    init(_ course: Course) {
        original = course
        day = course.isFreeTime ? 1 : course.weekTime
        weeks = Set(course.weeks)
        slots = course.isFreeTime ? [1] : Set(max(1, course.startTime)...max(1, course.endTime))
        classroom = course.classroom ?? ""
        isFreeTime = course.isFreeTime
        hidden = course.isHidden
    }

    var ranges: [ClosedRange<Int>] {
        if isFreeTime { return [0...0] }
        var result: [ClosedRange<Int>] = []
        for slot in slots.sorted() {
            if let last = result.last, slot == last.upperBound + 1 {
                result[result.count - 1] = last.lowerBound...slot
            } else { result.append(slot...slot) }
        }
        return result
    }
}
