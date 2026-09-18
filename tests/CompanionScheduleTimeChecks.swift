import Foundation

@main
struct CompanionScheduleTimeChecks {
    @MainActor static func main() async throws {
        let app = AppStore(fileURL: nil)
        let times = (1...13).map { index in
            ClassTime(start: String(format: "%02d:05", index + 6), end: String(format: "%02d:50", index + 6))
        }
        let course = Course(tableId: 0, name: "Imported late class", weeks: [1], weekTime: 1,
                            startTime: 12, timeCount: 1, importType: ImportKind.imported)
        let imported = ImportedSchedule(name: "Imported times", courses: [course],
                                        classTimeList: times, semesterStartMonday: "2026-09-14")
        app.install(payload: imported, mode: .newTable)
        precondition(app.classTimeList == times, "New imports must retain their clock times")
        precondition(app.selectedTable?.semesterStartMonday == "2026-09-14")
        let store = NativeScheduleStore()
        store.connect(app)
        let snapshot = store.snapshot()!
        precondition(snapshot.periods.count == 13, "Must not truncate to CpuTime's 11 slots")
        precondition(snapshot.periods[11].startTime == "18:05")
        precondition(snapshot.periods[12].endTime == "19:50")
        let payload = NativeWidgetSettings.payload(from: snapshot, selectedWeek: 1)!
        let widgetCourse = payload.weekDays!.first!.courses!.first!
        precondition(widgetCourse.startTime == "18:05" && widgetCourse.endTime == "19:50")
        #if os(iOS)
        let now = ISO8601DateFormatter().date(from: "2026-09-14T18:10:00+08:00")!
        let occurrence = NativeLiveActivityController.shared.nextOccurrence(in: snapshot, now: now)!
        precondition(occurrence.isInProgress)
        precondition(occurrence.start == ISO8601DateFormatter().date(from: "2026-09-14T18:05:00+08:00")!)
        precondition(occurrence.end == ISO8601DateFormatter().date(from: "2026-09-14T19:50:00+08:00")!)
        precondition(occurrence.periodLabel == "第 12-13 节")
        precondition(occurrence.dateLabel == "周一 · 第 1 周")
        let state = ScheduleLiveActivityAttributes.ContentState(
            phase: .inProgress, courseName: occurrence.name,
            startDate: occurrence.start, endDate: occurrence.end,
            updatedAt: occurrence.end.addingTimeInterval(60))
        precondition(state.countdownInterval.lowerBound == occurrence.end)
        precondition(state.countdownInterval.upperBound == occurrence.end)
        // Activities from the previous release have none of the new metadata.
        let legacy = """
        {"phase":"upcoming","courseName":"Legacy","teacher":"","location":"",
         "startDate":1000,"endDate":2000,"updatedAt":900}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ScheduleLiveActivityAttributes.ContentState.self, from: legacy)
        precondition(decoded.periodLabel == nil && decoded.nextCourseEnd == nil)
        print("PASS: Live Activity imported times, weekday, late countdown and legacy decoding")
        #endif
        let second = app.addTable(name: "Other school", semesterStartMonday: "2026-09-14",
                                  classTimeList: [ClassTime(start: "07:30", end: "08:20")])
        await store.refresh()
        precondition(store.snapshot()!.periods.first!.startTime == "07:30", "Switching tables must update companion times")
        app.updateClassTimeList([ClassTime(start: "07:45", end: "08:35")])
        await store.refresh()
        precondition(store.snapshot()!.periods.first!.startTime == "07:45", "Editing times must update snapshots")
        precondition(app.selectedTableId == second.id)
        app.updateClassTimeList([])
        await store.refresh()
        precondition(store.snapshot()!.periods.first!.endTime == SchoolDefaults.classTimeList.first!.end)
        print("PASS: imported times and dates, 13-slot widget range, table switching, time edits and local defaults")
    }
}
