import Foundation

/// Turns a week's classified courses into grid coordinates.
///
/// Layout follows the Flutter app's `CourseWidget`: a meeting is placed by
/// `weekTime` and `startTime` and spans `timeCount + 1` rows. When two meetings
/// overlap, `ScheduleLogic` has already grouped them; the group is drawn side by
/// side inside the shared cell, which is what `setFlag` / `multiCourses` did
/// there. Meetings that do not run in the displayed week are always listed, drawn
/// as a translucent "非本周" card.
nonisolated struct ScheduleLayout {
    struct Placed: Identifiable {
        let id: Int
        let day: Int
        /// Inclusive slot range.
        let startSlot: Int
        let endSlot: Int
        let lane: Int
        /// How many columns this cell is split into. It is per cell, not per
        /// day: one conflict must not narrow every other course on that day.
        let laneCount: Int
        /// Every meeting sharing this cell, the visible one first.
        let sessions: [Course]
        /// Whether the visible session meets in the displayed week.
        let isThisWeek: Bool

        var face: Course { sessions.first ?? sessions[0] }
    }

    struct DayColumns {
        var lanes: Int = 1
        var placed: [Placed] = []
        var hidden: [Placed] = []
    }

    /// `day -> columns`
    private(set) var columnsByDay: [Int: DayColumns] = [:]
    private(set) var free: [Course] = []

    init(logic: ScheduleLogic, days: [Int]) {
        free = logic.freeCourses

        for day in days {
            var entry = DayColumns()
            let dayLanes = (logic.lanes + logic.ghostLanes).filter { $0.face.weekTime == day }
            var columns: [Lane] = []

            // Both the current week's meetings and the "非本周" ghosts go through
            // the same allocator, so a ghost can never cover a live course and
            // two ghosts in the same slot sit side by side.
            for lane in dayLanes {
                guard let face = lane.group.first else { continue }
                let start = max(1, face.startTime)
                let end = max(start, face.endTime)
                let index = allocateLane(start: start, end: end, into: &columns)
                // A conflict group draws one card per meeting side by side; a
                // single meeting always takes the whole cell.
                let laneCount = max(1, lane.group.count)
                columns[index].laneCount = max(columns[index].laneCount, laneCount)
                entry.lanes = max(entry.lanes, laneCount)

                let placed = Placed(
                    id: face.id,
                    day: day,
                    startSlot: start,
                    endSlot: end,
                    lane: index,
                    laneCount: columns[index].laneCount,
                    sessions: lane.group,
                    isThisWeek: face.weeks.contains(logic.nowWeek)
                )
                if placed.isThisWeek {
                    entry.placed.append(placed)
                } else {
                    entry.hidden.append(placed)
                }
            }
            columnsByDay[day] = entry
        }
    }

    /// One column of a day, with the slot ranges it already holds and how many
    /// sub-columns the cell there needs.
    private struct Lane {
        var ranges: [ClosedRange<Int>] = []
        var laneCount: Int = 1
    }

    /// First column whose occupied slots do not overlap this meeting.
    private func allocateLane(start: Int, end: Int, into columns: inout [Lane]) -> Int {
        for index in columns.indices {
            if columns[index].ranges.allSatisfy({ !$0.overlaps(start...end) }) {
                columns[index].ranges.append(start...end)
                return index
            }
        }
        columns.append(Lane(ranges: [start...end]))
        return columns.count - 1
    }

    func placed(for day: Int) -> [Placed] {
        columnsByDay[day]?.placed ?? []
    }

    func laneCount(for day: Int) -> Int {
        max(1, columnsByDay[day]?.lanes ?? 1)
    }

    func hiddenCourses(for day: Int) -> [Placed] {
        columnsByDay[day]?.hidden ?? []
    }

    /// The slot a tap on an empty cell should pre-fill.
    static func slot(at point: CGPoint, rowHeight: CGFloat, gap: CGFloat) -> Int {
        guard rowHeight > 0 else { return 1 }
        let step = rowHeight + gap
        let index = Int(floor(max(0, point.y - 1) / step))
        return max(1, index + 1)
    }
}

/// Sizing rules shared by the grid and the day header.
nonisolated struct GridMetrics: Equatable {
    var axisWidth: CGFloat = 40
    var gap: CGFloat = 3
    var laneGap: CGFloat = 2
    var headerHeight: CGFloat = 34
    /// Width of one page, i.e. the full schedule surface.
    var pageWidth: CGFloat = 360
    /// Height the grid may occupy.
    var availableHeight: CGFloat = 600
    /// Resolved row height (settings or fitted).
    var rowHeight: CGFloat = 50

    /// Width of the seven (or five) day columns together.
    var availableColumnWidth: CGFloat {
        max(120, pageWidth - axisWidth)
    }

    /// Width of one day column after the gaps between days come out.
    func cellWidth(days: Int) -> CGFloat {
        let count = max(1, days)
        return max(24, (availableColumnWidth - CGFloat(count - 1) * gap) / CGFloat(count))
    }

    /// Width of one course card inside a cell split into `lanes` columns.
    func laneWidth(days: Int, lanes: Int) -> CGFloat {
        let count = max(1, lanes)
        let cell = cellWidth(days: days)
        return max(16, (cell - CGFloat(count - 1) * laneGap) / CGFloat(count))
    }

    /// Horizontal offset of a lane inside its cell.
    func laneOffset(days: Int, lane: Int, lanes: Int) -> CGFloat {
        guard lanes > 1 else { return 0 }
        return CGFloat(lane) * (laneWidth(days: days, lanes: lanes) + laneGap)
    }

    func height(forSlots range: ClosedRange<Int>) -> CGFloat {
        let count = range.count
        return CGFloat(count) * rowHeight + CGFloat(max(0, count - 1)) * gap
    }

    func y(forSlot slot: Int) -> CGFloat {
        CGFloat(max(0, slot - 1)) * (rowHeight + gap)
    }

    func gridHeight(classes: Int) -> CGFloat {
        CGFloat(classes) * rowHeight + CGFloat(max(0, classes - 1)) * gap
    }
}
