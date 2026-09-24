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
            component.sort()
            let members = component.map { ImportConflictGroup.Member(id: $0, course: courses[$0]) }
            result.append(ImportConflictGroup(
                id: component[0],
                weekday: courses[component[0]].weekTime,
                startSlot: members.map(\.course.startTime).min() ?? 0,
                endSlot: members.map(\.course.endTime).max() ?? 0,
                members: members
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

    /// 要用户回答处理方式的成员：和保留的那节只有部分周次重叠的。
    /// 完全被盖住的不用问，整节收起来就是唯一的答案。
    static func membersNeedingDisposition(
        in group: ImportConflictGroup, keeping kept: Int
    ) -> [ImportConflictGroup.Member] {
        guard let keeper = group.members.first(where: { $0.id == kept }) else { return [] }
        return group.members.filter {
            $0.id != kept && partiallyOverlaps($0.course, keeping: keeper.course)
        }
    }

    /// 写库前的最终课程表。
    ///
    /// 没选中的行不会被丢掉，只是标成隐藏：课表里看不见，但还在，用户之后可以
    /// 在「隐藏的课程」里改主意。只让出部分周次的那节会拆成两行——照常上课的
    /// 周次留在明面上，重叠的周次收起来——这样两头都能还原。
    /// 还没做完选择的组原样保留，调用方在选完之前不该放行导入。
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
            for member in group.members where member.id != kept {
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
