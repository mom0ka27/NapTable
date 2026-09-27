import AppIntents
import SwiftUI
import WidgetKit

/// 长按小组件 →「编辑小组件」里的选项。每个小组件各存各的，所以同一种小组件
/// 放两个也可以一个接着看下一次课、一个只看今天。
struct ScheduleWidgetConfiguration: Sendable {
    var afterClass: ScheduleWidgetAfterClassStyle = .nextCourseDay
    /// 小号「临近课程」显示几节课。
    var upcomingCourseCount = 1
    /// 大号今日课表和两日课表的课怎么排。
    var layout: ScheduleWidgetLayoutStyle = .timeline
}

/// 大号上的课怎么排。中号、小号放不下时间线，一律是列表。
enum ScheduleWidgetLayoutStyle: String, Sendable {
    /// 左边一列起止时间，卡片和课间按时长分高度，把组件的高度用满。
    case timeline
    /// 一门课一张卡片，按顺序往下排。
    case list
}

enum LayoutOption: String, AppEnum {
    case timeline
    case list

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "显示方式"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .timeline: "时间线",
        .list: "列表",
    ]

    var style: ScheduleWidgetLayoutStyle {
        switch self {
        case .timeline: return .timeline
        case .list: return .list
        }
    }
}

enum AfterClassOption: String, AppEnum {
    case nextCourseDay
    /// rawValue 沿用旧的「不显示其他内容」，原来选它的小组件不用重新设置；
    /// 旧的「显示明日课程」「显示最近的节假日」解不出来，落回默认的下一次课。
    case todayOnly = "none"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "今日课程结束后"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .nextCourseDay: "接着显示下一次课",
        .todayOnly: "只看今天",
    ]

    var style: ScheduleWidgetAfterClassStyle {
        switch self {
        case .nextCourseDay: return .nextCourseDay
        case .todayOnly: return .todayOnly
        }
    }
}

enum UpcomingCourseCountOption: Int, AppEnum {
    case one = 1
    case two = 2

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "显示课程数"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .one: "仅当前一节",
        .two: "当前与下一节",
    ]
}

/// 放假当天祝福上方的彩炮按钮。记下按的时间，系统随即刷新小组件，这一刷看到刚按过就放一次烟花，
/// 几秒后的下一条时间线再收起来（见 `ScheduleTimeline.make`）。
struct CelebrateHolidayIntent: AppIntent {
    static let title: LocalizedStringResource = "放礼花"
    static let isDiscoverable = false

    static let firedAtKey = "naptable.holidayFireworksFiredAt"
    static let previousFiredAtKey = "naptable.holidayFireworksPreviousFiredAt"

    func perform() async throws -> some IntentResult {
        let defaults = UserDefaults(suiteName: NextWidgetConfiguration.appGroup)
        defaults?.set(defaults?.object(forKey: Self.firedAtKey), forKey: Self.previousFiredAtKey)
        defaults?.set(Date(), forKey: Self.firedAtKey)
        return .result()
    }

    /// 上上次和上一次按的时间，给烟花层当身份用（见 `ScheduleEntry.fireworksRound`）。没按过是 0。
    static func rounds() -> (previous: Double, latest: Double) {
        let defaults = UserDefaults(suiteName: NextWidgetConfiguration.appGroup)
        func stamp(_ key: String) -> Double {
            (defaults?.object(forKey: key) as? Date)?.timeIntervalSince1970 ?? 0
        }
        return (stamp(previousFiredAtKey), stamp(firedAtKey))
    }

    /// 按下后多久之内刷新出来的时间线算「刚按过」。
    static func justFired(now: Date) -> Bool {
        guard let firedAt = UserDefaults(suiteName: NextWidgetConfiguration.appGroup)?.object(forKey: firedAtKey) as? Date else {
            return false
        }
        let elapsed = now.timeIntervalSince(firedAt)
        return elapsed >= 0 && elapsed < 5
    }
}

protocol ScheduleWidgetIntent: WidgetConfigurationIntent {
    var configuration: ScheduleWidgetConfiguration { get }
}

