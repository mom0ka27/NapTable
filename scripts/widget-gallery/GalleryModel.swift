import Foundation
import SwiftUI
import WidgetKit

/// 一张预览图的全部设置。网页和批量脚本都发这个 JSON，缺的字段取默认值。
struct GalleryJob: Codable {
    /// `widget` 或 `activity`。
    var surface: String?
    var kind: String?
    var family: String?
    /// 实时活动的形态：lockScreen / watch / islandExpanded / islandCompact / islandMinimal。
    var activity: String?

    // 编辑小组件
    var afterClass: String?
    var courseCount: Int?
    /// 显示方式：timeline / list。不给就是这个小组件的默认（两日课表列表，今日课程大号时间线）。
    var layout: String?
    /// 画放烟花那一刻（按了放假祝福上的彩炮）。
    var celebrating: Bool?
    /// 画烟花动画第几秒（从按下算起）。给了就逐帧自己算，不靠 `celebrating` 的过渡。
    var fireworksTime: Double?

    // 全局设置（App 里的「课表与设备设置」）
    var theme: String?
    var customColor: String?
    var solid: Bool?
    var display: [String: Bool]?

    // 系统外观
    var scheme: String?
    var renderingMode: String?
    var tint: String?
    var device: String?
    var scale: Double?
    /// 垫在图下面的底色，默认透明。锁屏小组件是透明底白字，单独看图时用得上。
    var backdrop: String?

    // 场景
    var scenario: String?
    var date: String?
    var time: String?
    var state: String?
    var tableName: String?
    var sourceLabel: String?
    /// 直接给一份完整的 payload，覆盖预置课表。
    var payload: WidgetSchedulePayload?

    // 实时活动
    var persistent: Bool?
    var companion: Bool?
    /// 直接给实时活动这一刻的内容，不按课表推算。和真实系统渲染对照时用同一份。
    var activityState: ScheduleLiveActivityAttributes.ContentState?

    var isActivity: Bool { surface == "activity" }
}

// MARK: - 设备

struct GalleryDevice: Codable {
    let id: String
    let title: String
    let screen: CGSize
    let scale: CGFloat
    let small: CGSize
    let medium: CGSize
    let large: CGSize
    let circular: CGSize
    let rectangular: CGSize
    let inline: CGSize
    /// 锁屏实时活动和展开灵动岛的宽度。
    let activityWidth: CGFloat
    let hasIsland: Bool
    let cornerRadius: CGFloat
    /// 尺寸不在 Apple 公布的表里，按屏宽推算。
    let estimated: Bool

    func size(for family: WidgetFamily) -> CGSize {
        switch family {
        case .systemSmall: return small
        case .systemMedium: return medium
        case .systemLarge: return large
        case .accessoryCircular: return circular
        case .accessoryRectangular: return rectangular
        case .accessoryInline: return inline
        default: return medium
        }
    }

