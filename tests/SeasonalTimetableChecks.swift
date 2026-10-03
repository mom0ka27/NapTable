import Foundation

@main
struct SeasonalTimetableChecks {
    struct Fixture: Decodable {
        struct Day: Decodable { var date: String; var start: String; var end: String }
        var seasons: [SeasonalClassTimes]
        var days: [Day]
    }

    @MainActor static func main() async throws {
        let fixture = try JSONDecoder().decode(Fixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        precondition(SeasonalClassTimes.defaults(for: "xjtu") == fixture.seasons)
        let winter = fixture.seasons[1].periods
        for day in fixture.days {
            let clocks = SeasonalClassTimes.resolve(on: day.date, base: winter, seasons: fixture.seasons)
            precondition(clocks[4].start == day.start && clocks[5].end == day.end)
            precondition(clocks[0].start == "08:00" && clocks[3].end == "12:00")
        }
        precondition(SeasonalClassTimes.resolve(on: "2026-05-01", base: winter, seasons: []) == winter)

        func snapshot(monday: String, adjustments: [CalendarAdjustment] = [], source: String? = nil) -> NativeScheduleSnapshot {
            let anchor = WeekCalculator.parseDay(monday)!
            let days = (0..<7).map { WeekCalculator.format(WeekCalculator.calendar.date(byAdding: .day, value: $0, to: anchor)!) }
            let courses = (1...7).map { NativeScheduleCell(day: $0, bigSlot: 3, courses: [
                NativeScheduleCourse(liveActivitySourceID: "course-\($0)", name: "下午课", weeks: "1周", weekList: [1], startSlot: 5, endSlot: 6)
            ]) }
            return NativeScheduleSnapshot(scheduleScope: "xjtu-scope", periods: winter.enumerated().map {
                NativeSchedulePeriod(number: $0.offset + 1, startTime: $0.element.start, endTime: $0.element.end)
            }, seasonalPeriods: fixture.seasons,
            data: NativeScheduleResult(currentSemester: "term", currentWeek: "1", cells: courses),
            calendar: NativeScheduleCalendar(weeks: [NativeCalendarWeek(week: 1, days: days)],
                adjustments: CalendarAdjustmentResolver.index(adjustments, semesterStartMonday: monday)),
            auth: NativeScheduleAuth(authenticated: true, account: source == nil ? nil : "SHARE"),
            sourceLabel: source, schoolID: "xjtu", timeZone: "Asia/Shanghai")
        }
        func stamp(_ day: String, _ clock: String) -> Double {
            ISO8601DateFormatter().date(from: day + "T" + clock + ":00+08:00")!.timeIntervalSince1970
        }
        let fall = snapshot(monday: "2026-09-28")
        for (monday, before, after) in [("2026-04-27", "2026-04-30", "2026-05-01"),
                                      ("2026-09-28", "2026-09-30", "2026-10-01"),
                                      ("2026-12-28", "2026-12-31", "2027-01-01")] {
            let schedule = snapshot(monday: monday)
            let now = Date(timeIntervalSince1970: stamp(before, "00:00"))
            let occurrences = LiveActivityTimeline.build(schedule, now: now, lead: 30, perPeriod: true).occurrences
            precondition(occurrences.map(\.dateKey) == [before, after])
            let own = LiveActivityTimeline.ownCourses(schedule, perPeriod: true, now: now, limit: now.timeIntervalSince1970 + 2 * 86400)
            for occurrence in occurrences {
                let expected = fixture.days.first { $0.date == occurrence.dateKey }!
                precondition(occurrence.start == stamp(expected.date, expected.start))
                precondition(occurrence.end == stamp(expected.date, expected.end))
                precondition(occurrence.reminder == occurrence.start - 1800)
                precondition(occurrence.frames.count == 4, "Reminder, two periods and the break")
                precondition(own.first { $0.day == expected.date }?.start == occurrence.start)
            }
            let payload = NativeWidgetSettings.payload(from: schedule, selectedWeek: 1)!
            for day in [before, after] {
                let expected = fixture.days.first { $0.date == day }!
                let course = payload.weekDays!.first { $0.date == day }!.courses!.first!
                precondition(course.startTime == expected.start && course.endTime == expected.end)
            }
        }
        let shifted = snapshot(monday: "2026-09-28", adjustments: [
            CalendarAdjustment(date: "2026-09-30", kind: .swap, source: "2026-10-01", note: "补课")
        ])
        let shiftedOccurrence = LiveActivityTimeline.build(shifted,
            now: Date(timeIntervalSince1970: stamp("2026-09-30", "00:00")), lead: 30, perPeriod: false).occurrences
        precondition(shiftedOccurrence.count == 1 && shiftedOccurrence[0].start == stamp("2026-09-30", "14:30"),
                     "A moved October course uses September's actual-day summer clocks")
        let upload = LiveActivityTimeline.timetable(own: fall, share: nil, choices: [:], lead: 30, sharedLead: 30, perPeriod: true)!
        let ownBody = upload["own"] as! [String: Any]
        let seasons = try JSONDecoder().decode([SeasonalClassTimes].self,
            from: JSONSerialization.data(withJSONObject: ownBody["seasonalPeriods"]!))
        precondition(seasons == fixture.seasons && ownBody["schoolID"] as? String == "xjtu")
        let uploadData = try JSONSerialization.data(withJSONObject: upload)
        precondition(!String(decoding: uploadData, as: UTF8.self).contains("下午课"))

        let ics = NativeScheduleICSExporter.make(result: fall.data!, week: fall.calendar!.weeks[0],
            periods: fall.periods, seasonalPeriods: fall.seasonalPeriods)
        precondition(ics.contains("DTSTART;TZID=Asia/Shanghai:20260930T143000"))
        precondition(ics.contains("DTSTART;TZID=Asia/Shanghai:20261001T140000"))

        let app = AppStore(fileURL: nil)
        var imported = ImportedSchedule(name: "西交大", courses: [Course(tableId: 0, name: "下午课", weeks: [], weekTime: 4,
            startTime: 5, timeCount: 1, importType: ImportKind.imported)], classTimeList: winter, semesterStartMonday: "2026-09-28", schoolID: "xjtu", termID: "fall", termWeekCount: 18)
        imported.seasonalPeriods = fixture.seasons
        app.install(payload: imported, mode: .newTable)
        let store = NativeScheduleStore()
        store.connect(app)
        await store.selectWeek("1")
        precondition(store.periods[4].startTime == "14:30")
        await store.selectWeek("2")
        precondition(store.periods[4].startTime == "14:00")
        precondition(store.periods(on: "2026-09-30")[4].startTime == "14:30")
        precondition(store.snapshot()!.seasonalPeriods == fixture.seasons)
        let encoded = try JSONEncoder().encode(app.selectedTable!)
        let restored = try JSONDecoder().decode(CourseTable.self, from: encoded)
        precondition(restored.classTimes(on: "2027-05-01")[4].start == "14:30")
        var legacyObject = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacyObject.removeValue(forKey: "seasonalPeriods")
        let legacy = try JSONDecoder().decode(CourseTable.self, from: JSONSerialization.data(withJSONObject: legacyObject))
        precondition(legacy.classTimes(on: "2026-09-30")[4].start == "14:30")
        var disabled = legacy
        disabled.seasonalPeriods = []
        precondition(disabled.classTimes(on: "2026-09-30")[4].start == "14:00")
        let frozen = try CoursePayloadCodec.decode(object: ["name": "共享", "courses": [], "schoolID": "xjtu", "seasonalPeriods": []])
        precondition(frozen.seasonalPeriods == [])
        print("PASS: XJTU seasonal boundaries, daily widget clocks, local reservations, per-period breaks, swaps, ICS, APNs upload, previews and legacy archives")
    }
}