struct TodayScheduleWidgetIntent: ScheduleWidgetIntent {
    static let title: LocalizedStringResource = "今日课表"
    static let description = IntentDescription("设置今日课程结束后小组件显示的内容，以及大尺寸组件的显示方式。")

    @Parameter(title: "今日课程结束后", default: .nextCourseDay)
    var afterClass: AfterClassOption

    @Parameter(title: "显示方式", default: .timeline)
    var layout: LayoutOption

    /// 中号只放得下两门课，没有时间线可选。
    static var parameterSummary: some ParameterSummary {
        When(widgetFamily: .equalTo, .systemLarge) {
            Summary {
                \.$afterClass
                \.$layout
            }
        } otherwise: {
            Summary {
                \.$afterClass
            }
        }
    }

    var configuration: ScheduleWidgetConfiguration {
        ScheduleWidgetConfiguration(afterClass: afterClass.style, layout: layout.style)
    }
}

struct UpcomingScheduleWidgetIntent: ScheduleWidgetIntent {
    static let title: LocalizedStringResource = "临近课程"
    static let description = IntentDescription("设置今日课程结束后显示的内容，以及小尺寸组件显示的课程数。")

    @Parameter(title: "今日课程结束后", default: .nextCourseDay)
    var afterClass: AfterClassOption

    @Parameter(title: "显示课程数", default: .one)
    var courseCount: UpcomingCourseCountOption

    /// 中号本来就是「当前 / 接下来」两栏，锁屏也只放得下一节，节数只在小号上给选。
    static var parameterSummary: some ParameterSummary {
        When(widgetFamily: .equalTo, .systemSmall) {
            Summary {
                \.$afterClass
                \.$courseCount
            }
        } otherwise: {
            Summary {
                \.$afterClass
            }
        }
    }

    var configuration: ScheduleWidgetConfiguration {
        ScheduleWidgetConfiguration(afterClass: afterClass.style, upcomingCourseCount: courseCount.rawValue)
    }
}

/// 两日课表固定显示今天和下一个有课日，只能选显示方式。默认是列表：它原来就是列表，
/// 已经放好的两日课表不会因为更新变了样。
struct TwoDayScheduleWidgetIntent: ScheduleWidgetIntent {
    static let title: LocalizedStringResource = "两日课表"
    static let description = IntentDescription("并排显示今天和下一个有课日的课程，可以选择时间线或列表。")

    @Parameter(title: "显示方式", default: .list)
    var layout: LayoutOption

    var configuration: ScheduleWidgetConfiguration { ScheduleWidgetConfiguration(layout: layout.style) }
}

/// 三个小组件共用同一条时间线，只是各自带上自己的配置。
struct ScheduleIntentTimelineProvider<Configuration: ScheduleWidgetIntent>: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ScheduleEntry { .placeholder }

    func snapshot(for configuration: Configuration, in context: Context) async -> ScheduleEntry {
        var entry = ScheduleEntry.placeholder
        entry.configuration = configuration.configuration
        return entry
    }

    func timeline(for configuration: Configuration, in context: Context) async -> Timeline<ScheduleEntry> {
        let timeline = ScheduleTimeline.make(now: .now)
        return Timeline(
            entries: timeline.entries.map { entry in
                var entry = entry
                entry.configuration = configuration.configuration
                return entry
            },
            policy: timeline.policy
        )
    }
}

private struct ScheduleWidgetConfigurationEnvironmentKey: EnvironmentKey {
    static let defaultValue = ScheduleWidgetConfiguration()
}

private struct ScheduleWidgetCelebratingEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var scheduleWidgetConfiguration: ScheduleWidgetConfiguration {
        get { self[ScheduleWidgetConfigurationEnvironmentKey.self] }
        set { self[ScheduleWidgetConfigurationEnvironmentKey.self] = newValue }
    }

    /// 刚按了彩炮，这一条时间线在放烟花。
    var scheduleWidgetCelebrating: Bool {
        get { self[ScheduleWidgetCelebratingEnvironmentKey.self] }
        set { self[ScheduleWidgetCelebratingEnvironmentKey.self] = newValue }
    }
}
