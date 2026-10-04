import Foundation

@main
struct ImportConflictChecks {
    @MainActor static func main() throws {
        func course(_ name: String, day: Int = 1, start: Int = 1, count: Int = 1,
                    weeks: [Int] = Array(1...16)) -> Course {
            Course(tableId: 0, name: name, weeks: weeks, weekTime: day,
                   startTime: start, timeCount: count, importType: ImportKind.imported)
        }
        let odd = course("单周", weeks: [1, 3, 5])
        let even = course("双周", weeks: [2, 4, 6])
        precondition(ImportConflictFinder.groups(in: [odd, even]).isEmpty)
        precondition(!ImportConflictFinder.collide(odd, course("另一日", day: 2)))
        precondition(!ImportConflictFinder.collide(odd, course("另一时段", start: 4)))
        precondition(ImportConflictFinder.groups(in: []).isEmpty)

        // 部分周次、部分节次重叠：选择只改优先级，全部真实安排保留。
        let partial = [course("前半程", weeks: Array(1...8)), course("全学期", start: 2)]
        let groups = ImportConflictFinder.groups(in: partial)
        precondition(groups.count == 1)
        let resolved = ImportConflictFinder.apply(keeping: [0: 0], to: partial, groups: groups)
        precondition(resolved.count == 2 && resolved.allSatisfy { !$0.isHidden })
        precondition(resolved.map(\.weeks) == partial.map(\.weeks))
        precondition(resolved.map(\.startTime) == partial.map(\.startTime))
        precondition(resolved[0].displayPriority == 1 && resolved[1].displayPriority == nil)
        precondition(ImportConflictFinder.apply(keeping: [:], to: partial, groups: groups) == partial)
        precondition(ImportConflictFinder.apply(keeping: [0: 99], to: partial, groups: groups) == partial)

        // 连环重叠不会隐藏任何成员；后续选择仍可独立保存优先级。
        let chain = [course("A", count: 0), course("B", count: 2), course("C", start: 3, count: 0)]
        let expanded = ImportConflictFinder.expandedGroups(in: chain, keeping: [0: 0])
        let chained = ImportConflictFinder.apply(keeping: [0: 0], to: chain, groups: expanded)
        precondition(chained.count == chain.count && chained.allSatisfy { !$0.isHidden })
        precondition(chained[0].displayPriority != nil && chained[2].displayPriority == nil)

        // 导入前必须完成所有真实重叠的选择，旧选择失效也不能放行。
        precondition(ImportConflictFinder.hasUnresolvedConflicts(in: partial, keeping: [:]))
        precondition(ImportConflictFinder.hasUnresolvedConflicts(in: partial, keeping: [0: 99]))
        precondition(!ImportConflictFinder.hasUnresolvedConflicts(in: partial, keeping: [0: 0]))
        precondition(ImportConflictFinder.hasUnresolvedConflicts(in: chain, keeping: [0: 0]))
        let nextGroup = expanded[1]
        precondition(!ImportConflictFinder.hasUnresolvedConflicts(in: chain, keeping: [0: 0, nextGroup.id: 2]))
        precondition(ImportConflictFinder.hasUnresolvedConflicts(in: chain, keeping: [0: 0, nextGroup.id: 0]))
        // 首位不在的后半学期，另外两门课仍须选一次。
        let halfTerm = [course("前半程", weeks: Array(1...8)), course("整学期 B"), course("整学期 C")]
        let halfGroups = ImportConflictFinder.expandedGroups(in: halfTerm, keeping: [0: 0])
        precondition(halfGroups.count == 2)
        precondition(ImportConflictFinder.hasUnresolvedConflicts(in: halfTerm, keeping: [0: 0]))
        precondition(!ImportConflictFinder.hasUnresolvedConflicts(in: halfTerm, keeping: [0: 0, halfGroups[1].id: 1]))

        // 相同名称归为一门课，但每条安排仍各自保留，网格、小组件快照能区分行身份。
        let duplicate = course("重复课")
        let duplicates = [duplicate, duplicate, duplicate]
        precondition(ImportConflictFinder.expandedGroups(in: duplicates, keeping: [0: 2]).count == 1)
        precondition(!ImportConflictFinder.hasUnresolvedConflicts(in: duplicates, keeping: [0: 2]))
        let picked = ImportConflictFinder.apply(keeping: [0: 2], to: duplicates,
                                                groups: ImportConflictFinder.groups(in: duplicates))
        let app = AppStore(fileURL: nil)
        app.deleteAllCourses()
        app.install(payload: ImportedSchedule(name: "重复课表", courses: picked, semesterStartMonday: "2026-09-07"), mode: .replaceCurrent)
        precondition(app.currentCourses.count == 3 && app.currentHiddenCourses.isEmpty)
        precondition(Set(app.currentCourses.map(\.id)).count == 3)
        precondition(Set(app.currentCourses.map(\.courseKey)).count == 1)
        precondition(app.courseFamily(containing: app.currentCourses[0]).count == 3)
        precondition(app.coursesInTimeRange(of: app.currentCourses[0]).count == 1)
        let logic = ScheduleLogic(courses: app.currentCourses, nowWeek: 1)
        precondition(logic.multiCourses.count == 1 && logic.multiCourses[0].count == 3)
        precondition(logic.multiCourses[0][0].id == app.currentCourses[2].id)
        precondition(logic.activeCourses.isEmpty) // 第三个成员不能又被单独画一次。
        let native = NativeScheduleStore()
        native.connect(app)
        let snapshot = native.snapshot()!
        let nativeRows = snapshot.data!.cells.flatMap(\.courses)
        precondition(nativeRows.count == 3 && Set(nativeRows.map(\.id)).count == 3)
        precondition(nativeRows.filter { ($0.displayPriority ?? 0) > 0 }.count == 1)

        // 实际课表卡片必须采用导入选择，不能只把优先课程排到并排卡片的左边。
        func blocks(_ rows: [NativeScheduleCourse]) -> [NativeScheduleCourseBlock] {
            rows.map { row in
                NativeScheduleCourseBlock(id: row.id, course: row, bigSlot: 1,
                    startSlot: row.startSlot ?? 1, endSlot: row.endSlot ?? 2)
            }
        }
        let visibleDuplicates = NativeScheduleCourseBlock.resolvingDisplayPriorities(blocks(nativeRows))
        precondition(visibleDuplicates.count == 1)
        precondition(visibleDuplicates[0].course.displayPriority == 1 && visibleDuplicates[0].lane == 0)
        precondition(NativeScheduleCourseBlock.resolvingDisplayPriorities(blocks(nativeRows.reversed()))
            .map(\.id) == visibleDuplicates.map(\.id))

        // 优先课仅覆盖中间两节时，另一门课的前后两段仍显示，且保留原课程身份。
        let longer = NativeScheduleCourse(name: "长课", weeks: "1-16", weekList: Array(1...16),
            startSlot: 1, endSlot: 6, customId: "long")
        let preferred = NativeScheduleCourse(name: "优先课", weeks: "1-8", weekList: Array(1...8),
            startSlot: 3, endSlot: 4, customId: "preferred", displayPriority: 2)
        let split = NativeScheduleCourseBlock.resolvingDisplayPriorities(blocks([longer, preferred]))
        precondition(split.count == 3 && Set(split.map(\.id)).count == 3)
        precondition(split.allSatisfy { $0.lane == 0 })
        let remaining = split.filter { $0.course.customId == "long" }
        precondition(remaining.map(\.startSlot) == [1, 5] && remaining.map(\.endSlot) == [2, 6])
        precondition(remaining.allSatisfy { $0.course.startSlot == 1 && $0.course.endSlot == 6 })
        // 后半学期优先课程不上课，整段恢复显示。
        let later = NativeScheduleCourseBlock.resolvingDisplayPriorities(
            blocks([longer, preferred].filter { $0.weekList.contains(9) }))
        precondition(later.count == 1 && later[0].startSlot == 1 && later[0].endSlot == 6)
        // 连环冲突按每一节的最高优先级选择，不把整组其余课程一起隐藏。
        let middle = NativeScheduleCourse(name: "第二优先", weeks: "1-16", weekList: Array(1...16),
            startSlot: 2, endSlot: 5, customId: "middle", displayPriority: 1)
        let chainBlocks = NativeScheduleCourseBlock.resolvingDisplayPriorities(blocks([longer, middle, preferred]))
        precondition(chainBlocks.count == 5 && chainBlocks.allSatisfy { $0.lane == 0 })
        for slot in 1...6 {
            let shown = chainBlocks.filter { $0.startSlot <= slot && slot <= $0.endSlot }
            precondition(shown.count == 1)
            let expected = (3...4).contains(slot) ? "preferred" : ((2...5).contains(slot) ? "middle" : "long")
            precondition(shown[0].course.customId == expected)
        }
        // 没有选择优先级的旧课表继续并排显示。
        let unranked = NativeScheduleCourse(name: "另一门", weeks: "1-16", weekList: Array(1...16),
            startSlot: 1, endSlot: 6, customId: "other")
        let parallel = NativeScheduleCourseBlock.resolvingDisplayPriorities(blocks([longer, unranked]))
        precondition(parallel.count == 2 && Set(parallel.map(\.lane)) == [0, 1])

        let widgetPayload = NativeWidgetSettings.payload(from: snapshot, selectedWeek: 1)!
        let widgetCourses = widgetPayload.weekDays!.first { $0.day == 1 }!.courses!
        precondition(widgetCourses.count == 3 && Set(widgetCourses.map(\.id)).count == 3)
        precondition(widgetCourses.first!.displayPriority == 1)
        let restoredWidget = try JSONDecoder().decode(WidgetSchedulePayload.self, from: JSONEncoder().encode(widgetPayload))
        precondition(restoredWidget.weekDays == widgetPayload.weekDays)
        let week = snapshot.calendar!.weeks.first { $0.week == 1 }!
        let ics = NativeScheduleICSExporter.make(result: snapshot.data!, week: week, periods: snapshot.periods)
        let uids = ics.components(separatedBy: "\n").filter { $0.hasPrefix("UID:") }
        precondition(uids.count == 3 && Set(uids).count == 3)

        // 老存档、备份、分享导入：优先级可选且往返保留。
        let legacy = Data(#"{"id":1,"tableId":1,"name":"旧课","weeks":[1],"weekTime":1,"startTime":1,"timeCount":1,"importType":1}"#.utf8)
        let decoded = try JSONDecoder().decode(Course.self, from: legacy)
        precondition(decoded.displayPriority == nil && !decoded.isHidden)
        let restored = try JSONDecoder().decode(Course.self, from: JSONEncoder().encode(picked[2]))
        precondition(restored.displayPriority == 1)
        let payload = CoursePayloadCodec.makeCourse(from: ["name": "分享课", "weeks": [1],
            "week_time": 1, "start_time": 1, "displayPriority": 2])!
        precondition(payload.displayPriority == 2)
        // 改成三门不同名称的课，验证多课程批量保存及优先级。
        for (index, var row) in app.currentCourses.enumerated() {
            row.name = "独立课程 \(index + 1)"
            app.updateCourse(row)
        }
        let originals = app.currentCourses
        precondition(app.coursesInTimeRange(of: originals[0]).count == 3)
        var drafts = originals.map { CourseScheduleDraft(courses: app.courseFamily(containing: $0)) }
        precondition(app.hasCourseOverlap(in: drafts, selectedIndex: 0, tableID: app.selectedTableId))
        var alternating = drafts
        alternating[0].meetings[0].weeks = [1, 3]
        alternating[1].meetings[0].weeks = [2, 4]
        alternating[2].meetings[0].hidden = true
        precondition(!app.hasCourseOverlap(in: alternating, selectedIndex: 0, tableID: app.selectedTableId))
        alternating[1].meetings[0].weeks = [1, 3]
        alternating[1].meetings[0].slots = [5, 6]
        precondition(!app.hasCourseOverlap(in: alternating, selectedIndex: 0, tableID: app.selectedTableId))
        alternating[1].meetings[0].slots = [1, 2]
        alternating[1].meetings[0].day = 2
        precondition(!app.hasCourseOverlap(in: alternating, selectedIndex: 0, tableID: app.selectedTableId))
        precondition(!app.hasCourseOverlap(in: [drafts[0]], selectedIndex: 0, tableID: app.selectedTableId,
                                         deleting: Set(originals.dropFirst().map(\.id))))
        drafts[0].name = "第一门修改"
        drafts[0].meetings[0].weeks = [1, 3]
        drafts[1].name = "第二门修改"
        drafts[1].meetings[0].slots = [3, 4]
        drafts[2].displayPriority = 8
        let beforeInvalidSave = app.courses
        var invalid = drafts
        invalid[2].meetings[0].weeks = []
        do {
            try app.saveCourseSchedules(invalid, tableID: app.selectedTableId)
            preconditionFailure("An invalid page must prevent the whole save")
        } catch { precondition(app.courses == beforeInvalidSave) }
        var missingPriority = drafts
        missingPriority[2].displayPriority = nil
        do {
            try app.saveCourseSchedules(missingPriority, tableID: app.selectedTableId)
            preconditionFailure("Unresolved overlaps after editing must not be saved")
        } catch { precondition(app.courses == beforeInvalidSave) }
        try app.saveCourseSchedules(drafts, tableID: app.selectedTableId)
        precondition(app.currentCourses.count == 3)
        precondition(app.currentCourses[0].name == "第一门修改" && app.currentCourses[0].weeks == [1, 3])
        precondition(app.currentCourses[1].name == "第二门修改" && app.currentCourses[1].startTime == 3)
        precondition(app.currentCourses[2].displayPriority == 8)
        precondition(app.currentCourses.map(\.id) == originals.map(\.id))
        // 暂存删除只提交被选中的课程，其他课程不受影响。
        try app.saveCourseSchedules([CourseScheduleDraft(courses: [app.currentCourses[0]])],
                                    tableID: app.selectedTableId, deleting: [originals[1].id])
        precondition(app.currentCourses.count == 2 && !app.currentCourses.contains { $0.id == originals[1].id })

        // 追加导入也必须包含已有课程的重叠；用户可以选择新课优先，已有课仍保留。
        app.install(payload: ImportedSchedule(name: "追加测试", courses: [duplicate]), mode: .replaceCurrent)
        let existing = app.currentCourses
        let incoming = ImportedSchedule(name: "追加", courses: [duplicate])
        precondition(ImportConflictFinder.hasUnresolvedConflicts(in: existing + incoming.courses, keeping: [:]))
        let appended = incoming.selectingDisplayPriorities([0: 1], existing: existing)
        app.install(payload: appended, mode: .appendToCurrent)
        precondition(app.currentCourses.count == 2 && app.currentCourses[0].id == existing[0].id)
        precondition(app.currentCourses[0].displayPriority == nil && app.currentCourses[1].displayPriority == 1)
        let preferExisting = incoming.selectingDisplayPriorities([0: 0], existing: app.currentCourses)
        precondition(preferExisting.displayPriorityUpdates[existing[0].id] == 1)

        print("ImportConflictChecks passed")
    }
}
