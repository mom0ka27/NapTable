import Foundation

/// 小组件和实时活动画面里的「现在」。正式构建就是 `Date()`；只有预览画廊
/// （`scripts/widget-gallery.sh`，编译时带 `WIDGET_GALLERY`）和 Debug 构建里的 Xcode 预览
/// 能把它钉在某一刻，这样同一份课表可以出「上课前 / 上课中 / 放学后」、放假当天各个时刻的图。
///
/// 只给实时活动的视图、小组件的占位条目用。桌面小组件的视图不读这里：时间线一次排好一整天的条目，
/// 系统提前把每一条都画好，每条要按自己的 `entry.date` 画，所以从 `\.scheduleWidgetNow`
///（`ScheduleWidgetRoot` 放进环境）读；画廊钉时刻靠的是条目的日期。
/// 时间线什么时候刷新、提醒什么时候发，这些照旧看真实时间。
nonisolated enum WidgetClock {
    #if WIDGET_GALLERY || DEBUG
    nonisolated(unsafe) static var override: Date?
    static var now: Date { override ?? Date() }
    #else
    static var now: Date { Date() }
    #endif
}
