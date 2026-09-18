import Foundation

/// Port of the Flutter app's `CourseParser` (NJU 教务 page) and
/// `CourseParserXK` (NJU 选课 page).
///
/// Both originals walked a DOM and then fed the same "周三 第1-2节 1-16周 仙Ⅱ-304"
/// string into their week-number helpers. This port keeps the two page layouts
/// separate and shares the string reader, which is the part with all the real
/// rules in it.
nonisolated enum CourseHTMLParser {
    // MARK: - Legacy NJU 教务 page

    /// `CourseParser.parseCourseName()` — "2025-2026学年第1学期". The live page
    /// writes the semester as an Arabic digit, the old one used 一 / 二.
    static func courseTableName(fromHTML html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "[0-9]{4}-[0-9]{4}\\s*学年第\\s*[一二三四1-4]\\s*学期") else {
            return nil
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let value = Range(match.range, in: html) else { return nil }
        return String(html[value])
    }

    /// `CourseParser.parseCourse(tableId:)`
    static func parseLegacyJWCourses(fromHTML html: String) -> [Course] {
        let document = LightHTML.parse(html)
        let rows = document.root.descendants(withClass: "TABLE_TR_01")
            + document.root.descendants(withClass: "TABLE_TR_02")
        var result: [Course] = []

        for row in rows {
            let cells = directCells(of: row)
            guard cells.count > 4 else { continue }

            // 退选课程
            if cells.count > 6, cells[6].trimmedText.contains("已退选") { continue }

            let courseName = clean(cells[1].trimmedText)
            let teacher = cells.count > 3 ? clean(cells[3].trimmedText) : ""
            let testTime = cells.count > 8 ? clean(cells[8].trimmedText) : ""
            let testLocation = cells.count > 9 ? clean(cells[9].trimmedText) : ""
            let info = cells.count > 10 ? clean(cells[10].trimmedText) : ""
            // `trimmedText` turns the `<br>` markers into real newlines; the raw
            // `plainText` would keep the whole cell on one line.
            let timeAndPlace = cells[4].trimmedText

            for line in splitMeetings(timeAndPlace) {
                guard let meeting = MeetingParser.parse(line) else { continue }
                result.append(Course(
                    tableId: 0,
                    name: courseName,
                    weeks: meeting.weeks,
                    weekTime: meeting.weekday,
                    startTime: meeting.startSlot,
                    timeCount: meeting.timeCount,
                    importType: ImportKind.imported,
                    classroom: meeting.classroom,
                    teacher: teacher,
                    testTime: testTime,
                    testLocation: testLocation,
                    info: info
                ))
            }
        }
        return result
    }

    // MARK: - NJU 选课 page

    /// `CourseParserXK.parseCourseName()` — the current-term label.
    static func selectionTableName(fromHTML html: String) -> String? {
        let document = LightHTML.parse(html)
        guard let element = document.root.descendants(withClass: "currentTerm").first else { return nil }
        let value = clean(element.plainText)
        return value.isEmpty ? nil : value
    }

    /// `CourseParserXK.parseCourse(tableId:)` — the column order is discovered
    /// from the header row, exactly like the original.
    static func parseSelectionCourses(fromHTML html: String) -> [Course] {
        let document = LightHTML.parse(html)
        let heads = document.root.descendants(withClass: "course-head")
        guard heads.count > 1 else { return [] }
        let headerRow = heads[1].allElements.first { $0.tag == "tr" } ?? heads[1]
        let headerCells = directCells(of: headerRow)

        var infoIndex = 3
        var nameIndex = 1
        var teacherIndex = 2
        var remarkIndex = 6
        for (index, cell) in headerCells.enumerated() {
            let text = cell.plainText
            if text.contains("时间地点") { infoIndex = index }
            else if text.contains("课程名") { nameIndex = index }
            else if text.contains("教师") { teacherIndex = index }
            else if text.contains("备注") { remarkIndex = index }
        }

        let bodies = document.root.descendants(withClass: "course-body")
        guard bodies.count > 1 else { return [] }
        let body = bodies[1]
        // Rows can sit directly under the body or inside a tbody.
        let rows = directRows(of: body)
            + body.children.filter { $0.tag == "tbody" }.flatMap { directRows(of: $0) }
        var result: [Course] = []

        for row in uniqueRows(rows) {
            if row.hasClass("wdbm-course-tr") { continue }
            let cells = directCells(of: row)
            guard cells.indices.contains(max(infoIndex, max(nameIndex, teacherIndex))) else { continue }

            let courseName = clean(cells[nameIndex].trimmedText)
            guard !courseName.isEmpty else { continue }
            let teacher = clean(cells[teacherIndex].trimmedText)
            let remark = remarkIndex < cells.count ? clean(cells[remarkIndex].trimmedText) : ""
            let infoCell = cells[infoIndex]
            // Each meeting is one child element; when the page puts them all in
            // one text node, fall back to its newlines.
            var infoTexts = infoCell.children
                .filter { !clean($0.trimmedText).isEmpty }
                .map(\.trimmedText)
            if infoTexts.isEmpty {
                infoTexts = infoCell.trimmedText.components(separatedBy: "\n")
            }

            for text in infoTexts {
                if clean(text).isEmpty { continue }
                if clean(text) == "自由地点" { continue }
                guard let meeting = MeetingParser.parse(text) else { continue }
                result.append(Course(
                    tableId: 0,
                    name: courseName,
                    weeks: meeting.weeks,
                    weekTime: meeting.weekday,
                    startTime: meeting.startSlot,
                    timeCount: meeting.timeCount,
                    importType: ImportKind.imported,
                    classroom: meeting.classroom,
                    teacher: teacher,
                    info: remark
                ))
            }
        }
        return result
    }

    // MARK: - Shared helpers

    /// Direct `td` children of a row. `LightHTML` keeps a flat child list, so
    /// nested tables do not leak cells into the parent row.
    private static func directCells(of node: LightHTML.Node, tag: String = "td") -> [LightHTML.Node] {
        node.children.filter { $0.tag == tag }
    }

    private static func directRows(of node: LightHTML.Node) -> [LightHTML.Node] {
        node.children.filter { $0.tag == "tr" }
    }

    private static func uniqueRows(_ rows: [LightHTML.Node]) -> [LightHTML.Node] {
        var seen: [ObjectIdentifier] = []
        var result: [LightHTML.Node] = []
        for row in rows where !seen.contains(ObjectIdentifier(row)) {
            seen.append(ObjectIdentifier(row))
            result.append(row)
        }
        return result
    }

    private static func splitMeetings(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\u{FFFD}", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{FFFD}", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The string reader shared by both page layouts. This is a straight port of the
/// Flutter helpers `_getIntWeek`, `getWeekSeriesString`, `_getWeekSeries`,
/// `_getSingleWeekSeries` and `_getDoubleWeekSeries`.
nonisolated enum MeetingParser {
    struct Meeting: Equatable {
        var weekday: Int
        var startSlot: Int
        var timeCount: Int
        var weeks: [Int]
        var classroom: String
    }

    private static let weekdayCharacters: [Character: Int] = [
        "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "日": 7, "天": 7
    ]

    private static let slotRangePattern = try? NSRegularExpression(pattern: "第?(\\d{1,2})-(\\d{1,2})节")
    private static let slotSinglePattern = try? NSRegularExpression(pattern: "第(\\d{1,2})节")
    // `1-16周`, `1-16周(单)`, `1-16周单周` and `第1-16周` all appear in real pages.
    private static let weekRangePattern = try? NSRegularExpression(
        pattern: "^第?(\\d{1,2})\\s*-\\s*(\\d{1,2})\\s*周?(?:\\(?[单双]\\)?周?)?$"
    )
    private static let weekSinglePattern = try? NSRegularExpression(pattern: "^第?(\\d{1,2})周$")
    private static let weekFromPattern = try? NSRegularExpression(pattern: "从第?(\\d{1,2})周开始")
    private static let weekListPattern = try? NSRegularExpression(pattern: "(\\d{1,2})-(\\d{1,2})周|(?<![\\d-])(\\d{1,2})周")

    /// Returns `nil` for lines that carry no meeting (a stray header, a note).
    static func parse(_ rawLine: String, defaultWeekStart: Int = 1, defaultWeekEnd: Int = SchoolDefaults.defaultWeekCount) -> Meeting? {
        let line = rawLine
            .replacingOccurrences(of: "\u{FFFD}", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\u{3000}" }).map(String.init)
        guard !tokens.isEmpty else { return nil }

        // "自由时间 2-17周 详见主页通知" — the Flutter app kept these as free-time
        // courses with no weekday so they could be listed separately.
        if line.contains("自由时间") {
            let weeks = parseWeeks(line, defaultWeekStart: defaultWeekStart, defaultWeekEnd: defaultWeekEnd)
            return Meeting(
                weekday: 0,
                startSlot: 0,
                timeCount: 0,
                weeks: weeks,
                classroom: tokens.last ?? "自由地点"
            )
        }

        guard let weekday = weekday(in: line), weekday > 0 else { return nil }

        let slots = slotRange(in: line)
        // A line without a slot range is a note, not a meeting. The Flutter
        // parser skipped those too (`catch { continue; }`).
        guard let slots else { return nil }

        let weeks = parseWeeks(line, defaultWeekStart: defaultWeekStart, defaultWeekEnd: defaultWeekEnd)
        // The room follows the week specification: "周一 第1-2节 1-16周 仙Ⅱ-304".
        // Slicing right after the slot range would keep the week text, which is
        // how the Flutter parser ended up storing "5-16周  逸B-410" as a room.
        var classroom = tokens.last ?? ""
        if let weekEnd = lastWeekTokenEnd(in: line) {
            classroom = String(line[weekEnd...]).trimmingCharacters(in: .whitespaces)
        } else if let matched = slots.matched {
            classroom = String(line[matched.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        classroom = classroom
            .replacingOccurrences(of: "单周", with: "")
            .replacingOccurrences(of: "双周", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Meeting(
            weekday: weekday,
            startSlot: slots.start,
            timeCount: max(0, slots.end - slots.start),
            weeks: weeks,
            classroom: classroom
        )
    }

    static func weekday(in line: String) -> Int? {
        // The original read the first two characters ("周三"), so honour that
        // before falling back to any weekday character in the line.
        let characters = Array(line)
        if characters.count >= 2, characters[0] == "周" {
            if let value = weekdayCharacters[characters[1]] { return value }
        }
        if characters.count >= 3, characters[0] == "星", characters[1] == "期" {
            if let value = weekdayCharacters[characters[2]] { return value }
        }
        // Selected-course pages write "星期三" or "周三 5-6节".
        for (index, character) in characters.enumerated() where index < 8 {
            if let value = weekdayCharacters[character] {
                let previous = index > 0 ? characters[index - 1] : nil
                if previous == "周" || previous == "期" { return value }
            }
        }
        return nil
    }

    static func slotRange(in line: String) -> (start: Int, end: Int, matched: Range<String.Index>?)? {
        if let regex = slotRangePattern {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = regex.firstMatch(in: line, range: range),
               let start = intValue(match, 1, in: line),
               let end = intValue(match, 2, in: line),
               end >= start {
                return (start, end, Range(match.range, in: line))
            }
        }
        if let regex = slotSinglePattern {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = regex.firstMatch(in: line, range: range),
               let start = intValue(match, 1, in: line) {
                return (start, start, Range(match.range, in: line))
            }
        }
        return nil
    }

    /// `getWeekSeriesString`: explicit week tokens first, then the 单周/双周
    /// fallback that the 教务 page relies on when it prints no range at all.
    static func parseWeeks(
        _ line: String,
        defaultWeekStart: Int = 1,
        defaultWeekEnd: Int = SchoolDefaults.defaultWeekCount
    ) -> [Int] {
        let tokens = line
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: " ", with: "\u{1F}")
            .split(separator: "\u{1F}")
            .map(String.init)

        var weeks: [Int] = []
        for token in tokens {
            for piece in token.split(separator: ",").map(String.init) {
                // A bare 单周 / 双周 qualifier carries no range of its own; the
                // range token next to it already applied the qualifier.
                if piece == "单周" || piece == "双周" || piece == "单" || piece == "双" { continue }
                // The qualifier can be inside the token ("1-16周单周") or a
                // separate token on the same line ("1-16周 单周") depending on
                // the campus page, so fall back to the whole line.
                let scope = piece.contains("单") || piece.contains("双") ? piece : line
                let isSingle = scope.contains("单")
                let isDouble = scope.contains("双")
                if let regex = weekRangePattern {
                    let range = NSRange(piece.startIndex..<piece.endIndex, in: piece)
                    if let match = regex.firstMatch(in: piece, range: range),
                       let start = intValue(match, 1, in: piece),
                       let end = intValue(match, 2, in: piece) {
                        if isSingle {
                            weeks += WeekSeries.single(from: start, to: end)
                        } else if isDouble {
                            weeks += WeekSeries.double(from: start, to: end)
                        } else {
                            weeks += WeekSeries.full(from: start, to: end)
                        }
                        continue
                    }
                }
                if let regex = weekFromPattern {
                    let range = NSRange(piece.startIndex..<piece.endIndex, in: piece)
                    if let match = regex.firstMatch(in: piece, range: range),
                       let start = intValue(match, 1, in: piece) {
                        if isSingle {
                            weeks += WeekSeries.single(from: start, to: defaultWeekEnd)
                        } else if isDouble {
                            weeks += WeekSeries.double(from: start, to: defaultWeekEnd)
                        } else {
                            weeks += WeekSeries.full(from: start, to: defaultWeekEnd)
                        }
                        continue
                    }
                }
                if let regex = weekSinglePattern {
                    let range = NSRange(piece.startIndex..<piece.endIndex, in: piece)
                    if let match = regex.firstMatch(in: piece, range: range),
                       let value = intValue(match, 1, in: piece) {
                        weeks.append(value)
                    }
                }
            }
        }

        if weeks.isEmpty {
            // Some lines only say "周二 第3-4节 单周 逸B-101".
            if line.contains("单周") {
                weeks = WeekSeries.single(from: defaultWeekStart, to: defaultWeekEnd)
            } else if line.contains("双周") {
                weeks = WeekSeries.double(from: defaultWeekStart, to: defaultWeekEnd)
            } else {
                weeks = WeekSeries.full(from: defaultWeekStart, to: defaultWeekEnd)
            }
        }
        return Array(Set(weeks)).sorted()
    }

    /// The 选课 page uses `2-4节 14-18周(双)`, which the 教务 patterns miss.
    static func parseWeeksWithParentheses(
        _ line: String,
        defaultWeekStart: Int = 1,
        defaultWeekEnd: Int = SchoolDefaults.defaultWeekCount
    ) -> [Int] {
        guard let regex = weekListPattern else {
            return parseWeeks(line, defaultWeekStart: defaultWeekStart, defaultWeekEnd: defaultWeekEnd)
        }
        let isSingle = line.contains("(单)") || line.contains("单周")
        let isDouble = line.contains("(双)") || line.contains("双周")
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        var weeks: [Int] = []
        for match in regex.matches(in: line, range: range) {
            if let start = intValue(match, 1, in: line), let end = intValue(match, 2, in: line) {
                if isSingle {
                    weeks += WeekSeries.single(from: start, to: end)
                } else if isDouble {
                    weeks += WeekSeries.double(from: start, to: end)
                } else {
                    weeks += WeekSeries.full(from: start, to: end)
                }
            } else if let single = intValue(match, 3, in: line) {
                weeks.append(single)
            }
        }
        if weeks.isEmpty {
            return parseWeeks(line, defaultWeekStart: defaultWeekStart, defaultWeekEnd: defaultWeekEnd)
        }
        return Array(Set(weeks)).sorted()
    }

    private static let weekTokenPatterns = [
        try? NSRegularExpression(pattern: "\\d{1,2}\\s*-\\s*\\d{1,2}\\s*周"),
        try? NSRegularExpression(pattern: "从第?\\d{1,2}\\s*周开始"),
        try? NSRegularExpression(pattern: "第?\\d{1,2}\\s*周")
    ]

    /// End offset of the last week token in a meeting line, so whatever follows
    /// it is the room.
    private static func lastWeekTokenEnd(in line: String) -> String.Index? {
        var end: String.Index?
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        for case let regex? in weekTokenPatterns {
            for match in regex.matches(in: line, range: range) {
                guard let candidate = Range(match.range, in: line) else { continue }
                if let current = end {
                    if candidate.upperBound > current { end = candidate.upperBound }
                } else {
                    end = candidate.upperBound
                }
            }
        }
        return end
    }

    private static func intValue(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> Int? {
        guard index < match.numberOfRanges,
              let range = Range(match.range(at: index), in: text) else { return nil }
        return Int(text[range])
    }
}
