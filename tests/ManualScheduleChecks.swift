import Foundation

@main
struct ManualScheduleChecks {
    @MainActor static func main() {
        // MARK: 周次

        // 每周：从起始周到最后一周；不填结束周时跟着学期总周数走。
        var meeting = ManualMeetingDraft(weekday: 2, startPeriod: 3, endPeriod: 4, firstWeek: 1)
        precondition(meeting.weeks(weekCount: 16) == Array(1...16))
        precondition(meeting.weeks(weekCount: 18) == Array(1...18))

        // 单双周只取范围里对应奇偶的周，起始周本身不对也会顺延。
        meeting.kind = .single
        meeting.firstWeek = 2
        meeting.lastWeek = 9
        precondition(meeting.weeks(weekCount: 16) == [3, 5, 7, 9])
        meeting.kind = .double
        precondition(meeting.weeks(weekCount: 16) == [2, 4, 6, 8])
        precondition(meeting.weekSummary(weekCount: 16) == "第 2-9 周 双周")

        // 结束周超过总周数时收回到最后一周。
        meeting.lastWeek = 30
        precondition(meeting.weeks(weekCount: 10).last == 10)

        // 自选：只保留学期范围内勾选的周。
        meeting.kind = .custom
        meeting.customWeeks = [1, 4, 5, 25]
        precondition(meeting.weeks(weekCount: 16) == [1, 4, 5])
        meeting.customWeeks = []
        precondition(meeting.problem(periodCount: 12, weekCount: 16) == "请至少选一周")

        // 一周范围里没有单周时要拦下，不能存一门永远不上的课。
        let empty = ManualMeetingDraft(firstWeek: 2, lastWeek: 2, kind: .single)
        precondition(empty.problem(periodCount: 12, weekCount: 16) != nil)

        // 节次超出、倒过来都不行。
        precondition(ManualMeetingDraft(startPeriod: 11, endPeriod: 13).problem(periodCount: 12, weekCount: 16) != nil)
        precondition(ManualMeetingDraft(startPeriod: 4, endPeriod: 3).problem(periodCount: 12, weekCount: 16) != nil)
        precondition(ManualMeetingDraft().problem(periodCount: 12, weekCount: 16) == nil)

        // MARK: 节次时间

        let generated = ClassTimeGenerator(
            lessonMinutes: 45, breakMinutes: 10,
            blocks: [.init(title: "上午", start: 8 * 60, count: 2), .init(title: "下午", start: 14 * 60, count: 1)]
        ).make()
        precondition(generated == [
            ClassTime(start: "08:00", end: "08:45"),
            ClassTime(start: "08:55", end: "09:40"),
            ClassTime(start: "14:00", end: "14:45"),
        ])
        precondition(ClassTimeValidator.problem(in: generated) == nil)
        precondition(ClassTimeValidator.problem(in: []) != nil)
        precondition(ClassTimeValidator.problem(in: [ClassTime(start: "8点", end: "09:00")]) != nil)
        precondition(ClassTimeValidator.problem(in: [ClassTime(start: "09:00", end: "08:00")]) != nil)
        precondition(ClassTimeValidator.problem(in: [
            ClassTime(start: "08:00", end: "09:00"), ClassTime(start: "08:30", end: "09:30"),
        ]) != nil)
        precondition(ClassTimeValidator.minutes("08：05") == 485)

        // MARK: 冲突提醒

        var 高数 = ManualCourseDraft(name: "高等数学")
        高数.meetings = [ManualMeetingDraft(weekday: 1, startPeriod: 1, endPeriod: 2, kind: .single)]
        var 实验 = ManualCourseDraft(name: "物理实验")
        实验.meetings = [ManualMeetingDraft(weekday: 1, startPeriod: 2, endPeriod: 3, kind: .double)]
        var draft = ManualScheduleDraft(
            name: "  我的课表 ", semesterStartMonday: "2026-09-07", weekCount: 16,
            classTimes: generated + [ClassTime(start: "15:00", end: "15:45")], courses: [高数, 实验]
        )
        // 单双周轮流上同一个时段，不算冲突。
        precondition(draft.overlapWarnings.isEmpty)
        draft.courses[1].meetings[0].kind = .full
        precondition(draft.overlapWarnings.count == 1)

        // MARK: 写进库

        // 一门课两个上课时间：两行，共用一个 courseKey。
        draft.courses[0].teacher = " 王老师 "
        draft.courses[0].meetings.append(ManualMeetingDraft(weekday: 3, startPeriod: 3, endPeriod: 4, classroom: "A101"))
        let app = AppStore(fileURL: nil)
        let table = app.installManualSchedule(draft)
        precondition(app.selectedTableId == table.id)
        precondition(table.name == "我的课表")
        precondition(table.semesterStartMonday == "2026-09-07")
        precondition(table.termWeekCount == 16 && table.termID == nil)
        precondition(app.maxWeeks == 16)
        precondition(table.classTimeList.count == 4)

        let rows = app.courses.filter { $0.tableId == table.id }
        precondition(rows.count == 3)
        let math = rows.filter { $0.name == "高等数学" }
        precondition(math.count == 2 && Set(math.map(\.courseKey)).count == 1)
        precondition(math.allSatisfy { $0.teacher == "王老师" && $0.isManual })
        precondition(math.first { $0.weekTime == 1 }?.weeks == [1, 3, 5, 7, 9, 11, 13, 15])
        let wednesday = math.first { $0.weekTime == 3 }
        precondition(wednesday?.startTime == 3 && wednesday?.timeCount == 1 && wednesday?.classroom == "A101")
        precondition(rows.first { $0.name == "物理实验" }?.courseKey != math[0].courseKey)
        precondition(Set(rows.map(\.id)).count == 3)

        // 这张课表的周数是它自己的，改了不影响别的课表。
        let other = app.addTable(name: "另一张")
        app.updateWeekCount(20, tableId: table.id)
        precondition(app.weekCount(of: app.tables.first { $0.id == table.id }!) == 20)
        precondition(app.weekCount(of: other) == max(1, app.settings.weekCount))

        // 统一假期安排：手动建的课表没绑学期，也按服务端下发的统一安排调课。
        let unified = [
            CalendarAdjustment(date: "2026-09-25", kind: .off, note: "中秋节"),
            CalendarAdjustment(date: "2026-09-26", kind: .off, note: "中秋节"),
        ]
        app.updateUnifiedCalendar(unified)
        let manual = app.tables.first { $0.id == table.id }!
        precondition(app.calendarAdjustments(of: manual) == unified)
        // 课表自带的只补统一安排没写到的日期，同一天以统一安排为准。
        var imported = manual
        imported.calendarAdjustments = [
            CalendarAdjustment(date: "2026-09-26", kind: .swap, source: "2026-09-24"),
            CalendarAdjustment(date: "2026-11-06", kind: .off, note: "校运会"),
        ]
        let merged = app.calendarAdjustments(of: imported)
        precondition(merged.map(\.date) == ["2026-09-25", "2026-09-26", "2026-11-06"])
        precondition(merged.first { $0.date == "2026-09-26" }?.kind == .off)
        // 关掉以后一条都不用，但节假日提示照旧知道中秋放到哪天。
        app.setUnifiedHolidaysEnabled(false, tableId: table.id)
        precondition(app.calendarAdjustments(of: app.tables.first { $0.id == table.id }!).isEmpty)
        app.selectTable(table.id)
        precondition(app.holidayCalendarAdjustments.map(\.date) == ["2026-09-25", "2026-09-26"])
        app.setUnifiedHolidaysEnabled(true, tableId: table.id)
        precondition(app.calendarAdjustments(of: app.tables.first { $0.id == table.id }!) == unified)

        let makeup = CalendarAdjustment(date: "2026-10-10", kind: .swap, source: "2026-10-08", note: "补班")
        app.updateUnifiedCalendar(unified + [makeup])
        app.setUnifiedMakeupEnabled(false, tableId: table.id)
        precondition(app.calendarAdjustments(of: app.tables.first { $0.id == table.id }!).map(\.date) == unified.map(\.date))
        app.setUnifiedMakeupEnabled(true, tableId: table.id)
        precondition(app.calendarAdjustments(of: app.tables.first { $0.id == table.id }!).contains(makeup))

        // 编辑不同周次的任意节次，拆成连续行后可以再次编辑整门课。
        var original = math[0]
        original.classNumber = "MATH-001"
        original.link = "https://example.com/course"
        original.color = "#123456"
        original.displayPriority = 3
        app.updateCourse(original)
        let family = app.courseFamily(containing: original)
        var editing = CourseScheduleDraft(courses: family)
        editing.meetings[0].weeks = [1, 3, 5]
        editing.meetings[0].slots = [1, 2, 5, 7, 8]
        editing.meetings[1].weeks = [2, 4, 6]
        editing.meetings[1].slots = [3, 4]
        editing.meetings[1].classroom = "B202"
        precondition(editing.problem(weekCount: 20, slotCount: 13) == nil)
        // 编辑指定课表时，当前选中其他课表也不能把课程写错位置。
        app.selectTable(other.id)
        try! app.saveCourseSchedule(editing, tableID: table.id)
        let edited = app.courseFamily(containing: original)
        precondition(edited.count == 4)
        precondition(edited.filter { $0.weekTime == 1 }.map(\.startTime) == [1, 5, 7])
        precondition(edited.filter { $0.weekTime == 1 }.allSatisfy {
            $0.weeks == [1, 3, 5] && $0.classNumber == "MATH-001"
                && $0.link == original.link && $0.color == original.color
        })
        precondition(edited.first { $0.weekTime == 3 }?.classroom == "B202")
        precondition(edited.allSatisfy { $0.tableId == table.id && $0.displayPriority == 3 })
        precondition(Set(edited.map(\.id)).count == 4)
        precondition(Set(edited.map(\.courseKey)).count == 1)
        precondition(edited.contains { $0.id == original.id })
        precondition(app.courses.filter { $0.tableId == table.id && $0.name == "物理实验" }.count == 1)
        let reopened = CourseScheduleDraft(courses: edited)
        try! app.saveCourseSchedule(reopened, tableID: table.id)
        precondition(app.courseFamily(containing: original) == edited)

        // 无周次、无节次、越界都拦住；自由时间不强制节次，旧收起状态保留。
        editing.meetings[0].weeks = []
        precondition(editing.problem(weekCount: 20, slotCount: 13) != nil)
        editing.meetings[0].weeks = [21]
        precondition(editing.problem(weekCount: 20, slotCount: 13) != nil)
        editing.meetings[0].weeks = [1]
        editing.meetings[0].slots = []
        precondition(editing.problem(weekCount: 20, slotCount: 13) != nil)
        editing.meetings[0].isFreeTime = true
        editing.meetings[0].hidden = true
        precondition(editing.problem(weekCount: 20, slotCount: 13) == nil)
        let free = editing.rows(tableID: table.id)[0]
        precondition(free.isFreeTime && free.isHidden && free.weeks == [1])

        // 移除安排后，其他行保留；新增课程仍有教师和备注。
        var trimmed = reopened
        trimmed.meetings.removeLast()
        try! app.saveCourseSchedule(trimmed, tableID: table.id)
        precondition(app.courseFamily(containing: original).count == 3)
        var added = CourseScheduleDraft(courses: [])
        added.name = "新课程"
        added.teacher = "新老师"
        added.note = "备注"
        try! app.saveCourseSchedule(added, tableID: other.id)
        let newCourse = app.courses.first { $0.tableId == other.id && $0.name == "新课程" }!
        precondition(newCourse.teacher == "新老师" && newCourse.info == "备注")

        print("ManualScheduleChecks passed")
    }
}
