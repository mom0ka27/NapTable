import Foundation

nonisolated struct TrialReminder: Identifiable, Equatable {
    enum Stage: String { case endingSoon, expired }
    let stage: Stage
    let expiresAt: Date

    var id: String { "\(expiresAt.timeIntervalSince1970)-\(stage.rawValue)" }
}

/// Automatic reminders are local, optional and limited to two per trial.
@MainActor
enum TrialReminderPolicy {
    static let advanceNotice: TimeInterval = 3 * 24 * 60 * 60
    static let classLeadTime: TimeInterval = 10 * 60
    static let minimumSpacing: TimeInterval = 24 * 60 * 60
    private static let historyKey = "naptable.trialReminder.presentations"

    static func pending(
        accessMode: PurchaseManager.AccessMode, state: PurchaseManager.State,
        expiresAt: Date?, now: Date, defaults: UserDefaults = .standard
    ) -> TrialReminder? {
        guard accessMode == .paid, state != .loading, state != .lifetime,
              let expiresAt, expiresAt.timeIntervalSince(now) <= advanceNotice else { return nil }
        let stage: TrialReminder.Stage
        if expiresAt <= now {
            stage = .expired
        } else {
            guard case .trial = state else { return nil }
            stage = .endingSoon
        }
        let reminder = TrialReminder(stage: stage, expiresAt: expiresAt)
        let history = defaults.dictionary(forKey: historyKey) as? [String: Double] ?? [:]
        guard history[reminder.id] == nil,
              history[TrialReminder(stage: .expired, expiresAt: expiresAt).id] == nil,
              history.values.allSatisfy({ now.timeIntervalSince1970 - $0 >= minimumSpacing }) else { return nil }
        return reminder
    }

    /// Call only once the page actually appears, never when a class defers it.
    static func markPresented(_ reminder: TrialReminder, now: Date = Date(), defaults: UserDefaults = .standard) {
        var history = defaults.dictionary(forKey: historyKey) as? [String: Double] ?? [:]
        guard history[reminder.id] == nil else { return }
        history[reminder.id] = now.timeIntervalSince1970
        defaults.set(history, forKey: historyKey)
    }

    /// Uses real dates, teaching weeks, holiday swaps and that day's bell times.
    /// A multi-period course protects only its first lead-in and actual class
    /// periods; breaks between its periods are available for reminders.
    /// Uncertain timing defers rather than guessing from the displayed week.
    static func isSafeToPresent(in snapshot: NativeScheduleSnapshot, now: Date) -> Bool {
        guard !snapshot.cancelled, snapshot.error == nil, let data = snapshot.data else { return false }
        let cells = data.cells.filter { $0.bigSlot > 0 && !$0.courses.isEmpty }
        guard !cells.isEmpty else { return true }
        guard let timetable = snapshot.calendar, !timetable.weeks.isEmpty,
              let zone = TimeZone(identifier: snapshot.timeZone ?? "Asia/Shanghai") else { return false }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        let firstDay = formatter.string(from: now)
        // Also covers a course starting just after midnight tomorrow.
        let lastDay = formatter.string(from: now.addingTimeInterval(classLeadTime))
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.isLenient = false

        func instant(_ day: String, _ clock: String) -> Date? {
            let text = day + " " + clock
            guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
            return date
        }

        for week in timetable.weeks {
            for (index, day) in week.days.enumerated() where firstDay <= day && day <= lastDay {
                let adjustment = timetable.adjustments[day]
                if adjustment?.suppressesCourses == true { continue }
                let sourceDay = adjustment?.sourceDay ?? index + 1
                let sourceWeek = adjustment?.sourceWeek ?? week.week
                let periods = Dictionary(snapshot.periods(on: day).map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
                for cell in cells where cell.day == sourceDay {
                    // Keep every conflict candidate, including the one hidden
                    // behind the selected face of an overlapping course block.
                    for course in cell.courses where course.weekList.isEmpty || course.weekList.contains(sourceWeek) {
                        guard let first = course.startSlot, let last = course.endSlot, last >= first,
                              let startPeriod = periods[first], let endPeriod = periods[last],
                              let start = instant(day, startPeriod.startTime),
                              let end = instant(day, endPeriod.endTime), end > start else { return false }
                        if start.addingTimeInterval(-classLeadTime) <= now && now < start { return false }
                        for number in first...last {
                            guard let period = periods[number],
                                  let periodStart = instant(day, period.startTime),
                                  let periodEnd = instant(day, period.endTime), periodEnd > periodStart else { return false }
                            if periodStart <= now && now < periodEnd { return false }
                        }
                    }
                }
            }
        }
        return true
    }
}