    // 尺寸来自 HIG「Widgets → Specifications」；18 系列的屏幕尺寸不在表里，按屏宽推算。
    static let all: [GalleryDevice] = [
        GalleryDevice(
            id: "se", title: "iPhone SE（375×667）", screen: CGSize(width: 375, height: 667), scale: 2,
            small: CGSize(width: 148, height: 148), medium: CGSize(width: 321, height: 148), large: CGSize(width: 321, height: 324),
            circular: CGSize(width: 68, height: 68), rectangular: CGSize(width: 153, height: 68), inline: CGSize(width: 225, height: 26),
            activityWidth: 353, hasIsland: false, cornerRadius: 20, estimated: false
        ),
        GalleryDevice(
            id: "standard", title: "标准屏 iPhone 16（393×852）", screen: CGSize(width: 393, height: 852), scale: 3,
            small: CGSize(width: 158, height: 158), medium: CGSize(width: 338, height: 158), large: CGSize(width: 338, height: 354),
            circular: CGSize(width: 72, height: 72), rectangular: CGSize(width: 160, height: 72), inline: CGSize(width: 234, height: 26),
            activityWidth: 371, hasIsland: true, cornerRadius: 22, estimated: false
        ),
        GalleryDevice(
            id: "pro", title: "iPhone 18 Pro（402×874）", screen: CGSize(width: 402, height: 874), scale: 3,
            small: CGSize(width: 162, height: 162), medium: CGSize(width: 346, height: 162), large: CGSize(width: 346, height: 362),
            circular: CGSize(width: 72, height: 72), rectangular: CGSize(width: 160, height: 72), inline: CGSize(width: 234, height: 26),
            activityWidth: 380, hasIsland: true, cornerRadius: 22, estimated: true
        ),
        GalleryDevice(
            id: "promax", title: "iPhone 18 Pro Max（440×956）", screen: CGSize(width: 440, height: 956), scale: 3,
            small: CGSize(width: 170, height: 170), medium: CGSize(width: 364, height: 170), large: CGSize(width: 364, height: 382),
            circular: CGSize(width: 76, height: 76), rectangular: CGSize(width: 172, height: 76), inline: CGSize(width: 257, height: 26),
            activityWidth: 418, hasIsland: true, cornerRadius: 23, estimated: true
        ),
    ]

    static func named(_ id: String?) -> GalleryDevice {
        all.first { $0.id == id } ?? all[2]
    }
}

// MARK: - 小组件目录

struct GalleryWidgetInfo: Codable {
    let kind: String
    let title: String
    let families: [String]
    /// 这个小组件「编辑小组件」里有的选项。今日课程的「显示课程数」只在小号上出现，「显示方式」只在大号上出现。
    let options: [String]
}

enum GalleryCatalog {
    static let widgets: [GalleryWidgetInfo] = [
        GalleryWidgetInfo(
            kind: "upcoming", title: "今日课程",
            families: ["systemSmall", "systemMedium", "systemLarge", "accessoryInline", "accessoryCircular", "accessoryRectangular"],
            options: ["afterClass", "courseCount", "layout"]
        ),
        GalleryWidgetInfo(kind: "twoday", title: "两日课表", families: ["systemLarge"], options: ["layout"]),
    ]

    static let activityParts = ["lockScreen", "islandExpanded", "islandCompact", "islandMinimal", "watch"]

    static func family(_ name: String?) -> WidgetFamily {
        switch name {
        case "systemSmall": return .systemSmall
        case "systemLarge": return .systemLarge
        case "accessoryInline": return .accessoryInline
        case "accessoryCircular": return .accessoryCircular
        case "accessoryRectangular": return .accessoryRectangular
        default: return .systemMedium
        }
    }
}

// MARK: - 课表场景

struct GalleryScenario {
    let id: String
    let title: String
    let detail: String
    /// 按星期（1 = 周一）排的课。
    var week: [Int: [WidgetCourse]]
    /// 按离「今天」的天数覆盖某一天的课。
    var overrides: [Int: [WidgetCourse]] = [:]
    /// 按离「今天」的天数写调休说明。
    var notes: [Int: String] = [:]
    /// 学期怎么放：默认 2026-08-31 起 20 周；也可以放在今天之外，看寒暑假和课表过期。
    var term: GalleryTerm = .standard
}

enum GalleryTerm {
    /// 第 1 周周一 `GalleryPayload.semesterStart`，20 周。
    case standard
    /// 学期（18 周）在这么多天前结束：寒暑假里、下学期开学日期不知道。
    case endedDaysAgo(Int)
    /// 学期（18 周）过这么多天开学：「距开学还有 N 天」。
    case startsIn(Int)
    /// 学期照常，但 App 五周前写的数据：今天不在里面，提示「打开 App 更新课表」。
    case stale
}

