import Foundation

/// 小组件和实时活动画面里的「现在」。正式构建就是 `Date()`；只有预览画廊
/// （`scripts/widget-gallery.sh`，编译时带 `WIDGET_GALLERY`）和 Debug 构建里的 Xcode 预览
/// 能把它钉在某一刻，这样同一份课表可以出「上课前 / 上课中 / 放学后」、放假当天各个时刻的图。
///
/// 只给视图用。时间线什么时候刷新、提醒什么时候发，这些照旧看真实时间。
nonisolated enum WidgetClock {
    #if WIDGET_GALLERY || DEBUG
    nonisolated(unsafe) static var override: Date?
    static var now: Date { override ?? Date() }
    #else
    static var now: Date { Date() }
    #endif
}
