import Foundation

/// Port of the Flutter app's `ScheduleModel`: splits a table's courses into the
/// ones that meet this week, the ones that do not, the free-time ones, and the
/// overlapping groups that must share a grid cell.
///
/// The classification and overlap rules are a straight translation of
/// `lib/Models/ScheduleModel.dart`, including the deliberate choice to prefer the
/// longest meeting in a conflict group as the group's visible face.
nonisolated struct ScheduleLogic {
    /// Courses that meet in the displayed week.
    private(set) var activeCourses: [Course] = []
    /// Courses that belong to the table but not to the displayed week.
    private(set) var hiddenCourses: [Course] = []
    /// Courses without a fixed weekday (`weekTime == 0`).
    private(set) var freeCourses: [Course] = []
    /// Overlapping meetings, grouped by the cell they share.
    private(set) var multiCourses: [[Course]] = []

    let nowWeek: Int

    init(courses: [Course], nowWeek: Int) {
        self.nowWeek = nowWeek
        classify(courses)
        deduplicate()
    }

    /// Everything the grid should draw: non-overlapping singles first, then one
    /// entry per conflict group. The first element of a group is its face.
    var visibleCourses: [Course] {
        activeCourses + multiCourses.compactMap { $0.first }.filter { isThisWeek($0) }
    }

    /// Conflict groups whose face meets this week.
    var visibleMultiCourses: [[Course]] {
        multiCourses.filter { group in
            guard let first = group.first else { return false }
            return isThisWeek(first)
        }
    }

    func isThisWeek(_ course: Course) -> Bool {
        course.weeks.contains(nowWeek)
    }

    /// The chronological neighbours used by the editor when a user changes the
    /// day or slot of one meeting.
    func group(containing course: Course) -> [Course] {
        for group in multiCourses where group.contains(where: { $0.id == course.id }) {
            return group
        }
        return []
    }

    // MARK: - Classification

    private mutating func classify(_ courses: [Course]) {
        for course in courses {
            if course.isFreeTime {
                freeCourses.append(course)
            } else if course.weeks.contains(nowWeek) {
                activeCourses.append(course)
            } else if course.isLecture, let first = course.weeks.first, first < nowWeek {
                // A lecture that already happened is dropped instead of being
                // listed as a course of another week.
                continue
            } else {
                hiddenCourses.append(course)
            }
        }
    }

    // MARK: - Conflict merging

    private mutating func deduplicate() {
        var singles: [Course] = []
        var consumed: [Int] = []

        // Both passes have to read the same source lists and only then update
        // them: mutating `activeCourses` after the first pass would leave the
        // second pass iterating a stale array, and a course consumed by the
        // first pass would silently vanish from the grid.
        let source = activeCourses + hiddenCourses
        // `activeCourses` first so a conflict group's face is as likely as
        // possible to be a course of the displayed week.
        merge(&singles, &consumed, from: activeCourses)
        merge(&singles, &consumed, from: hiddenCourses)
        _ = source

        activeCourses.removeAll { course in consumed.contains(course.id) }
        hiddenCourses.removeAll { course in consumed.contains(course.id) }
    }

    private mutating func merge(_ singles: inout [Course], _ consumed: inout [Int], from source: [Course]) {
        for course in source {
            var joined = false
            for index in multiCourses.indices {
                guard let head = multiCourses[index].first else { continue }
                if overlaps(course, head) {
                    multiCourses[index].append(course)
                    reorderFace(&multiCourses[index])
                    joined = true
                    break
                }
            }
            if joined { continue }

            if let hit = singles.firstIndex(where: { overlaps(course, $0) }) {
                let previous = singles[hit]
                var group = [course, previous]
                reorderFace(&group)
                multiCourses.append(group)
                singles.remove(at: hit)
                consumed.append(course.id)
                consumed.append(previous.id)
                continue
            }

            singles.append(course)
        }
    }

    /// `ScheduleModel._checkIfOverlapping`: same weekday and intersecting slot
    /// ranges. Unmerged free-time courses never reach this path.
    private func overlaps(_ a: Course, _ b: Course) -> Bool {
        guard a.weekTime == b.weekTime, a.weekTime != 0 else { return false }
        return (a.startTime >= b.startTime && a.startTime <= b.endTime)
            || (b.startTime >= a.startTime && b.startTime <= a.endTime)
    }

    /// `ScheduleModel._checkMultiCoursesElement`: the longest meeting that also
    /// runs this week becomes the group's face.
    private func reorderFace(_ group: inout [Course]) {
        var bestIndex = 0
        var bestCount = 0
        for (index, course) in group.enumerated() where course.timeCount > bestCount && course.weeks.contains(nowWeek) {
            bestCount = course.timeCount
            bestIndex = index
        }
        if bestIndex != 0 {
            group.swapAt(0, bestIndex)
        }
    }
}

/// A conflict group placed on the grid: the group's face plus the number of
/// lanes the cell has to split into.
nonisolated struct ScheduleLane: Identifiable {
    let id: Int
    let group: [Course]

    var face: Course { group[0] }
}

extension ScheduleLogic {
    /// Every non-overlapping meeting and conflict group as a lane, keyed by the
    /// face course's row id.
    var lanes: [ScheduleLane] {
        let singles = activeCourses.map { ScheduleLane(id: $0.id, group: [$0]) }
        let multi = multiCourses.compactMap { group -> ScheduleLane? in
            guard let face = group.first else { return nil }
            return ScheduleLane(id: face.id, group: group)
        }
        return singles + multi
    }

    /// Meetings of other weeks. They are drawn as ghosts, so the grid needs them
    /// in the same shape as `lanes`.
    var ghostLanes: [ScheduleLane] { hiddenCourses.map { ScheduleLane(id: $0.id, group: [$0]) } }

    var freeLanes: [ScheduleLane] { freeCourses.map { ScheduleLane(id: $0.id, group: [$0]) } }
}