enum GalleryScenarios {
    private static let slots: [Int: (String, String)] = [
        1: ("08:00", "08:45"), 2: ("08:50", "09:35"), 3: ("10:00", "10:45"), 4: ("10:50", "11:35"),
        5: ("14:00", "14:45"), 6: ("14:50", "15:35"), 7: ("16:00", "16:45"), 8: ("16:50", "17:35"),
        9: ("19:00", "19:45"), 10: ("19:50", "20:35"),
    ]

    static func course(_ name: String, _ teacher: String, _ room: String, _ first: Int, _ last: Int, note: String? = nil) -> WidgetCourse {
        WidgetCourse(
            name: name, teacher: teacher, location: room, note: note, slotNote: "1-16周",
            startTime: slots[first]?.0, endTime: slots[last]?.1, startSlot: first, endSlot: last
        )
    }

    private static let normalWeek: [Int: [WidgetCourse]] = [
        1: [course("药物化学", "王老师", "教1-201", 1, 2), course("药剂学", "苏老师", "教2-305", 3, 4), course("药理学实验", "陈老师", "实验楼 B402", 5, 8)],
        2: [course("分析化学", "李老师", "教1-104", 1, 2), course("大学英语", "Emily", "外语楼 312", 5, 6)],
        3: [course("药理学", "赵老师", "教3-108", 3, 4), course("体育（羽毛球）", "周老师", "体育馆", 7, 8)],
        4: [course("药物分析", "孙老师", "教2-201", 1, 2), course("生物化学", "吴老师", "教1-301", 3, 4), course("形势与政策", "郑老师", "报告厅", 9, 10)],
        5: [course("天然药物化学", "钱老师", "教3-205", 1, 2), course("药事管理学", "冯老师", "教1-402", 5, 6)],
    ]

    private static let fullDay: [WidgetCourse] = (1...8).map { slot in
        let names = ["药物化学", "药剂学", "分析化学", "药理学", "生物化学", "药物分析", "大学英语", "医药数理统计"]
        return course(names[slot - 1], "老师\(slot)", "教1-\(200 + slot)", slot, slot)
    } + [course("形势与政策", "郑老师", "报告厅", 9, 10)]

    private static let longWeek: [Int: [WidgetCourse]] = normalWeek.mapValues { courses in
        courses.map { value in
            WidgetCourse(
                name: "\(value.displayName)（双语）与计算机辅助药物设计综合实践",
                teacher: "欧阳明远 / 司马婉清 / 慕容雪",
                location: "江宁校区第二教学楼 B 区 305 多媒体阶梯教室",
                note: nil, slotNote: value.slotNote,
                startTime: value.startTime, endTime: value.endTime, startSlot: value.startSlot, endSlot: value.endSlot
            )
        }
    }

    static let all: [GalleryScenario] = [
        GalleryScenario(id: "normal", title: "普通一周", detail: "工作日每天 2–3 门，周末没课", week: normalWeek),
        GalleryScenario(id: "full", title: "满课", detail: "每个工作日 9 门，看「后面还有 N 门课」", week: [1: fullDay, 2: fullDay, 3: fullDay, 4: fullDay, 5: fullDay]),
        GalleryScenario(id: "long", title: "超长文字", detail: "课名、教室、老师都很长，看截断", week: longWeek),
        GalleryScenario(id: "todayEmpty", title: "今天没课", detail: "普通一周，但今天空着", week: normalWeek, overrides: [0: []]),
        GalleryScenario(
            id: "sparse", title: "三天后才有课", detail: "今天起两天没课，第 3 天一门",
            week: [:], overrides: [3: [course("药物化学", "王老师", "教1-201", 3, 4)]]
        ),
        GalleryScenario(id: "none", title: "三周内没课", detail: "休息状态、假期倒计时", week: [:]),
        GalleryScenario(
            id: "adjustment", title: "调休上课日", detail: "今天补另一天的课，带调休说明",
            week: normalWeek, overrides: [0: normalWeek[4] ?? []], notes: [0: "上 10.9 周四的课"]
        ),
        GalleryScenario(
            id: "vacation", title: "放假（学期已结束）", detail: "学期三周前结束；日期选 1 月下旬看寒假、7 月下旬看暑假",
            week: normalWeek, term: .endedDaysAgo(21)
        ),
        GalleryScenario(
            id: "beforeTerm", title: "放假（快开学）", detail: "9 天后开学，显示「距开学还有 9 天」",
            week: normalWeek, term: .startsIn(9)
        ),
        GalleryScenario(
            id: "stale", title: "课表过期", detail: "五周没打开 App，今天不在数据里",
            week: normalWeek, term: .stale
        ),
    ]

