import Foundation

@main
struct ImportConflictChecks {
    @MainActor static func main() {
        func course(
            _ name: String, day: Int, start: Int, count: Int = 1, weeks: [Int] = Array(1...16)
        ) -> Course {
            Course(tableId: 0, name: name, weeks: weeks, weekTime: day,
                   startTime: start, timeCount: count, importType: ImportKind.imported)
        }

        // MARK: 撞车判定

        // 同一天、节次相交、周次也相交：撞车。
        let 高数 = course("高等数学", day: 3, start: 3)
        let 线代 = course("线性代数", day: 3, start: 4)
        precondition(ImportConflictFinder.collide(高数, 线代))

        // 单双周轮流的实验课节次完全重合，但永远不会在同一周碰面。
        let 单周 = course("实验 A", day: 1, start: 1, weeks: [1, 3, 5, 7])
        let 双周 = course("实验 B", day: 1, start: 1, weeks: [2, 4, 6, 8])
        precondition(!ImportConflictFinder.collide(单周, 双周))
        precondition(ImportConflictFinder.groups(in: [单周, 双周]).isEmpty)

        // 节次不相邻、星期不同、自由时间：都不算冲突。
        precondition(!ImportConflictFinder.collide(高数, course("体育", day: 3, start: 6)))
        precondition(!ImportConflictFinder.collide(高数, course("英语", day: 4, start: 3)))
        let 自由 = Course(tableId: 0, name: "自由时间", weeks: Array(1...16), weekTime: 0,
                        startTime: 0, timeCount: 0, importType: ImportKind.imported)
        precondition(!ImportConflictFinder.collide(自由, 自由))

        // MARK: 分组

        // 一组两节：组 id 是组内第一门课的下标，范围覆盖两节课。
        let pair = [course("体育", day: 5, start: 1), 高数, 线代]
        let groups = ImportConflictFinder.groups(in: pair)
        precondition(groups.count == 1)
        precondition(groups[0].id == 1 && groups[0].members.map(\.id) == [1, 2])
        precondition(groups[0].weekday == 3 && groups[0].startSlot == 3 && groups[0].endSlot == 5)
        precondition(groups[0].title == "周三 第3-5节")

        // A 撞 B、B 撞 C，但 A 和 C 不相交：三节必须进同一组，
        // 否则用户选完一组之后另外两节还叠着。
        let chain = [course("A", day: 2, start: 1, count: 1),
                     course("B", day: 2, start: 2, count: 1),
                     course("C", day: 2, start: 3, count: 1)]
        precondition(!ImportConflictFinder.collide(chain[0], chain[2]))
        let chained = ImportConflictFinder.groups(in: chain)
        precondition(chained.count == 1 && chained[0].members.map(\.id) == [0, 1, 2])

        // 两个互不相干的冲突组，各自独立。
        let two = [高数, 线代, course("物理", day: 6, start: 1), course("化学", day: 6, start: 1)]
        precondition(ImportConflictFinder.groups(in: two).map(\.id) == [0, 2])

        // 没有课、只有一节课时不该报冲突。
        precondition(ImportConflictFinder.groups(in: []).isEmpty)
        precondition(ImportConflictFinder.groups(in: [高数]).isEmpty)

        // MARK: 完全重叠——没选中的整节收起来

        let resolved = ImportConflictFinder.apply(
            keeping: [1: 2], dispositions: [:], to: pair, groups: groups
        )
        // 一节都没少，只是让位的那节被收起来了。
        precondition(resolved.map(\.name) == ["体育", "高等数学", "线性代数"])
        precondition(resolved.map(\.isHidden) == [false, true, false])

        // 还没选的组原样保留，也不能有谁被收起来。
        let untouched = ImportConflictFinder.apply(
            keeping: [:], dispositions: [:], to: pair, groups: groups
        )
        precondition(untouched == pair && untouched.allSatisfy { !$0.isHidden })
        // 选了个不在组里的下标同样按「没选」处理。
        precondition(ImportConflictFinder.apply(
            keeping: [1: 0], dispositions: [:], to: pair, groups: groups
        ) == pair)

        // MARK: 部分重叠——要问用户

        let 早半程 = course("专业课", day: 4, start: 1, weeks: Array(1...8))
        let 全学期 = course("选修课", day: 4, start: 1, weeks: Array(1...16))
        precondition(ImportConflictFinder.partiallyOverlaps(全学期, keeping: 早半程))
        // 反过来不算：早半程整个被盖住，收起来不会误伤任何一周。
        precondition(!ImportConflictFinder.partiallyOverlaps(早半程, keeping: 全学期))

        let partial = [早半程, 全学期]
        let partialGroups = ImportConflictFinder.groups(in: partial)
        precondition(partialGroups.count == 1)
        // 保留早半程时要问全学期那节怎么办；反过来不用问。
        precondition(ImportConflictFinder.membersNeedingDisposition(in: partialGroups[0], keeping: 0)
            .map(\.id) == [1])
        precondition(ImportConflictFinder.membersNeedingDisposition(in: partialGroups[0], keeping: 1).isEmpty)
        precondition(ImportConflictFinder.overlappingWeeks(全学期, keeping: 早半程) == Array(1...8))
        precondition(ImportConflictFinder.remainingWeeks(全学期, keeping: 早半程) == Array(9...16))

        // 整节收起来：第 9-16 周也跟着看不见了，这正是要先问一句的原因。
        let wholeHidden = ImportConflictFinder.apply(
            keeping: [0: 0], dispositions: [1: .hideCourse], to: partial, groups: partialGroups
        )
        precondition(wholeHidden.count == 2)
        precondition(wholeHidden[1].isHidden && wholeHidden[1].weeks == Array(1...16))

        // 只收起重叠的周次：拆成明面上的 9-16 周和收起来的 1-8 周，两头都能还原。
        let split = ImportConflictFinder.apply(
            keeping: [0: 0], dispositions: [1: .hideOverlap], to: partial, groups: partialGroups
        )
        precondition(split.count == 3)
        precondition(split[0].name == "专业课" && !split[0].isHidden)
        precondition(split[1].name == "选修课" && !split[1].isHidden && split[1].weeks == Array(9...16))
        precondition(split[2].name == "选修课" && split[2].isHidden && split[2].weeks == Array(1...8))

        // 选了保留哪一节但还没回答处理方式：原样保留，不能擅自收起来。
        precondition(ImportConflictFinder.apply(
            keeping: [0: 0], dispositions: [:], to: partial, groups: partialGroups
        ) == partial)

        // MARK: 文案

        let member = ImportConflictGroup.Member(
            id: 0, course: course("X", day: 1, start: 1, weeks: [1, 2, 3, 5, 9, 10])
        )
        precondition(member.weeksText == "第 1-3,5,9-10 周")

        // MARK: 旧存档

        // `hidden` 是后加的键，旧存档里没有它，必须还能解出来；
        // 没被收起来的课也不该因为这个键而多写一段 JSON。
        let legacy = Data(#"""
        {"id":1,"tableId":1,"name":"旧课","weeks":[1],"weekTime":1,"startTime":1,
         "timeCount":1,"importType":1}
        """#.utf8)
        let decoded = try! JSONDecoder().decode(Course.self, from: legacy)
        precondition(!decoded.isHidden)
        let encoded = String(data: try! JSONEncoder().encode(decoded), encoding: .utf8)!
        precondition(!encoded.contains("hidden"))

        // MARK: 收起来的课不进课表

        let app = AppStore(fileURL: nil)
        app.deleteAllCourses()
        let table = app.install(
            payload: ImportedSchedule(name: "冲突课表", courses: resolved), mode: .replaceCurrent
        )
        precondition(app.selectedTableId == table.id)
        // 三节都写进去了，但让位的那节不出现在课表里。
        precondition(app.currentCourses.map(\.name) == ["体育", "线性代数"])
        precondition(app.currentHiddenCourses.map(\.name) == ["高等数学"])
        // 网格、分享、通知都走 currentCourses，所以那一节确实不会画在格子里。
        func drawn(_ day: Int) -> [ScheduleLayout.Placed] {
            app.layout(forWeek: 1, days: [day]).columnsByDay[day]?.placed ?? []
        }
        precondition(!drawn(3).flatMap(\.sessions).contains { $0.name == "高等数学" })

        // 之后随时可以改主意。
        let restored = app.currentHiddenCourses[0]
        app.setCourse(id: restored.id, hidden: false)
        precondition(app.currentHiddenCourses.isEmpty)
        precondition(app.currentCourses.count == 3)
        // 恢复之后它又和原来那节撞在一起，课表把两节并排画在同一个格子里。
        precondition(drawn(3).contains { $0.sessions.count == 2 })

        print("ImportConflictChecks passed")
    }
}
