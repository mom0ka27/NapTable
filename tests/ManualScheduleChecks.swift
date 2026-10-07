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
            lessonMinutes: 45, smallBreakMinutes: 10,
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

        // 每个时段从小课间开始，奇数节最后一节前必须用小课间。
        for count in 1...8 {
            let times = ClassTimeGenerator(lessonMinutes: 45, smallBreakMinutes: 5, largeBreakMinutes: 25,
                blocks: [.init(title: "上午", start: 8 * 60, count: count)]).make()
            for index in 1..<count {
                let previous = ClassTimeValidator.minutes(times[index - 1].end)!
                let next = ClassTimeValidator.minutes(times[index].start)!
                let lastSingle = count % 2 == 1 && index == count - 1
                precondition(next - previous == (index % 2 == 1 || lastSingle ? 5 : 25))
            }
        }
        let resetTimes = ClassTimeGenerator(lessonMinutes: 45, smallBreakMinutes: 5, largeBreakMinutes: 25,
            blocks: [.init(title: "上午", start: 8 * 60, count: 3), .init(title: "下午", start: 14 * 60, count: 4), .init(title: "晚上", start: 19 * 60, count: 3)]).make()
        precondition(resetTimes[4].start == "14:50")
        precondition(resetTimes[5].start == "16:00")
        precondition(resetTimes[9].start == "20:40")

        let recognition = ImageImportResult(classTimes: [], courses: [
            .init(name: "数学", teacher: "李老师", classroom: "A101", weekday: 1, startPeriod: 1, endPeriod: 2, weeks: [1, 3, 5]),
            .init(name: "数学", teacher: "李老师", classroom: "A102", weekday: 3, startPeriod: 3, endPeriod: 4, weeks: []),
        ], warnings: [])
        let imageDraft = try! recognition.draft()
        precondition(imageDraft.courses.count == 1 && imageDraft.courses[0].meetings.count == 2)
        precondition(imageDraft.courses[0].meetings[0].weeks(weekCount: imageDraft.weekCount) == [1, 3, 5])
        precondition(imageDraft.courses[0].meetings[1].weeks(weekCount: imageDraft.weekCount).isEmpty)
        precondition(imageDraft.courses[0].problem(periodCount: imageDraft.classTimes.count, weekCount: imageDraft.weekCount) != nil)
        precondition(recognition.reviewWarnings.count == 4)

        // 图片识别会把同名课程合到一门课里，其重复安排仍须处理后才能完成。
        var duplicateImage = recognition
        duplicateImage.courses = Array(repeating: recognition.courses[0], count: 3)
        let duplicateDraft = try! duplicateImage.draft()
        precondition(duplicateDraft.courses.count == 1 && duplicateDraft.courses[0].meetings.count == 3)
        precondition(duplicateDraft.resolvingImportConflicts(keeping: [:]) == nil)
        precondition(duplicateDraft.resolvingImportConflicts(keeping: [0: 99]) == nil)
        let resolvedImage = duplicateDraft.resolvingImportConflicts(keeping: [0: 2])!
        let imageStore = AppStore(fileURL: nil)
        let imageTable = imageStore.installManualSchedule(resolvedImage)
        let imageRows = imageStore.courses.filter { $0.tableId == imageTable.id }
        precondition(imageRows.count == 3 && imageRows.allSatisfy { !$0.isHidden })
        precondition(imageRows.map(\.displayPriority) == [nil, nil, 1])
        precondition(imageRows.allSatisfy { $0.weeks == [1, 3, 5] && $0.startTime == 1 && $0.endTime == 2 })
        precondition(imageTable.termWeekCount == duplicateDraft.weekCount)
        precondition(imageTable.classTimeList == duplicateDraft.classTimes)

        // 选中的课只上前几周时，其余周次的重叠仍须继续选择。
        var partialImage = duplicateImage
        partialImage.courses[0].weeks = [1]
        partialImage.courses[1].name = "物理"
        partialImage.courses[2].name = "化学"
        let partialImageDraft = try! partialImage.draft()
        precondition(partialImageDraft.resolvingImportConflicts(keeping: [0: 0]) == nil)
        let imageGroups = ImportConflictFinder.expandedGroups(
            in: partialImageDraft.courseRows(tableId: 0).flatMap { $0 }, keeping: [0: 0])
        precondition(imageGroups.count == 2)
        precondition(partialImageDraft.resolvingImportConflicts(keeping: [0: 0, imageGroups[1].id: 1]) != nil)

        // 修改时间或删除重复安排后，不再重叠就可以完成；单双周不误报。
        var editedImage = duplicateDraft
        editedImage.courses[0].meetings = Array(editedImage.courses[0].meetings.prefix(2))
        editedImage.courses[0].meetings[1].customWeeks = [2, 4, 6]
        precondition(editedImage.resolvingImportConflicts(keeping: [:]) != nil)
        editedImage.courses[0].meetings[1].customWeeks = [1, 3, 5]
        editedImage.courses[0].meetings[1].weekday = 2
        precondition(editedImage.resolvingImportConflicts(keeping: [:]) != nil)
        editedImage.courses[0].meetings.removeLast()
        precondition(editedImage.resolvingImportConflicts(keeping: [:]) != nil)

        // Partial times retain their period numbers; the count includes empty rows.
        let partialJSON = """
        {"name":"图片课表","semesterStartMonday":"2026-09-07","weekCount":16,"periodCount":8,
         "classTimes":[],"periodTimes":[{"period":5,"start":"13:30","end":"14:15"},
         {"period":6,"start":"14:25","end":null}],"warnings":[],
         "courses":[{"name":"数学","teacher":"","classroom":"A101","weekday":1,"startPeriod":5,"endPeriod":6,"weeks":[1,3,5]}]}
        """
        let partial = try! JSONDecoder().decode(ImageImportResult.self, from: Data(partialJSON.utf8))
        let partialDraft = try! partial.draft()
        precondition(partialDraft.name == "2026 秋")
        precondition(partialDraft.classTimes.count == 8)
        precondition(partialDraft.classTimes[4] == ClassTime(start: "13:30", end: "14:15"))
        precondition(partialDraft.classTimes[5].start == "14:25")
        precondition(partialDraft.courses[0].meetings[0].startPeriod == 5)
        precondition(partial.periodReviewWarnings.contains { $0.contains("第 6 节未读到下课") })
        precondition(partial.periodReviewWarnings.contains { $0.contains("第 1、2、3、4、7、8 节") })

        var countOnly = recognition
        countOnly.periodCount = 12
        precondition(try! countOnly.draft().classTimes.count == 12)
        precondition(countOnly.periodReviewWarnings.contains { $0.contains("12 节默认作息") })
        countOnly.periodCount = 4
        precondition(try! countOnly.draft().classTimes.count == 4)

        var complete = partial
        complete.periodCount = 2
        complete.periodTimes = nil
        complete.classTimes = [.init(start: "08:15", end: "09:00"), .init(start: "09:10", end: "09:55")]
        complete.courses[0].startPeriod = 1
        complete.courses[0].endPeriod = 2
        precondition(try! complete.draft().classTimes == [ClassTime(start: "08:15", end: "09:00"), ClassTime(start: "09:10", end: "09:55")])
        precondition(complete.periodReviewWarnings.isEmpty)

        // Old server JSON still decodes without either of the new fields.
        let legacyJSON = """
        {"name":"旧格式课表","classTimes":[],"warnings":[],
         "courses":[{"name":"数学","teacher":"","classroom":"","weekday":1,"startPeriod":1,"endPeriod":2,"weeks":[]}]}
        """
        let legacy = try! JSONDecoder().decode(ImageImportResult.self, from: Data(legacyJSON.utf8))
        precondition(legacy.periodCount == nil && legacy.periodTimes == nil)
        precondition(try! legacy.draft().courses.count == 1)
        let fallDate = WeekCalculator.parseDay("2026-10-05")!
        precondition(try! legacy.draft(now: fallDate).name == "2026 秋")
        var spring = partial
        spring.semesterStartMonday = "2027-02-22"
        precondition(try! spring.draft(now: fallDate).name == "2027 春")
        precondition(try! legacy.draft(now: WeekCalculator.parseDay("2026-06-30")!).name == "2026 春")
        precondition(try! legacy.draft(now: WeekCalculator.parseDay("2026-07-01")!).name == "2026 秋")

        // A recognized time that conflicts with defaults is kept for editing.
        var needsReview = partial
        needsReview.periodTimes = [.init(period: 5, start: "15:30", end: "16:15")]
        let needsReviewDraft = try! needsReview.draft()
        precondition(needsReviewDraft.classTimes[4].start == "15:30")
        precondition(needsReviewDraft.courses.count == 1)
        precondition(needsReviewDraft.classTimesProblem != nil)
        precondition(needsReview.periodReviewWarnings.contains { $0.contains("暂填作息与已识别时间") })

        func expectRecognitionError(_ value: ImageImportResult, containing text: String) {
            do { _ = try value.draft(); preconditionFailure("Expected recognition error") }
            catch { precondition(error.localizedDescription.contains(text), error.localizedDescription) }
        }
        var noCourses = recognition
        noCourses.courses = []
        noCourses.warnings = ["截图未包含星期表头，无法确定课程安排。"]
        precondition(try! noCourses.draft().courses.isEmpty)
        precondition(noCourses.reviewWarnings.contains { $0.contains("截图未包含星期表头") })
        precondition(noCourses.reviewWarnings.contains { $0.contains("手动添加") })

        let optionalJSON = """
        {"name":null,"weekCount":null,"classTimes":null,"courses":[{"name":"数学"},
        {"name":null,"teacher":"李老师","classroom":"A101","endPeriod":6},
        {"teacher":"李老师","startPeriod":12,"weeks":null}],"warnings":null}
        """
        let optional = try! JSONDecoder().decode(ImageImportResult.self, from: Data(optionalJSON.utf8))
        var editable = try! optional.draft(now: fallDate)
        precondition(editable.name == "2026 秋")
        precondition(editable.courses.count == 3) // Unnamed courses must not be merged.
        precondition(editable.classTimes.count == 12)
        let unknownMeeting = editable.courses[0].meetings[0]
        precondition(unknownMeeting.weekday == 0 && unknownMeeting.startPeriod == 0 && unknownMeeting.endPeriod == 0)
        precondition(unknownMeeting.weeks(weekCount: editable.weekCount).isEmpty)
        precondition(unknownMeeting.summary(weekCount: editable.weekCount, classTimes: editable.classTimes).contains("待填写星期"))
        precondition(editable.courses[1].teacher == "李老师" && editable.courses[1].meetings[0].endPeriod == 6)
        precondition(editable.courses[2].meetings[0].startPeriod == 12 && editable.courses[2].meetings[0].endPeriod == 0)
        // Both recognized and missing values can be changed before final validation.
        editable.courses[0].name = "高等数学"
        editable.courses[0].meetings[0].weekday = 3
        editable.courses[0].meetings[0].startPeriod = 1
        editable.courses[0].meetings[0].endPeriod = 2
        editable.courses[0].meetings[0].customWeeks = [2, 4, 6]
        precondition(editable.courses[0].problem(periodCount: editable.classTimes.count, weekCount: editable.weekCount) == nil)
        let blank = try! JSONDecoder().decode(ImageImportResult.self, from: Data("{}".utf8))
        precondition(try! blank.draft().courses.isEmpty)
        var invalid = partial
        invalid.periodCount = 4
        expectRecognitionError(invalid, containing: "节次")
        invalid = partial
        invalid.periodTimes = [.init(period: 0, start: "08:00", end: "08:45")]
        expectRecognitionError(invalid, containing: "节次编号")
        invalid.periodTimes = [.init(period: 5, start: "14:00", end: "13:45")]
        expectRecognitionError(invalid, containing: "第 5 节")
        invalid.periodTimes = [.init(period: 5, start: "", end: "14:45")]
        expectRecognitionError(invalid, containing: "第 5 节")
        invalid.periodTimes = [.init(period: 5, start: "14:00", end: nil), .init(period: 5, start: nil, end: "14:45")]
        expectRecognitionError(invalid, containing: "重复")
        invalid = complete
        invalid.classTimes[0].end = ""
        expectRecognitionError(invalid, containing: "不完整")
        precondition(AppAttestService.guarded(method: "POST", path: "/v1/import/image"))
        precondition(!AppAttestService.guarded(method: "GET", path: "/v1/import/image/config"))

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

        try! checkNameGroupingAndMigration()
        try! checkCustomTimetables()
        print("ManualScheduleChecks passed")
    }

    @MainActor static func checkNameGroupingAndMigration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("legacy.json")
        var legacy = AppStateFile()
        legacy.version = 1
        legacy.tables = [CourseTable(id: 1, name: "秋季"), CourseTable(id: 2, name: "春季")]
        legacy.selectedTableId = 1
        legacy.courses = [
            Course(id: 1, tableId: 1, name: " 数学 ", weeks: [1, 3], weekTime: 1, startTime: 1,
                   timeCount: 1, importType: ImportKind.imported, classroom: "A101", teacher: "甲", courseKey: 10),
            Course(id: 2, tableId: 1, name: "数学", weeks: [2, 4], weekTime: 3, startTime: 3,
                   timeCount: 1, importType: ImportKind.imported, classroom: "B202", teacher: "乙", courseKey: 20, hidden: true),
            Course(id: 3, tableId: 2, name: "数学", weeks: [1], weekTime: 2, startTime: 1,
                   timeCount: 0, importType: ImportKind.manual, courseKey: 10),
            Course(id: 4, tableId: 1, name: "物理", weeks: [1], weekTime: 4, startTime: 1,
                   timeCount: 0, importType: ImportKind.manual, courseKey: 10)
        ]
        try JSONEncoder().encode(legacy).write(to: url)
        let app = AppStore(fileURL: url)
        precondition(app.courses.count == 4)
        precondition(app.courseFamily(containing: app.courses[0]).map(\.id) == [1, 2])
        precondition(Set(app.courses.map(\.courseKey)).count == 3)
        for (before, var after) in zip(legacy.courses, app.courses) {
            after.name = before.name
            after.courseKey = before.courseKey
            precondition(after == before, "Migration must preserve all meeting metadata")
        }
        let saved = try JSONDecoder().decode(AppStateFile.self, from: Data(contentsOf: url))
        precondition(saved.version == 2 && saved.courses == app.courses)
        precondition(AppStore(fileURL: url).courses == app.courses, "Migration must be idempotent")
        app.install(payload: ImportedSchedule(name: "追加", courses: [legacy.courses[1]]), mode: .appendToCurrent)
        precondition(app.courseFamily(containing: app.courses[0]).count == 3)
        let otherTableCourses = app.courses.filter { $0.tableId == 2 }
        app.deleteCourseFamily(app.courses[0])
        precondition(app.courses.filter { $0.tableId == 2 } == otherTableCourses)
        precondition(app.courses.filter { $0.tableId == 1 }.map(\.name) == ["物理"])
        let imported = app.install(payload: ImportedSchedule(name: "导入", courses: Array(legacy.courses.prefix(2))), mode: .newTable)
        precondition(Set(app.courses.filter { $0.tableId == imported.id }.map(\.courseKey)).count == 1)
        let restored = AppStore(fileURL: nil)
        restored.restore(app.exportDocument())
        let math = restored.courses.filter { $0.name == "数学" }
        precondition(math.count == 3 && Set(math.map(\.courseKey)).count == 2)
        var manual = ManualScheduleDraft(name: "手动同名")
        manual.courses = [ManualCourseDraft(name: "同名"), ManualCourseDraft(name: "同名")]
        let manualTable = app.installManualSchedule(manual)
        precondition(Set(app.courses.filter { $0.tableId == manualTable.id }.map(\.courseKey)).count == 1)
        var renamed = app.courses.first { $0.tableId == imported.id }!
        let beforeRename = renamed
        renamed.name = "物理"
        app.updateCourse(renamed)
        var another = app.courses.first { $0.tableId == imported.id && $0.name == "数学" }!
        another.name = "物理"
        app.updateCourse(another)
        precondition(app.courseFamily(containing: beforeRename).count == 2)
        precondition(Set(app.courses.filter { $0.tableId == imported.id }.map(\.courseKey)).count == 1)
        precondition(app.courses.filter { $0.tableId == 1 }.map(\.name) == ["物理"])
    }

    @MainActor static func checkCustomTimetables() throws {
        let app = AppStore(fileURL: nil)
        let table = app.addTable(name: "学校课表")
        let base = [ClassTime(start: "08:00", end: "08:50")]
        let summer = [ClassTime(start: "09:00", end: "09:50")]
        let winter = [ClassTime(start: "10:00", end: "10:50")]
        var term = ServiceTermConfiguration(id: "fall", version: 1, semesterStartMonday: "2026-09-07", weekCount: 18,
            periods: [.init(id: 1, name: "第一节", start: "08:00", end: "08:50")],
            timezone: "Asia/Shanghai", note: "", current: true)
        app.applyTerm(term, schoolID: "test")
        let seasons = [SeasonalClassTimes(from: "05-01", periods: summer), SeasonalClassTimes(from: "10-01", periods: winter)]
        precondition(app.updateCustomClassTimes(base, seasons: seasons, tableId: table.id))
        precondition(app.selectedTable!.classTimes(on: "2026-04-30") == winter)
        precondition(app.selectedTable!.classTimes(on: "2026-05-01") == summer)
        precondition(app.selectedTable!.classTimes(on: "2026-10-01") == winter)
        precondition(app.selectedTable!.classTimes(on: "2027-01-01") == winter)
        term.version = 2
        term.periods[0].start = "07:00"
        term.periods[0].end = "07:50"
        app.refreshServiceConfiguration([ServiceSchoolConfiguration(id: "test", name: "测试学校", timezone: "Asia/Shanghai", terms: [term], note: "")])
        precondition(app.selectedTable!.classTimeList == term.classTimes)
        precondition(app.selectedTable!.classTimes(on: "2026-05-01") == summer)
        precondition(app.setUsesCustomClassTimes(false, tableId: table.id))
        precondition(app.selectedTable!.classTimes(on: "2026-05-01") == term.classTimes)
        precondition(app.selectedTable!.customSeasonalPeriods == seasons)
        precondition(app.setUsesCustomClassTimes(true, tableId: table.id))
        precondition(app.selectedTable!.classTimes(on: "2026-05-01") == summer)
        let restored = try JSONDecoder().decode(CourseTable.self, from: JSONEncoder().encode(app.selectedTable!))
        precondition(restored.customSeasonalPeriods == seasons && restored.usesCustomClassTimes == true)
        precondition(!app.updateCustomClassTimes(base, seasons: [seasons[0], seasons[0]], tableId: table.id))
        precondition(!app.updateCustomClassTimes(base, seasons: [.init(from: "02-30", periods: base)], tableId: table.id))
        precondition(!app.updateClassTimeList([ClassTime(start: "10:00", end: "09:00")], tableId: table.id))
        precondition(!app.updateCustomClassTimes(base, seasons: [.init(from: "02-29", periods: base)], tableId: table.id))
        precondition(!app.updateCustomClassTimes(base, seasons: (1...5).map { .init(from: "0\($0)-01", periods: base) }, tableId: table.id))
        precondition(!app.updateCustomClassTimes(base, seasons: [.init(from: "05-01", periods: base + summer)], tableId: table.id))
        precondition(!app.updateCustomClassTimes(base, seasons: [.init(from: "05-01", periods: [])], tableId: table.id))
        app.addCourse(Course(tableId: table.id, name: "晚课", weeks: [1], weekTime: 1, startTime: 2, timeCount: 0, importType: ImportKind.manual))
        precondition(!app.updateCustomClassTimes(base, seasons: seasons, tableId: table.id), "Cannot remove a period used by a course")
        precondition(app.selectedTable == restored, "Invalid edits must leave saved settings intact")
    }

}
