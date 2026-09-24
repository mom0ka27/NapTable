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

        print("ManualScheduleChecks passed")
    }
}
