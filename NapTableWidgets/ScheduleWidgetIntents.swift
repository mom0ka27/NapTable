import AppIntents
import SwiftUI
import WidgetKit

/// 长按小组件 →「编辑小组件」里的选项。每个小组件各存各的，所以同一种小组件
/// 放两个也可以一个看明天、一个看假期。
struct ScheduleWidgetConfiguration: Sendable {
    /// `nil` 只出现在占位图里，此时沿用 App 里旧的全局设置。
    var afterClass: ScheduleWidgetAfterClassStyle?
    /// 小号「临近课程」显示几节课。
    var upcomingCourseCount = 1
    var twoDayStart: TwoDayStartOption = .today
}

enum AfterClassOption: String, AppEnum {
    case none
    case tomorrow
    case holiday
    case nextCourseDay

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "今日课程结束后"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .none: "不显示其他内容",
        .tomorrow: "显示明日课程",
        .holiday: "显示最近的节假日",
        .nextCourseDay: "显示下一个有课日",
    ]

    var style: ScheduleWidgetAfterClassStyle { ScheduleWidgetAfterClassStyle(rawValue: rawValue) ?? .tomorrow }
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

enum TwoDayStartOption: String, AppEnum {
    /// 固定今天和明天。
    case today
    /// 左边照旧是今天，右边是今天之后最近一个有课的日期（三周之内，没有就是明天）。
    /// rawValue 沿用旧名，已经放好的小组件不用重新设置。
    case nextCourseDay

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "显示日期"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .today: "今日与明日",
        .nextCourseDay: "今日与下一个有课日",
    ]
}

protocol ScheduleWidgetIntent: WidgetConfigurationIntent {
    var configuration: ScheduleWidgetConfiguration { get }
}

struct TodayScheduleWidgetIntent: ScheduleWidgetIntent {
    static let title: LocalizedStringResource = "今日课表"
    static let description = IntentDescription("设置今日课程结束后小组件显示的内容。")

    @Parameter(title: "今日课程结束后", default: .tomorrow)
    var afterClass: AfterClassOption

    var configuration: ScheduleWidgetConfiguration {
        ScheduleWidgetConfiguration(afterClass: afterClass.style)
    }
}

struct UpcomingScheduleWidgetIntent: ScheduleWidgetIntent {
    static let title: LocalizedStringResource = "临近课程"
    static let description = IntentDescription("设置今日课程结束后显示的内容，以及小尺寸组件显示的课程数。")

    @Parameter(title: "今日课程结束后", default: .tomorrow)
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

struct TwoDayScheduleWidgetIntent: ScheduleWidgetIntent {
    static let title: LocalizedStringResource = "两日课表"
    static let description = IntentDescription("设置两日课表显示的日期。")

    @Parameter(title: "显示日期", default: .today)
    var start: TwoDayStartOption

    var configuration: ScheduleWidgetConfiguration {
        ScheduleWidgetConfiguration(twoDayStart: start)
    }
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

extension EnvironmentValues {
    var scheduleWidgetConfiguration: ScheduleWidgetConfiguration {
        get { self[ScheduleWidgetConfigurationEnvironmentKey.self] }
        set { self[ScheduleWidgetConfigurationEnvironmentKey.self] = newValue }
    }
}
