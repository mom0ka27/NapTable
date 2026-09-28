import Foundation

/// 没选中的那节课怎么处理。整节让位还是只让出重叠的几周，只有用户知道，
/// 所以周次只是部分重叠时要问一句。
nonisolated enum ImportConflictDisposition: String, CaseIterable, Identifiable {
    /// 整节收起来，一周都不显示。
    case hideCourse
    /// 只收起和保留那节重叠的周次，其余周次照常上课。
    case hideOverlap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hideCourse: return "整节收起来"
        case .hideOverlap: return "只收起重叠的周次"
        }
    }
}

/// 导入时撞在同一个时段的几节课。
///
/// 课表本身能把重叠的课并排画成两条车道（见 `ScheduleLogic`），但那只是先把
/// 两节都显示出来，并没有回答「这个时段到底上哪节」。教务偶尔会把同一门课导
/// 出两遍，学生也可能真的选到同一时段的两门课，所以导入时先把真正撞车的行挑
/// 出来，交给用户自己选一节。
nonisolated struct ImportConflictGroup: Identifiable, Equatable {
    /// 组内第一门课在 `ImportedSchedule.courses` 里的下标。一次解析之内稳定。
    let id: Int
    /// 1 = 周一 … 7 = 周日。
    let weekday: Int
    /// 整组占用的节次范围，取组内的最早和最晚。
    let startSlot: Int
    let endSlot: Int
    let members: [Member]
    /// 第几轮分组：0 是 `groups(in:)` 直接给的，保留一节之后剩下的成员重新
    /// 分出来的是 1，依此类推。
    var level = 0
    /// 这次导入的课程总数。后续分组的 id 是「组内第一节的下标 + stride × level」，
    /// 这样它不会和上一轮的组撞 id，`conflictChoice` 可以继续按 id 记。
    var stride = 0

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

    /// 和 `kept` 真正撞在一起的成员（含 `kept` 自己）。
    ///
    /// 组按连通分量划分（A 撞 B、B 撞 C 时三节同组），但 A 和 C 可能节次毫无
    /// 交集：只处理「和保留那节 collide 为真」的成员，A 和 C 才能留到用户之后
    /// 自己选，而不是被连带整节收起来。
    func members(collidingWith kept: Int) -> [Member] {
        guard let keeper = members.first(where: { $0.id == kept }) else { return [] }
        return members.filter { $0.id == kept || ImportConflictFinder.collide($0.course, keeper.course) }
    }

    /// 和保留那节不撞、因此不受它影响的成员。
    func membersUnaffected(by kept: Int) -> [Member] {
        members.filter { member in !members(collidingWith: kept).contains { $0.id == member.id } }
    }

    /// 保留 `kept` 之后，其余成员按「和谁撞」重新分组，让用户接着一组一组选。
    func remainingGroups(keeping kept: Int) -> [ImportConflictGroup] {
        guard members.contains(where: { $0.id == kept }) else { return [] }
        return ImportConflictFinder.components(
            of: membersUnaffected(by: kept), stride: stride, level: level + 1
        )
    }
}