    static func named(_ id: String?) -> GalleryScenario {
        all.first { $0.id == id } ?? all[0]
    }
}

// MARK: - 时间

enum GalleryTime {
    static let zone = TimeZone(identifier: "Asia/Shanghai")!

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.locale = Locale(identifier: "zh_CN")
        return calendar
    }

    /// 快捷时刻，配合场景里的标准节次时间。
    static let presets: [(id: String, title: String, time: String)] = [
        ("beforeFirst", "第一节课前", "07:30"),
        ("inClass", "上课中", "08:20"),
        ("break", "课间", "09:45"),
        ("afternoon", "下午课前", "13:30"),
        ("afterLast", "放学后", "21:30"),
        ("lateNight", "零点前", "23:55"),
    ]

    static func instant(date: String?, time: String?) -> Date {
        let now = Date()
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = zone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let day = date.flatMap { $0.isEmpty ? nil : $0 } ?? WidgetSchedulePayload.dateString(now)
        let clock = time.flatMap { $0.isEmpty ? nil : $0 } ?? {
            let parts = calendar.dateComponents([.hour, .minute], from: now)
            return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        }()
        return formatter.date(from: "\(day) \(clock)") ?? now
    }

    static func date(_ day: String, time: String?) -> Date? {
        guard let time else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = zone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: "\(day) \(time.prefix(5))")
    }
}

// MARK: - payload

enum GalleryPayload {
    /// 第 1 周的周一，和 `ScheduleEntry.placeholder` 一致。
    static let semesterStart = "2026-08-31"
    static let weekdayLabels = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    /// 示例用的统一放假安排（2026 年国务院通知：中秋 9.25–9.27、国庆 10.1–10.7）。真机上
    /// App 从服务端 `/v1/calendar` 拿，这里写死一份，让画廊和真机一样：放假那天没课，
    /// 日期栏的节日按连休算。不在这里面的年份退回离线推算的法定假日，和没同步到时一样。
    static let sampleHolidays: [PublishedHoliday] =
        (25...27).map { PublishedHoliday(date: String(format: "2026-09-%02d", $0), name: "中秋节") }
        + (1...7).map { PublishedHoliday(date: String(format: "2026-10-%02d", $0), name: "国庆节") }

