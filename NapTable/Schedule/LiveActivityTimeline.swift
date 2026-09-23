#if os(iOS) || LIVE_ACTIVITY_CHECKS
import Foundation

@MainActor
struct LiveActivityTimeline {
    struct Conflict: Identifiable, Equatable {
        struct Choice: Identifiable, Equatable { var id: String; var name: String }
        var id: String
        var date: String
        var period: Int
        var choices: [Choice]
    }
    struct Result {
        var occurrences: [LiveActivityOccurrence]
        var conflicts: [Conflict]
        var omitted: Int
    }
    struct Identity: Codable {
        var id: String
        var source: String
        var day: String
        var first: Int
        var last: Int
        var supersedes: [String]
    }

    /// - Parameter own: The reader's own timetable. Only consulted when
    ///   `snapshot` is a followed share (it carries a `sourceLabel`); a course
    ///   of theirs that overlaps the share's frames is attached as the frame's
    ///   `companion` so the activity can show both.
    static func build(_ snapshot: NativeScheduleSnapshot, own: NativeScheduleSnapshot? = nil, scope: String, now: Date,
                      lead: Int, perPeriod: Bool, defaults: UserDefaults) -> Result {
        guard let data = snapshot.data, let calendar = snapshot.calendar,
              let zone = TimeZone(identifier: snapshot.timeZone ?? TimeZone.current.identifier) else {
            return Result(occurrences: [], conflicts: [], omitted: 0)
        }
        let formatter = instantFormatter(zone: zone)
        func instant(day: String, clock: String, zone: TimeZone) -> Double? {
            Self.instant(day: day, clock: clock, zone: zone, formatter: formatter)
        }
        let storage = "naptable.liveActivity.identities." + scope
        var identities = defaults.data(forKey: storage).flatMap { try? JSONDecoder().decode([String: Identity].self, from: $0) } ?? [:]
        let original = identities
        let choices = defaults.dictionary(forKey: "naptable.liveActivity.conflicts." + scope) as? [String: String] ?? [:]
        let periods = snapshot.periods
        let byNumber = Dictionary(periods.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        var result = Result(occurrences: [], conflicts: [], omitted: 0)
        var unassigned: Set<String> = []
        let limit = now.addingTimeInterval(180 * 86400).timeIntervalSince1970
        let companions = snapshot.sourceLabel == nil ? [] : own.map { companionSpans($0, now: now, limit: limit) } ?? []
        for week in calendar.weeks {
            for (index, day) in week.days.enumerated() {
                let adjustment = calendar.adjustments[day]
                if adjustment?.suppressesCourses == true { continue }
                let sourceDay = adjustment?.sourceDay ?? index + 1
                let sourceWeek = adjustment?.sourceWeek ?? week.week
                var occupants: [Int: [String: NativeScheduleCourse]] = [:]
                for cell in data.cells where cell.day == sourceDay || cell.bigSlot == 0 {
                    for course in cell.courses where course.weekList.isEmpty || course.weekList.contains(sourceWeek) {
                        guard cell.bigSlot > 0, let first = course.startSlot, let last = course.endSlot,
                              let source = course.liveActivitySourceID ?? course.nativeId,
                              first > 0, last >= first, last <= periods.count else {
                            unassigned.insert(course.liveActivitySourceID ?? course.customId ?? course.id)
                            continue
                        }
                        for period in first...last { occupants[period, default: [:]][source] = course }
                    }
                }
                var selected: [(Int, String, NativeScheduleCourse)] = []
                var unresolved = false
                for period in occupants.keys.sorted() {
                    guard let candidates = occupants[period] else { continue }
                    let key = day + ":" + String(period)
                    if candidates.count > 1 {
                        result.conflicts.append(Conflict(id: key, date: day, period: period,
                            choices: candidates.sorted { $0.key < $1.key }.map { .init(id: $0.key, name: $0.value.name) }))
                    }
                    let source = candidates.count == 1 ? candidates.keys.first : choices[key]
                    guard let source, let course = candidates[source] else { unresolved = true; continue }
                    selected.append((period, source, course))
                }
                // Do not schedule partially resolved days; reminder occupancy would be incomplete.
                if unresolved { continue }
                var segments: [[(Int, String, NativeScheduleCourse)]] = []
                for value in selected {
                    if let last = segments.last?.last, last.1 == value.1, last.0 + 1 == value.0 {
                        segments[segments.count - 1].append(value)
                    } else { segments.append([value]) }
                }
                var previousEnd: Double = 0
                for segment in segments {
                    guard let first = segment.first, let last = segment.last,
                          let firstPeriod = byNumber[first.0], let lastPeriod = byNumber[last.0],
                          let start = instant(day: day, clock: firstPeriod.startTime, zone: zone),
                          let end = instant(day: day, clock: lastPeriod.endTime, zone: zone), end > start else { result.omitted += 1; continue }
                    let reminder = max(start - Double(lead * 60), previousEnd)
                    previousEnd = end
                    guard end > now.timeIntervalSince1970, start < limit else { continue }
                    guard end - reminder <= 8 * 3600 else { result.omitted += 1; continue }
                    let key = "\(first.1):\(day):\(first.0):\(last.0)"
                    if identities[key] == nil {
                        let ancestors = original.values.filter { $0.source == first.1 && $0.day == day && $0.first <= last.0 && $0.last >= first.0 }.map(\.id).sorted()
                        identities[key] = Identity(id: UUID().uuidString, source: first.1, day: day, first: first.0, last: last.0, supersedes: ancestors)
                    }
                    let identity = identities[key]!
                    let course = first.2
                    func state(from: Double, until: Double, upcoming: Bool) -> ScheduleLiveActivityAttributes.ContentState {
                        .init(phase: upcoming ? .upcoming : .inProgress, courseName: course.name,
                              teacher: course.teacher ?? "", location: course.location ?? "",
                              periodLabel: "第 \(first.0)–\(last.0) 节", dateLabel: day, weekRangeLabel: course.weeks,
                              startDate: Date(timeIntervalSince1970: upcoming ? start : from),
                              endDate: Date(timeIntervalSince1970: until), sourceLabel: snapshot.sourceLabel,
                              adjustmentNote: adjustment?.detail, updatedAt: Date(timeIntervalSince1970: from))
                    }
                    var frames: [LiveActivityOccurrence.Frame] = []
                    if reminder < start { frames.append(.init(from: reminder, until: start, state: state(from: reminder, until: end, upcoming: true))) }
                    if perPeriod {
                        for value in segment {
                            guard let period = byNumber[value.0],
                                  let a = instant(day: day, clock: period.startTime, zone: zone),
                                  let b = instant(day: day, clock: period.endTime, zone: zone) else { continue }
                            if let previous = frames.last, previous.until < a {
                                let pause = ScheduleLiveActivityAttributes.ContentState(phase: .upcoming, courseName: course.name, teacher: course.teacher ?? "", location: course.location ?? "", periodLabel: "课间 · 第 \(value.0) 节", dateLabel: day, startDate: Date(timeIntervalSince1970: a), endDate: Date(timeIntervalSince1970: b), sourceLabel: snapshot.sourceLabel, adjustmentNote: adjustment?.detail, updatedAt: Date(timeIntervalSince1970: previous.until))
                                frames.append(.init(from: previous.until, until: a, state: pause))
                            }
                            frames.append(.init(from: a, until: b, state: state(from: a, until: b, upcoming: false)))
                        }
                    } else { frames.append(.init(from: start, until: end, state: state(from: start, until: end, upcoming: false))) }
                    if !companions.isEmpty { frames = attach(companions, to: frames) }
                    result.occurrences.append(.init(item: .init(occurrenceId: identity.id, supersedes: identity.supersedes, dateKey: day, startPeriod: first.0, endPeriod: last.0), sourceID: first.1, start: start, end: end, reminder: reminder, frames: frames))
                }
            }
        }
        if let encoded = try? JSONEncoder().encode(identities) { defaults.set(encoded, forKey: storage) }
        result.omitted += unassigned.count
        result.occurrences.sort { $0.reminder < $1.reminder }
        return result
    }

    static func instant(day: String, clock: String, zone: TimeZone) -> Double? {
        instant(day: day, clock: clock, zone: zone, formatter: instantFormatter(zone: zone))
    }

    struct CompanionSpan: Equatable {
        var start: Double
        var end: Double
        var companion: ScheduleLiveActivityAttributes.ContentState.Companion
    }

    /// Every course of the reader's own timetable as an absolute interval.
    ///
    /// Only a display hint, so it is deliberately forgiving: conflicting
    /// courses are all kept (the earliest wins at render time) and courses
    /// without a reliable time are skipped instead of counted as omitted.
    static func companionSpans(_ own: NativeScheduleSnapshot, now: Date, limit: Double) -> [CompanionSpan] {
        guard let data = own.data, let calendar = own.calendar,
              let zone = TimeZone(identifier: own.timeZone ?? TimeZone.current.identifier) else { return [] }
        let formatter = instantFormatter(zone: zone)
        let byNumber = Dictionary(own.periods.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        let current = now.timeIntervalSince1970
        var spans: [CompanionSpan] = []
        for week in calendar.weeks {
            for (index, day) in week.days.enumerated() {
                let adjustment = calendar.adjustments[day]
                if adjustment?.suppressesCourses == true { continue }
                let sourceDay = adjustment?.sourceDay ?? index + 1
                let sourceWeek = adjustment?.sourceWeek ?? week.week
                for cell in data.cells where cell.bigSlot > 0 && cell.day == sourceDay {
                    for course in cell.courses where course.weekList.isEmpty || course.weekList.contains(sourceWeek) {
                        guard let first = course.startSlot, let last = course.endSlot, last >= first,
                              let firstPeriod = byNumber[first], let lastPeriod = byNumber[last],
                              let start = instant(day: day, clock: firstPeriod.startTime, zone: zone, formatter: formatter),
                              let end = instant(day: day, clock: lastPeriod.endTime, zone: zone, formatter: formatter),
                              end > start, end > current, start < limit else { continue }
                        let span = CompanionSpan(start: start, end: end, companion: .init(
                            courseName: course.name, teacher: course.teacher ?? "", location: course.location ?? "",
                            periodLabel: first == last ? "第 \(first) 节" : "第 \(first)–\(last) 节",
                            startDate: Date(timeIntervalSince1970: start), endDate: Date(timeIntervalSince1970: end)))
                        if !spans.contains(span) { spans.append(span) }
                    }
                }
            }
        }
        return spans.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    /// Splits `frames` wherever one of the reader's own courses starts or
    /// ends, so each resulting frame either has one concurrent course of theirs
    /// for its whole duration or none at all.
    static func attach(_ spans: [CompanionSpan], to frames: [LiveActivityOccurrence.Frame]) -> [LiveActivityOccurrence.Frame] {
        frames.flatMap { frame -> [LiveActivityOccurrence.Frame] in
            let overlapping = spans.filter { $0.start < frame.until && $0.end > frame.from }
            guard !overlapping.isEmpty else { return [frame] }
            let cuts = Set(overlapping.flatMap { [$0.start, $0.end] }.filter { frame.from < $0 && $0 < frame.until })
            let edges = [frame.from] + cuts.sorted() + [frame.until]
            return zip(edges, edges.dropFirst()).map { from, until in
                let active = overlapping.first { $0.start <= from && from < $0.end }
                return .init(from: from, until: until, state: frame.state.with(companion: active?.companion))
            }
        }
    }

    private static func instantFormatter(zone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.isLenient = false
        return formatter
    }

    private static func instant(day: String, clock: String, zone: TimeZone, formatter: DateFormatter) -> Double? {
        let text = day + " " + clock
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        // Match the server's refusal of ambiguous DST boundaries.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let previous = calendar.startOfDay(for: date).addingTimeInterval(-1)
        let first = calendar.nextDate(after: previous, matching: parts, matchingPolicy: .strict, repeatedTimePolicy: .first)
        let last = calendar.nextDate(after: previous, matching: parts, matchingPolicy: .strict, repeatedTimePolicy: .last)
        guard first == last else { return nil }
        return date.timeIntervalSince1970
    }
}
#endif