nonisolated enum ImportConflictFinder {
    /// 同一天、节次相交、并且确实有共同周次的两行才算撞车。
    ///
    /// 周次这一条不能省：单双周轮流上的实验课节次完全重合，只看节次会把它们
    /// 全部误报成冲突，用户反而会被迫删掉一半的课。
    static func collide(_ a: Course, _ b: Course) -> Bool {
        guard !a.isFreeTime, !b.isFreeTime, a.weekTime == b.weekTime else { return false }
        guard a.startTime <= b.endTime, b.startTime <= a.endTime else { return false }
        return !Set(a.weeks).isDisjoint(with: b.weeks)
    }

    /// 把撞车的行按连通分量分组：A 撞 B、B 撞 C 时三行要一起选，
    /// 否则用户选完 A 之后 B 和 C 仍然叠在一起。
    static func groups(in courses: [Course]) -> [ImportConflictGroup] {
        guard courses.count > 1 else { return [] }
        let members = courses.enumerated().map { ImportConflictGroup.Member(id: $0.offset, course: $0.element) }
        return components(of: members, stride: courses.count, level: 0)
    }

    /// 顶层分组加上每组选定之后剩下的后续分组，按「父组后面紧跟它的后续组」排列。
    /// 界面按这个顺序逐组提问，写库时也把它原样交给 `apply`。
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
        of candidates: [ImportConflictGroup.Member], stride: Int, level: Int
    ) -> [ImportConflictGroup] {
        let courses = candidates.map(\.course)
        guard courses.count > 1 else { return [] }
        var adjacency = [Set<Int>](repeating: [], count: courses.count)
        for i in courses.indices {
            for j in courses.indices where j > i && collide(courses[i], courses[j]) {
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
                stride: stride
            ))
        }
        return result
    }

    /// 和保留的那节撞在一起的周次。
    static func overlappingWeeks(_ member: Course, keeping kept: Course) -> [Int] {
        let shared = Set(kept.weeks)
        return member.weeks.filter { shared.contains($0) }.sorted()
    }

    /// 让出重叠周次之后，这节课还能照常上的周次。
    static func remainingWeeks(_ member: Course, keeping kept: Course) -> [Int] {
        let shared = Set(kept.weeks)
        return member.weeks.filter { !shared.contains($0) }.sorted()
    }

    /// 没选中的那节和保留的那节只有部分周次撞在一起——这种情况整节收起来会
    /// 连不冲突的周次一起抹掉，所以要回头问用户。
    static func partiallyOverlaps(_ member: Course, keeping kept: Course) -> Bool {
        !overlappingWeeks(member, keeping: kept).isEmpty
            && !remainingWeeks(member, keeping: kept).isEmpty
    }

    /// 要用户回答处理方式的成员：和保留的那节撞在一起、且只有部分周次重叠的。
    /// 完全被盖住的不用问，整节收起来就是唯一的答案。
    static func membersNeedingDisposition(
        in group: ImportConflictGroup, keeping kept: Int
    ) -> [ImportConflictGroup.Member] {
        guard let keeper = group.members.first(where: { $0.id == kept }) else { return [] }
        return group.members(collidingWith: kept).filter {
            $0.id != kept && partiallyOverlaps($0.course, keeping: keeper.course)
        }
    }

    /// 还没做完的选择：任何一组没选保留哪一节，或者有成员缺处理方式。
    /// 界面用它决定「导入」按钮能不能点。
    static func hasUnresolvedConflicts(
        in courses: [Course], keeping choice: [Int: Int],
        dispositions: [Int: ImportConflictDisposition]
    ) -> Bool {
        expandedGroups(in: courses, keeping: choice).contains { group in
            // 上一轮改了选择之后，后续组里残留的旧选择可能已经不在组里了。
            guard let kept = choice[group.id], group.members.contains(where: { $0.id == kept }) else { return true }
            return membersNeedingDisposition(in: group, keeping: kept)
                .contains { dispositions[$0.id] == nil }
        }
    }

    /// 写库前的最终课程表。
    ///
    /// 没选中的行不会被丢掉，只是标成隐藏：课表里看不见，但还在，用户之后可以
    /// 在「隐藏的课程」里改主意。只让出部分周次的那节会拆成两行——照常上课的
    /// 周次留在明面上，重叠的周次收起来——这样两头都能还原。
    /// 还没做完选择的组原样保留，调用方在选完之前不该放行导入。
    /// `groups` 应当是 `expandedGroups` 的结果，后续分组里的选择才会生效。
    static func apply(
        keeping choice: [Int: Int],
        dispositions: [Int: ImportConflictDisposition],
        to courses: [Course],
        groups: [ImportConflictGroup]
    ) -> [Course] {
        /// 下标 -> 这一行要改写成的那些行。没有登记的下标原样保留。
        var rewrites: [Int: [Course]] = [:]
        for group in groups {
            guard let kept = choice[group.id],
                  let keeper = group.members.first(where: { $0.id == kept }) else { continue }
            // 只处理真的和保留那节撞在一起的成员。组里其余成员是被连通分量带进来的，
            // 它们不受这一节影响，留在原处等用户在后续分组里自己选。
            for member in group.members(collidingWith: kept) where member.id != kept {
                guard partiallyOverlaps(member.course, keeping: keeper.course) else {
                    rewrites[member.id] = [hiding(member.course)]
                    continue
                }
                switch dispositions[member.id] {
                case .hideCourse:
                    rewrites[member.id] = [hiding(member.course)]
                case .hideOverlap:
                    var visible = member.course
                    visible.weeks = remainingWeeks(member.course, keeping: keeper.course)
                    var overlapping = member.course
                    overlapping.weeks = overlappingWeeks(member.course, keeping: keeper.course)
                    rewrites[member.id] = [visible, hiding(overlapping)]
                case nil:
                    // 还没回答，原样保留。
                    continue
                }
            }
        }
        guard !rewrites.isEmpty else { return courses }
        return courses.enumerated().flatMap { index, course in
            rewrites[index] ?? [course]
        }
    }

    private static func hiding(_ course: Course) -> Course {
        var value = course
        value.hidden = true
        return value
    }
}
