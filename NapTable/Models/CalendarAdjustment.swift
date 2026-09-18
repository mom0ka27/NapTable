import Foundation

// MARK: - Calendar adjustment (调休)

/// 一天的校历调整。
///
/// 课表本身只有「星期几 + 第几周」，表达不了国务院每年单独公布的调休：
/// 「10 月 11 日（周六）上 10 月 9 日（周四）的课」。这张表按**日期**覆盖课表：
/// `.off` 那天不上课，`.swap` 那天改上 `source` 那一天的课。
///
/// 数据由服务端按学期下发（`ServiceTermConfiguration.adjustments`），导入课表时随
/// 学期配置一起存进 `CourseTable.calendarAdjustments`，不需要用户自己维护。
nonisolated struct CalendarAdjustment: Codable, Equatable, Hashable, Identifiable {
    enum Kind: String, Codable, Equatable, Hashable, Sendable {
        /// 放假：这一天不上课。
        case off
        /// 调课：这一天改上 `source` 那一天的课。
        case swap
    }

    /// 被调整的那一天，`yyyy-MM-dd`。
    var date: String
    var kind: Kind
    /// `.swap` 时「上这一天的课」，同样是 `yyyy-MM-dd`；`.off` 不用。
    var source: String?
    /// 给用户看的说明，例如「国庆节」。留空时由 `CalendarAdjustmentResolver` 兜底生成。
    var note: String

    var id: String { date }

    init(date: String, kind: Kind, source: String? = nil, note: String = "") {
        self.date = date
        self.kind = kind
        self.source = source?.trimmedCalendarDate
        self.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CodingKeys: String, CodingKey { case date, kind, source, note }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            date: try values.decode(String.self, forKey: .date),
            // 未知类型按「放假」处理：宁可少显示一天课，也不要显示错的课。
            kind: (try? values.decode(Kind.self, forKey: .kind)) ?? .off,
            source: try values.decodeIfPresent(String.self, forKey: .source),
            note: try values.decodeIfPresent(String.self, forKey: .note) ?? ""
        )
    }
}

/// 一条调整在具体学期里的落点：`source` 已经换算成教学周和星期几，渲染层直接用。
public nonisolated struct ResolvedCalendarAdjustment: Codable, Equatable, Hashable, Sendable, Identifiable {
    let date: String
    let kind: CalendarAdjustment.Kind
    let sourceDate: String?
    /// `.swap` 时要渲染的教学周；学期之外解析不出来就是 `nil`（当作没课）。
    let sourceWeek: Int?
    /// `.swap` 时要渲染的星期几，1 = 周一。
    let sourceDay: Int?
    /// 服务端给的说明，可能为空。
    let note: String
    /// 日历格子右上角的一个字：放假「休」，调课「班」。
    let badge: String
    /// 一行说明：「国庆节放假」「上 10.9 周四的课」。
    let detail: String

    public var id: String { date }

    /// 这一天到底还有没有课要画。
    var suppressesCourses: Bool { kind == .off || sourceDay == nil || sourceWeek == nil }
}

/// 把服务端下发的调整表换算到某个学期的教学周上。
nonisolated enum CalendarAdjustmentResolver {
    /// `日期 -> 调整`。日期重复时后面的覆盖前面的，和服务端列表顺序一致。
    static func index(
        _ adjustments: [CalendarAdjustment],
        semesterStartMonday: String
    ) -> [String: ResolvedCalendarAdjustment] {
        guard !adjustments.isEmpty else { return [:] }
        let anchor = WeekCalculator.parseDay(semesterStartMonday).map { WeekCalculator.monday(of: $0) }
        var result: [String: ResolvedCalendarAdjustment] = [:]
        for item in adjustments {
            guard let date = WeekCalculator.parseDay(item.date) else { continue }
            var sourceDate: String?
            var sourceWeek: Int?
            var sourceDay: Int?
            if item.kind == .swap, let raw = item.source, let source = WeekCalculator.parseDay(raw) {
                sourceDate = WeekCalculator.format(source)
                sourceDay = WeekCalculator.weekday(source)
                sourceWeek = anchor.map { week(of: source, anchor: $0) }
            }
            let key = WeekCalculator.format(date)
            result[key] = ResolvedCalendarAdjustment(
                date: key,
                kind: item.kind,
                sourceDate: sourceDate,
                sourceWeek: sourceWeek,
                sourceDay: sourceDay,
                note: item.note,
                badge: item.kind == .off ? "休" : "班",
                detail: detail(for: item, sourceDate: sourceDate)
            )
        }
        return result
    }

    /// 这一周里的调整，按日期排序，用于课表顶部那条提示。
    static func inWeek(
        _ index: [String: ResolvedCalendarAdjustment],
        dates: [String]
    ) -> [ResolvedCalendarAdjustment] {
        dates.compactMap { index[$0] }
    }

    private static func week(of date: Date, anchor: Date) -> Int {
        let monday = WeekCalculator.monday(of: date)
        let delta = WeekCalculator.calendar.dateComponents([.day], from: anchor, to: monday).day ?? 0
        return Int(floor(Double(delta) / 7.0)) + 1
    }

    private static func detail(for item: CalendarAdjustment, sourceDate: String?) -> String {
        if !item.note.isEmpty { return item.note }
        switch item.kind {
        case .off:
            return "放假，不上课"
        case .swap:
            guard let sourceDate, let date = WeekCalculator.parseDay(sourceDate) else { return "调课" }
            return "上 \(WeekCalculator.monthDayShort(date)) \(WeekCalculator.weekdayName(WeekCalculator.weekday(date)))的课"
        }
    }
}

private extension String {
    /// 空串和纯空白都当成「没填」，服务端和手写 JSON 都可能出现。
    var trimmedCalendarDate: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
