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
        /// The occurrence on the clock. Missing on identities stored before
        /// the reader's own courses could merge in.
        var start: Double? = nil
        var end: Double? = nil
    }

    /// - Parameters:
    ///   - own: The reader's own timetable. Only consulted when `snapshot` is a
    ///     followed share (it carries a `sourceLabel`).
    ///   - mergesOwn: Whether the reader's own courses get reminders too. When
    ///     set, courses of both timetables that overlap in time become one
    ///     occurrence (the share leads while it is in class, the reader's
    ///     course rides along as the `companion`) and the rest of the reader's
    ///     courses become occurrences of their own. Items are then placed by
    ///     their instants, so only a token-mode plan can carry them. Otherwise
    ///     the reader's courses are only attached to the share's frames.
    static func build(_ snapshot: NativeScheduleSnapshot, own: NativeScheduleSnapshot? = nil, mergesOwn: Bool = false, scope: String, now: Date,
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
        let merging = mergesOwn && snapshot.sourceLabel != nil
        let mine = snapshot.sourceLabel == nil ? [] : own.map { ownCourses($0, perPeriod: perPeriod, now: now, limit: limit) } ?? []
        let companions = companionSpans(of: mine, lead: merging ? lead : nil)
        var pieces: [Piece] = []
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
                    pieces.append(Piece(key: "\(first.1):\(day):\(first.0):\(last.0)", source: first.1, day: day, first: first.0, last: last.0,
                                        start: start, end: end, reminder: reminder, frames: frames,
                                        upcoming: { state(from: $0, until: end, upcoming: true) }))
                }
            }
        }
        // Occurrence ids survive rebuilds. A new one supersedes what it replaces:
        // by periods of the same source, or when merging, anything on the clock it now covers.
        func identify(_ key: String, source: String, day: String, first: Int, last: Int, start: Double, end: Double, sharing: [Piece]?) -> Identity {
            if let identity = identities[key] { return identity }
            let ancestors = original.values.filter { old in
                guard old.day == day else { return false }
                guard let sharing else { return old.source == source && old.first <= last && old.last >= first }
                if let a = old.start, let b = old.end { return a < end && b > start }
                return sharing.contains { old.source == $0.source && old.first <= $0.last && old.last >= $0.first }
            }.map(\.id).sorted().prefix(64)
            let identity = Identity(id: UUID().uuidString, source: source, day: day, first: first, last: last, supersedes: Array(ancestors), start: start, end: end)
            identities[key] = identity
            return identity
        }
        if merging {
            let ownPieces = mine.filter { $0.end - $0.start <= 8 * 3600 }.map { course in
                Piece(key: course.key, source: course.source, day: course.day, first: course.first, last: course.last,
                      start: course.start, end: course.end, reminder: course.start - Double(lead * 60),
                      frames: ([course.lead(minutes: lead)].compactMap { $0 } + course.spans).map { .init(from: $0.start, until: $0.end, state: course.state($0.companion)) },
                      upcoming: { course.state(course.upcoming(from: $0)) }, isOwn: true)
            }
            var clusters: [[Piece]] = []
            for piece in (pieces + ownPieces).sorted(by: { ($0.start, $0.isOwn ? 1 : 0) < ($1.start, $1.isOwn ? 1 : 0) }) {
                if let end = clusters.last?.map(\.end).max(), piece.start < end { clusters[clusters.count - 1].append(piece) }
                else { clusters.append([piece]) }
            }
            var previousEnd: Double = 0
            for cluster in clusters {
                let start = cluster.map(\.start).min()!, end = cluster.map(\.end).max()!
                let reminder = max(start - Double(lead * 60), previousEnd)
                previousEnd = end
                // The share leads wherever it has a frame; the reader's own
                // course fills the rest, a class before a break, the earliest
                // first; the earliest course's countdown covers what is left
                // of the reminder window.
                let shared = cluster.filter { !$0.isOwn }.flatMap(\.frames)
                let owned = cluster.filter(\.isOwn).flatMap(\.frames)
                    .sorted { ($0.state.phase == .inProgress ? 0 : 1, $0.from) < ($1.state.phase == .inProgress ? 0 : 1, $1.from) }
                let opening = cluster[0]
                let fallback = reminder < opening.start ? [LiveActivityOccurrence.Frame(from: reminder, until: opening.start, state: opening.upcoming(reminder))] : []
                let frames = overlay(shared + owned + fallback, from: reminder, until: end)
                // Named after its opening course, so a course of either table
                // joining or leaving later keeps an activity that already started.
                let key = opening.key
                // A chain of overlapping courses can outlast one activity: hand
                // over to a fresh one at a frame boundary.
                var chunks: [[LiveActivityOccurrence.Frame]] = []
                for frame in frames {
                    if let head = chunks.last?.first, frame.until - head.from <= 8 * 3600 { chunks[chunks.count - 1].append(frame) }
                    else { chunks.append([frame]) }
                }
                // Every later course reminds when it would have on its own, if
                // the activity is already on screen by then.
                let joins = Set(cluster.dropFirst().map { max($0.reminder, reminder) }.filter { $0 > reminder })
                guard end > now.timeIntervalSince1970 else { continue }
                for (index, chunk) in chunks.enumerated() {
                    guard let from = chunk.first?.from, let until = chunk.last?.until, until > now.timeIntervalSince1970 else { continue }
                    let begins = index == 0 ? start : from
                    let identity = identify(index == 0 ? key : key + "#\(index)", source: opening.source, day: opening.day,
                                            first: opening.first, last: opening.last, start: begins, end: until, sharing: cluster.filter { !$0.isOwn })
                    result.occurrences.append(.init(item: .init(occurrenceId: identity.id, supersedes: identity.supersedes, dateKey: opening.day, start: begins, end: until),
                                                    sourceID: opening.source, start: begins, end: until, reminder: index == 0 ? reminder : from, frames: chunk,
                                                    alerts: Array(joins.filter { from < $0 && $0 < until }.sorted().prefix(16))))
                }
            }
        } else {
            for piece in pieces {
                let identity = identify(piece.key, source: piece.source, day: piece.day, first: piece.first, last: piece.last, start: piece.start, end: piece.end, sharing: nil)
                result.occurrences.append(.init(item: .init(occurrenceId: identity.id, supersedes: identity.supersedes, dateKey: piece.day, startPeriod: piece.first, endPeriod: piece.last),
                                                sourceID: piece.source, start: piece.start, end: piece.end, reminder: piece.reminder, frames: piece.frames))
            }
        }
        if let encoded = try? JSONEncoder().encode(identities) { defaults.set(encoded, forKey: storage) }
        result.omitted += unassigned.count
        result.occurrences.sort { $0.reminder < $1.reminder }
        return result
    }

    /// One course of either timetable placed on the clock, before merging.
    private struct Piece {
        var key: String
        var source: String
        var day: String
        var first: Int
        var last: Int
        var start: Double
        var end: Double
        var reminder: Double
        var frames: [LiveActivityOccurrence.Frame]
        /// Its countdown to class from the given instant.
        var upcoming: (Double) -> ScheduleLiveActivityAttributes.ContentState
        var isOwn = false
    }

    /// Lays `candidates` over `from..<until`: at every instant the first one
    /// covering it wins. Neighbours left with the same state are joined so a
    /// token-mode activity is not pushed where nothing changes.
    static func overlay(_ candidates: [LiveActivityOccurrence.Frame], from: Double, until: Double) -> [LiveActivityOccurrence.Frame] {
        let edges = Set(candidates.flatMap { [$0.from, $0.until] } + [from, until]).filter { from <= $0 && $0 <= until }.sorted()
        var frames: [LiveActivityOccurrence.Frame] = []
        for (a, b) in zip(edges, edges.dropFirst()) {
            guard let winner = candidates.first(where: { $0.from <= a && a < $0.until }) else { continue }
            if let last = frames.last, last.until == a, last.state == winner.state { frames[frames.count - 1].until = b }
            else { frames.append(.init(from: a, until: b, state: winner.state)) }
        }
        return frames
    }

    static func instant(day: String, clock: String, zone: TimeZone) -> Double? {
        instant(day: day, clock: clock, zone: zone, formatter: instantFormatter(zone: zone))
    }

    struct CompanionSpan: Equatable {
        var start: Double
        var end: Double
        var companion: ScheduleLiveActivityAttributes.ContentState.Companion
    }

    /// One course of the reader's own timetable on the clock.
    struct OwnCourse {
        var key: String
        var source: String
        var day: String
        var first: Int
        var last: Int
        var start: Double
        var end: Double
        var weeks: String
        var note: String?
        /// The class, split per period with breaks between under 分节计时.
        var spans: [CompanionSpan]

        /// Counting down to class from `from`.
        func upcoming(from: Double) -> ScheduleLiveActivityAttributes.ContentState.Companion {
            let head = spans[0].companion
            return .init(phase: .upcoming, courseName: head.courseName, teacher: head.teacher, location: head.location,
                         periodLabel: first == last ? "第 \(first) 节" : "第 \(first)–\(last) 节",
                         startDate: Date(timeIntervalSince1970: start), endDate: Date(timeIntervalSince1970: end), updatedAt: Date(timeIntervalSince1970: from))
        }
        /// The reminder window before class.
        func lead(minutes: Int) -> CompanionSpan? {
            let from = start - Double(minutes * 60)
            return from < start ? CompanionSpan(start: from, end: start, companion: upcoming(from: from)) : nil
        }
        /// The same course leading the activity, when the share has no class then.
        func state(_ companion: ScheduleLiveActivityAttributes.ContentState.Companion) -> ScheduleLiveActivityAttributes.ContentState {
            .init(phase: companion.phase, courseName: companion.courseName, teacher: companion.teacher, location: companion.location,
                  periodLabel: companion.periodLabel, dateLabel: day, weekRangeLabel: weeks,
                  startDate: companion.startDate, endDate: companion.endDate, sourceLabel: nil,
                  adjustmentNote: note, updatedAt: companion.updatedAt)
        }
    }

    /// Every course of the reader's own timetable as absolute intervals.
    ///
    /// `perPeriod` is the same 分节计时 setting the shared course follows:
    /// each period becomes its own span and the gap before the next period a
    /// break span counting down to it. Otherwise a course is one span.
    ///
    /// Deliberately forgiving: conflicting courses are all kept (a class beats
    /// a break, then the earliest wins at render time) and courses without a
    /// reliable time are skipped instead of counted as omitted.
    static func ownCourses(_ own: NativeScheduleSnapshot, perPeriod: Bool = false, now: Date, limit: Double) -> [OwnCourse] {
        guard let data = own.data, let calendar = own.calendar,
              let zone = TimeZone(identifier: own.timeZone ?? TimeZone.current.identifier) else { return [] }
        let formatter = instantFormatter(zone: zone)
        let byNumber = Dictionary(own.periods.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        let current = now.timeIntervalSince1970
        var courses: [OwnCourse] = []
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
                        let source = course.liveActivitySourceID ?? course.nativeId ?? course.id
                        let key = "own:\(source):\(day):\(first):\(last)"
                        guard !courses.contains(where: { $0.key == key }) else { continue }
                        let label = first == last ? "第 \(first) 节" : "第 \(first)–\(last) 节"
                        func span(_ phase: ScheduleLiveActivityAttributes.ContentState.Phase, _ from: Double, _ until: Double,
                                  label: String, start: Double, end: Double) -> CompanionSpan {
                            CompanionSpan(start: from, end: until, companion: .init(
                                phase: phase, courseName: course.name, teacher: course.teacher ?? "", location: course.location ?? "",
                                periodLabel: label, startDate: Date(timeIntervalSince1970: start),
                                endDate: Date(timeIntervalSince1970: end), updatedAt: Date(timeIntervalSince1970: from)))
                        }
                        // Mirrors the shared course's per-period frames: the
                        // course label while in class, "课间 · 第 n 节" between.
                        let bells = perPeriod && last > first ? (first...last).map { number -> (Int, Double, Double)? in
                            guard let period = byNumber[number],
                                  let a = instant(day: day, clock: period.startTime, zone: zone, formatter: formatter),
                                  let b = instant(day: day, clock: period.endTime, zone: zone, formatter: formatter), b > a else { return nil }
                            return (number, a, b)
                        } : []
                        var pieces: [CompanionSpan] = []
                        if !bells.isEmpty, !bells.contains(where: { $0 == nil }) {
                            let bells = bells.compactMap { $0 }
                            for (index, bell) in bells.enumerated() {
                                if index > 0, bells[index - 1].2 < bell.1 {
                                    pieces.append(span(.upcoming, bells[index - 1].2, bell.1, label: "课间 · 第 \(bell.0) 节", start: bell.1, end: bell.2))
                                }
                                pieces.append(span(.inProgress, bell.1, bell.2, label: label, start: bell.1, end: bell.2))
                            }
                        } else {
                            pieces = [span(.inProgress, start, end, label: label, start: start, end: end)]
                        }
                        courses.append(OwnCourse(key: key, source: source, day: day, first: first, last: last, start: start, end: end,
                                                 weeks: course.weeks, note: adjustment?.detail, spans: pieces))
                    }
                }
            }
        }
        return courses.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    /// The reader's courses as companion rows. With `lead`, each also shows up
    /// that many minutes early, counting down to its start.
    static func companionSpans(of courses: [OwnCourse], lead: Int? = nil, now: Date? = nil) -> [CompanionSpan] {
        var spans: [CompanionSpan] = []
        for course in courses {
            for piece in (lead.flatMap { course.lead(minutes: $0) }.map { [$0] } ?? []) + course.spans
            where piece.end > (now?.timeIntervalSince1970 ?? -.infinity) && !spans.contains(piece) { spans.append(piece) }
        }
        return spans.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    static func companionSpans(_ own: NativeScheduleSnapshot, perPeriod: Bool = false, now: Date, limit: Double) -> [CompanionSpan] {
        companionSpans(of: ownCourses(own, perPeriod: perPeriod, now: now, limit: limit), now: now)
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
                let covering = overlapping.filter { $0.start <= from && from < $0.end }
                let active = covering.first { $0.companion.phase == .inProgress } ?? covering.first
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