    /// 和 App 写进 App Group 的形状一样：今天、本周七天、之后的日子。App 带到学期结束，
    /// 画廊只带三周：「最近有课的一天」最多往后找三周，再多画出来也一样。
    static func make(job: GalleryJob, now: Date) -> WidgetSchedulePayload {
        let scenario = GalleryScenarios.named(job.scenario)
        // 下面按日期查节假日，要先换上放假安排。
        ChineseCalendarInfo.usePublishedHolidays(sampleHolidays)
        let calendar = GalleryTime.calendar
        let realToday = calendar.startOfDay(for: now)
        // 课表过期：数据是五周前写的，按那时的「今天」排。
        let staleShift: Int
        if case .stale = scenario.term { staleShift = -35 } else { staleShift = 0 }
        let today = calendar.date(byAdding: .day, value: staleShift, to: realToday)!
        let weekday = calendar.component(.weekday, from: today)
        let mondayOffset = weekday == 1 ? -6 : 2 - weekday
        let monday = calendar.date(byAdding: .day, value: mondayOffset, to: today)!
        let start = GalleryTime.instant(date: semesterStart, time: "00:00")

        func day(_ offsetFromToday: Int) -> WidgetDay {
            let date = calendar.date(byAdding: .day, value: offsetFromToday, to: today)!
            let weekdayValue = calendar.component(.weekday, from: date)
            let index = weekdayValue == 1 ? 7 : weekdayValue - 1
            let days = calendar.dateComponents([.day], from: start, to: date).day ?? 0
            let week = days >= 0 ? days / 7 + 1 : nil
            let dateString = WidgetSchedulePayload.dateString(date)
            // 和 App 一样：放假那天不出课，说明写「中秋节放假」（日期栏已经有节日名时会自己省掉）。
            // 场景自己写了说明的那天（调休上课日）照场景来。
            let holiday = scenario.notes[offsetFromToday] == nil
                ? ChineseCalendarInfo.info(forDate: dateString)?.holiday
                : nil
            return WidgetDay(
                day: index,
                label: weekdayLabels[index - 1],
                date: dateString,
                week: week,
                isToday: offsetFromToday == 0,
                courses: holiday != nil ? [] : scenario.overrides[offsetFromToday] ?? scenario.week[index] ?? [],
                note: holiday.map { "\($0)放假" } ?? scenario.notes[offsetFromToday]
            )
        }

        let firstOffset = calendar.dateComponents([.day], from: today, to: monday).day ?? 0
        let weekDays = (0..<7).map { day(firstOffset + $0) }
        let later = (firstOffset + 7..<firstOffset + 7 + 21).map(day)
        let term: (start: String, weeks: Int)
        switch scenario.term {
        case .standard, .stale:
            term = (semesterStart, 20)
        case .endedDaysAgo(let days):
            let end = calendar.date(byAdding: .day, value: -days, to: realToday)!
            term = (WidgetSchedulePayload.dateString(calendar.date(byAdding: .day, value: -(18 * 7 - 1), to: end)!), 18)
        case .startsIn(let days):
            term = (WidgetSchedulePayload.dateString(calendar.date(byAdding: .day, value: days, to: realToday)!), 18)
        }
        let name = job.tableName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = job.sourceLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        return WidgetSchedulePayload(
            title: name?.isEmpty == false ? name : nil,
            sourceLabel: source?.isEmpty == false ? source : nil,
            generatedAt: ISO8601DateFormatter().string(from: now),
            semester: "2026-2027-1",
            currentWeek: day(0).week,
            today: day(0),
            days: nil,
            weekDays: weekDays,
            nextWeekDays: later,
            holidays: sampleHolidays,
            termStart: term.start,
            termWeeks: term.weeks
        )
    }
}

// MARK: - 实时活动

enum GalleryActivity {
    struct Resolved {
        let state: ScheduleLiveActivityAttributes.ContentState
        let attributes: ScheduleLiveActivityAttributes
        let isStale: Bool
    }

