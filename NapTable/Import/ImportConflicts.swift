import Foundation

/// 导入时重叠的课程。选择只决定显示优先级，所有课程均完整保留。
nonisolated struct ImportConflictGroup: Identifiable, Equatable {
    /// 组内第一门课在 `ImportedSchedule.courses` 里的下标。一次解析之内稳定。
    let id: Int
    /// 1 = 周一 … 7 = 周日。
    let weekday: Int
    /// 整组占用的节次范围，取组内的最早和最晚。
    let startSlot: Int
    let endSlot: Int
    let members: [Member]
    /// 第几轮分组：0 是 `groups(in:)` 直接给的，选择优先显示之后，其余成员重新
    /// 分出来的是 1，依此类推。
    var level = 0
    /// 这次导入的课程总数。后续分组的 id 是「组内第一节的下标 + stride × level」，
    /// 这样它不会和上一轮的组撞 id，`conflictChoice` 可以继续按 id 记。
    var stride = 0
    /// 已选首位实际覆盖的周次与节次；其余区域仍需明确优先级。
    var coveredBy: [Course] = []

    nonisolated struct Member: Identifiable, Equatable {
        /// `ImportedSchedule.courses` 的下标。课程这时还没有 `Course.id`，
        /// 那要等 `AppStore.install` 写库时才分配，所以只能按下标定位。
        let id: Int
        let course: Course

        /// 「第 1-8,10 周」。和课程详情页用的是同一个格式化。
        var weeksText: String { WeekSeries.summary(course.weeks) }

        /// 「张三 · 仙Ⅰ-319」。教师和教室都没有时返回空串。
        var subtitle: String {
            let teacher = course.teacher?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let room = course.classroom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return [teacher, room].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    /// 「周三 第3-4节」
    var title: String {
        let day = WeekCalculator.weekdayName(weekday)
        return startSlot == endSlot ? "\(day) 第\(startSlot)节" : "\(day) 第\(startSlot)-\(endSlot)节"
    }

    /// 和所选课程真正重叠的成员（含它自己），用于确定哪些成员还可独立选优先级。
    func members(collidingWith kept: Int) -> [Member] {
        guard let keeper = members.first(where: { $0.id == kept }) else { return [] }
        return members.filter { $0.id == kept || ImportConflictFinder.collide($0.course, keeper.course) }
    }

    /// 和所选课程不重叠的成员，可以另行选择显示顺序。
    func membersUnaffected(by kept: Int) -> [Member] {
        members.filter { member in !members(collidingWith: kept).contains { $0.id == member.id } }
    }

    /// 首位已覆盖的重叠无需再选；它不上的周次、节次继续检查。
    func remainingGroups(keeping kept: Int) -> [ImportConflictGroup] {
        guard let selected = members.first(where: { $0.id == kept }) else { return [] }
        return ImportConflictFinder.components(
            of: members.filter { $0.id != kept }, stride: stride, level: level + 1,
            coveredBy: coveredBy + [selected.course]
        )
    }

}

nonisolated enum ImportConflictFinder {
    /// 同一天、节次相交、并且确实有共同周次的两行才算撞车。
    ///
    /// 周次这一条不能省：单双周轮流上的实验课节次完全重合，只看节次会把它们
    /// 全部误报成冲突，它们不需要选择显示优先级。
    static func collide(_ a: Course, _ b: Course) -> Bool {
        guard !a.isFreeTime, !b.isFreeTime, a.weekTime == b.weekTime else { return false }
        guard a.startTime <= b.endTime, b.startTime <= a.endTime else { return false }
        return !Set(a.weeks).isDisjoint(with: b.weeks)
    }

    /// 把撞车的行按连通分量分组：A 撞 B、B 撞 C 时三行要一起选，
    /// 同组课程可以选择优先显示顺序。
    static func groups(in courses: [Course]) -> [ImportConflictGroup] {
        guard courses.count > 1 else { return [] }
        let members = courses.enumerated().map { ImportConflictGroup.Member(id: $0.offset, course: $0.element) }
        return components(of: members, stride: courses.count, level: 0)
    }

    /// 顶层分组加上每组选定之后剩下的后续分组，按「父组后面紧跟它的后续组」排列。
    /// 界面按这个顺序逐组选择显示优先级，写库时也把它原样交给 `apply`。
    static func expandedGroups(in courses: [Course], keeping choice: [Int: Int]) -> [ImportConflictGroup] {
        var result: [ImportConflictGroup] = []
        func visit(_ group: ImportConflictGroup) {
            result.append(group)
            guard let kept = choice[group.id] else { return }
            group.remainingGroups(keeping: kept).forEach(visit)
        }
        groups(in: courses).forEach(visit)
        return result
    }

    /// 在给定的成员里按撞车关系求连通分量。
    static func components(
        of candidates: [ImportConflictGroup.Member], stride: Int, level: Int, coveredBy: [Course] = []
    ) -> [ImportConflictGroup] {
        let courses = candidates.map(\.course)
        guard courses.count > 1 else { return [] }
        var adjacency = [Set<Int>](repeating: [], count: courses.count)
        for i in courses.indices {
            for j in courses.indices where j > i && collide(courses[i], courses[j], outside: coveredBy) {
                adjacency[i].insert(j)
                adjacency[j].insert(i)
            }
        }

        var seen = Set<Int>()
        var result: [ImportConflictGroup] = []
        for start in courses.indices where !seen.contains(start) && !adjacency[start].isEmpty {
            var stack = [start]
            var component: [Int] = []
            seen.insert(start)
            while let index = stack.popLast() {
                component.append(index)
                for next in adjacency[index].sorted() where !seen.contains(next) {
                    seen.insert(next)
                    stack.append(next)
                }
            }
            let members = component.map { candidates[$0] }.sorted { $0.id < $1.id }
            result.append(ImportConflictGroup(
                id: members[0].id + stride * level,
                weekday: members[0].course.weekTime,
                startSlot: members.map(\.course.startTime).min() ?? 0,
                endSlot: members.map(\.course.endTime).max() ?? 0,
                members: members,
                level: level,
                stride: stride,
                coveredBy: coveredBy
            ))
        }
        return result
    }

    /// 判断是否还有已选课程未覆盖的实际重叠，避免相同三门课要求重复选择。
    private static func collide(_ a: Course, _ b: Course, outside coveredBy: [Course]) -> Bool {
        guard collide(a, b) else { return false }
        let sharedWeeks = Set(a.weeks).intersection(b.weeks)
        for week in sharedWeeks {
            for slot in max(a.startTime, b.startTime)...min(a.endTime, b.endTime) {
                if !coveredBy.contains(where: {
                    $0.weekTime == a.weekTime && $0.weeks.contains(week)
                        && $0.startTime <= slot && slot <= $0.endTime
                }) { return true }
            }
        }
        return false
    }

    /// 每一轮重叠都必须选定优先课程。旧选择不属于当前组时也视为未完成。
    static func hasUnresolvedConflicts(in courses: [Course], keeping choice: [Int: Int]) -> Bool {
        expandedGroups(in: courses, keeping: choice).contains { group in
            guard let selected = choice[group.id] else { return true }
            return !group.members.contains { $0.id == selected }
        }
    }

    /// 选择只记录优先级，不隐藏或拆分课程。调用方必须先检查所有组已完成选择。
    static func apply(
        keeping choice: [Int: Int], to courses: [Course], groups: [ImportConflictGroup]
    ) -> [Course] {
        var result = courses
        for group in groups {
            for member in group.members { result[member.id].displayPriority = nil }
        }
        for (index, group) in groups.enumerated() {
            guard let selected = choice[group.id],
                  group.members.contains(where: { $0.id == selected }),
                  result.indices.contains(selected) else { continue }
            result[selected].displayPriority = groups.count - index
        }
        return result
    }
}

nonisolated extension ImportedSchedule {
    func selectingDisplayPriorities(_ choice: [Int: Int], existing: [Course] = []) -> ImportedSchedule {
        let combined = existing + courses
        let groups = ImportConflictFinder.expandedGroups(in: combined, keeping: choice)
        let resolved = ImportConflictFinder.apply(keeping: choice, to: combined, groups: groups)
        var result = self
        result.courses = Array(resolved.dropFirst(existing.count))
        result.displayPriorityUpdates = Dictionary(uniqueKeysWithValues: resolved.prefix(existing.count).map {
            ($0.id, $0.displayPriority ?? 0)
        })
        return result
    }

}
