import Foundation

@main
struct TrialReminderChecks {
    @MainActor static func main() throws {
        let suite = "naptable.trial-reminder.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
        let expiry = date("2026-10-08T08:00:00+08:00")
        func pending(_ now: Date, mode: PurchaseManager.AccessMode = .paid,
                     state: PurchaseManager.State = .locked, expiresAt: Date? = expiry) -> TrialReminder? {
            TrialReminderPolicy.pending(accessMode: mode, state: state, expiresAt: expiresAt, now: now, defaults: defaults)
        }
        let start = expiry.addingTimeInterval(-TrialReminderPolicy.advanceNotice)
        let trial = PurchaseManager.State.trial(expiresAt: expiry)
        precondition(pending(start.addingTimeInterval(-1), state: trial) == nil)
        let soon = pending(start, state: trial)!
        precondition(soon.stage == .endingSoon)
        for mode in [PurchaseManager.AccessMode.beta, .loading, .unavailable] {
            precondition(pending(start, mode: mode, state: trial) == nil)
            precondition(pending(expiry, mode: mode) == nil)
        }
        for state in [PurchaseManager.State.lifetime, .loading, .locked, .unavailable] {
            precondition(pending(start, state: state) == nil)
        }
        precondition(pending(expiry, expiresAt: nil) == nil, "Never-trialled or revoked receipts cannot trigger expiry reminders")
        precondition(pending(expiry, state: .lifetime) == nil)
        precondition(pending(expiry, state: trial)?.stage == .expired, "A long session must not retain the old trial stage")
        precondition(pending(expiry, state: .unavailable)?.stage == .expired,
                     "Missing product prices must not erase a verified expired trial")
        TrialReminderPolicy.markPresented(soon, now: start, defaults: defaults)
        precondition(pending(start.addingTimeInterval(86400), state: trial) == nil)
        let ended = pending(expiry)!
        precondition(ended.stage == .expired)
        TrialReminderPolicy.markPresented(ended, now: expiry, defaults: defaults)
        let reopened = UserDefaults(suiteName: suite)!
        precondition(TrialReminderPolicy.pending(accessMode: .paid, state: .locked, expiresAt: expiry,
                                                now: expiry.addingTimeInterval(10 * 86400), defaults: reopened) == nil,
                     "Relaunching must not repeat an acknowledged reminder")
        defaults.removePersistentDomain(forName: suite)
        TrialReminderPolicy.markPresented(soon, now: expiry.addingTimeInterval(-60), defaults: defaults)
        precondition(pending(expiry) == nil, "Do not show both stages back to back")
        precondition(pending(expiry.addingTimeInterval(86400))?.stage == .expired)
        print("PASS: three-day threshold, eligibility, exact expiry, persistent once-per-stage history and cooldown")

        let monday = "2026-10-05"
        let days = (5...11).map { String(format: "2026-10-%02d", $0) }
        func snapshot(
            courseDay: Int = 1, weeks: [Int] = [1], start: String = "09:00", end: String = "10:40",
            adjustments: [CalendarAdjustment] = [], seasons: [SeasonalClassTimes]? = nil,
            zone: String = "Asia/Shanghai", courseEnd: Int = 2
        ) -> NativeScheduleSnapshot {
            NativeScheduleSnapshot(
                completeSemester: true,
                periods: [NativeSchedulePeriod(number: 1, startTime: start, endTime: "09:45"),
                          NativeSchedulePeriod(number: 2, startTime: "09:55", endTime: end)],
                seasonalPeriods: seasons,
                data: NativeScheduleResult(currentSemester: "term", currentWeek: "8", cells: [
                    NativeScheduleCell(day: courseDay, bigSlot: 1, courses: [
                        NativeScheduleCourse(name: "课程", weekList: weeks, startSlot: 1, endSlot: courseEnd)
                    ])
                ]),
                calendar: NativeScheduleCalendar(weeks: [NativeCalendarWeek(week: 1, days: days)],
                    adjustments: CalendarAdjustmentResolver.index(adjustments, semesterStartMonday: monday)),
                timeZone: zone
            )
        }
        func safe(_ stamp: String, _ schedule: NativeScheduleSnapshot? = nil) -> Bool {
            TrialReminderPolicy.isSafeToPresent(in: schedule ?? snapshot(), now: date(stamp))
        }
        precondition(safe("2026-10-05T08:49:59+08:00"))
        precondition(!safe("2026-10-05T08:50:00+08:00"), "Exactly ten minutes before class is protected")
        precondition(!safe("2026-10-05T09:00:00+08:00"))
        precondition(safe("2026-10-05T09:45:00+08:00"), "The break starts exactly when the first period ends")
        precondition(safe("2026-10-05T09:50:00+08:00"), "A break is not a new ten-minute lead-in")
        precondition(safe("2026-10-05T09:54:59+08:00"))
        precondition(!safe("2026-10-05T09:55:00+08:00"), "The next period itself is protected")
        precondition(!safe("2026-10-05T10:39:59+08:00"))
        precondition(safe("2026-10-05T10:40:00+08:00"))
        precondition(safe("2026-10-06T09:10:00+08:00"))
        precondition(safe("2026-10-05T09:10:00+08:00", snapshot(weeks: [2])))
        precondition(!safe("2026-10-05T09:10:00+08:00", snapshot(weeks: [])))
        precondition(safe("2026-11-05T09:10:00+08:00"), "Outside the semester is quiet")
        let holiday = snapshot(adjustments: [.init(date: monday, kind: .off)])
        precondition(safe("2026-10-05T09:10:00+08:00", holiday))
        let swap = snapshot(adjustments: [.init(date: "2026-10-06", kind: .swap, source: monday)])
        precondition(safe("2026-10-05T09:10:00+08:00", swap), "Moved source day is free")
        precondition(!safe("2026-10-06T08:50:00+08:00", swap), "Make-up class has its own protected window")
        let seasons = [SeasonalClassTimes(from: "10-01", periods: [
            ClassTime(start: "13:00", end: "13:45"), ClassTime(start: "14:00", end: "14:45")
        ])]
        precondition(safe("2026-10-05T09:10:00+08:00", snapshot(seasons: seasons)))
        precondition(!safe("2026-10-05T12:50:00+08:00", snapshot(seasons: seasons)))
        precondition(!safe("2026-10-05T00:50:00Z"), "Device timezone must not change the school's class time")
        precondition(!safe("2026-10-05T15:50:00Z", snapshot(zone: "America/Los_Angeles")))
        let midnight = snapshot(courseDay: 2, start: "00:05", end: "10:40")
        precondition(safe("2026-10-05T23:54:59+08:00", midnight))
        precondition(!safe("2026-10-05T23:55:00+08:00", midnight))
        precondition(!safe("2026-10-05T09:10:00+08:00", snapshot(start: "bad")))
        precondition(!safe("2026-10-05T09:10:00+08:00", snapshot(courseEnd: 99)))
        precondition(!safe("2026-10-05T09:10:00+08:00", NativeScheduleSnapshot()))
        defaults.removePersistentDomain(forName: suite)
        precondition(!safe("2026-10-05T09:10:00+08:00"))
        precondition(pending(date("2026-10-05T10:40:00+08:00"), state: trial) != nil,
                     "Deferring for class must not consume the reminder")
        print("PASS: class and ten-minute boundaries, breaks, weeks, holidays, swaps, seasonal times, timezone, midnight and missing data")
    }
}