    /// 按「现在」从今天的课里挑出活动这一刻的内容：正在上的那节，否则下一节；
    /// 今天都上完了就拿最后一节、标成过期，交给视图自己决定显示「已下课」还是「今日无课」。
    static func resolve(payload: WidgetSchedulePayload, job: GalleryJob, now: Date) -> Resolved {
        let day = payload.currentDay(now: now)
        let dateKey = day.date ?? WidgetSchedulePayload.dateString(now)
        let attributes = ScheduleLiveActivityAttributes(semester: payload.semester ?? "", dateKey: dateKey, week: day.week ?? 0)
        if let state = job.activityState {
            return Resolved(state: state, attributes: attributes, isStale: false)
        }
        let dated = day.courseList.compactMap { course -> (WidgetCourse, Date, Date)? in
            guard let start = GalleryTime.date(dateKey, time: course.startTime),
                  let end = GalleryTime.date(dateKey, time: course.endTime), end > start else { return nil }
            return (course, start, end)
        }.sorted { $0.1 < $1.1 }

        let current = dated.firstIndex { $0.1 <= now && now < $0.2 }
        let upcoming = dated.firstIndex { $0.1 > now }
        guard let index = current ?? upcoming else {
            // 今天没课或都上完了：给一节已经结束的课，让活动走收尾分支。
            let last = dated.last
            let end = last?.2 ?? now.addingTimeInterval(-60)
            let course = last?.0 ?? GalleryScenarios.course("今日课程", "", "", 1, 2)
            let state = makeState(course, start: last?.1 ?? end.addingTimeInterval(-2700), end: end, next: nil,
                                  inProgress: true, day: day, job: job, updatedAt: last?.1 ?? end)
            return Resolved(state: state, attributes: attributes, isStale: true)
        }
        let selected = dated[index]
        let inProgress = current != nil
        let previousEnd = index > 0 ? dated[index - 1].2 : nil
        let updatedAt = inProgress ? selected.1 : max(previousEnd ?? now.addingTimeInterval(-1800), now.addingTimeInterval(-3 * 3600))
        let next = dated.dropFirst(index + 1).first
        let state = makeState(selected.0, start: selected.1, end: selected.2, next: next,
                              inProgress: inProgress, day: day, job: job, updatedAt: min(updatedAt, now))
        return Resolved(state: state, attributes: attributes, isStale: false)
    }

    private static func period(_ course: WidgetCourse) -> String? {
        guard let first = course.startSlot, let last = course.endSlot else { return nil }
        return first == last ? "第 \(first) 节" : "第 \(first)-\(last) 节"
    }

    private static func makeState(
        _ course: WidgetCourse,
        start: Date,
        end: Date,
        next: (WidgetCourse, Date, Date)?,
        inProgress: Bool,
        day: WidgetDay,
        job: GalleryJob,
        updatedAt: Date
    ) -> ScheduleLiveActivityAttributes.ContentState {
        let wantsCompanion = job.companion ?? false
        let typedSource = job.sourceLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 合并卡片只在显示别人课表时出现，没填名字就借一个。
        let source = typedSource.isEmpty ? (wantsCompanion ? "小明" : nil) : typedSource
        let companion = wantsCompanion
            ? ScheduleLiveActivityAttributes.ContentState.Companion(
                phase: .inProgress, courseName: "大学物理", teacher: "何老师", location: "教4-101",
                periodLabel: "第 1-2 节", startDate: start.addingTimeInterval(-600), endDate: end.addingTimeInterval(-900)
            )
            : nil
        return ScheduleLiveActivityAttributes.ContentState(
            phase: inProgress ? .inProgress : .upcoming,
            courseName: course.displayName,
            teacher: course.normalizedTeacher ?? "",
            location: course.normalizedLocation ?? "",
            periodLabel: period(course),
            dateLabel: day.displayLabel,
            weekRangeLabel: course.slotNote,
            startDate: start,
            endDate: end,
            nextCourseName: next?.0.displayName,
            nextCoursePeriod: next.flatMap { period($0.0) },
            nextCourseDateLabel: day.displayLabel,
            nextCourseWeekRangeLabel: next?.0.slotNote,
            nextCourseTeacher: next?.0.normalizedTeacher,
            nextCourseLocation: next?.0.normalizedLocation,
            nextCourseStart: next?.1,
            nextCourseEnd: next?.2,
            sourceLabel: source,
            adjustmentNote: day.normalizedNote,
            updatedAt: updatedAt,
            companion: companion
        )
    }
}

// MARK: - 颜色

extension Color {
    init?(galleryHex hex: String?) {
        guard let value = GalleryRGB(hex: hex) else { return nil }
        self.init(red: value.red, green: value.green, blue: value.blue)
    }
}

struct GalleryRGB {
    let red: Double
    let green: Double
    let blue: Double

    init?(hex: String?) {
        guard var text = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = Int(text, radix: 16) else { return nil }
        red = Double((value >> 16) & 0xFF) / 255
        green = Double((value >> 8) & 0xFF) / 255
        blue = Double(value & 0xFF) / 255
    }
}
