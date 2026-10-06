import SwiftUI

/// 分享图使用独立的排版尺寸，不受屏幕宽度和课表显示密度影响。
struct ScheduleShareImageLayout {
    let isDayView: Bool
    let slotCount: Int
    /// 表格风格的周视图不留面板内边距，见 `NativeScheduleView.stylePanelPadding`。
    var flushPanel = false

    var width: CGFloat { isDayView ? 360 : 560 }
    var inset: CGFloat { 24 }
    var headerHeight: CGFloat { 76 }
    var footerHeight: CGFloat { 56 }
    var dateHeaderHeight: CGFloat { isDayView ? 0 : NativeScheduleDayColumn.dateHeaderHeight }
    /// 周视图和屏幕上一样套在一块面板里，这是面板的内边距；日视图屏幕上没有面板。
    var panelPadding: CGFloat { isDayView || flushPanel ? 0 : NativeScheduleView.panelPadding }
    /// 日视图卡片固定用标准字号下的高度，不随系统字号变。
    var timelineCardHeight: CGFloat { NativeScheduleDayTimeline.standardCardHeight }

    var rowHeight: CGFloat {
        // 3:5 的修长画布；节次较多时继续向下延伸，保证每行可读。
        let available = width * 5 / 3 - inset * 2 - headerHeight - footerHeight - dateHeaderHeight - panelPadding * 2
        let gaps = CGFloat(max(0, slotCount - 1)) * NativeScheduleDayColumn.slotGap
        return max(isDayView ? 44 : 46, (available - gaps) / CGFloat(max(1, slotCount)))
    }

    func columnWidth(dayCount: Int, axisWidth: CGFloat, gap: CGFloat) -> CGFloat {
        // HStack 中包含节次轴，因此 n 天对应 n 个间隔。
        (width - inset * 2 - panelPadding * 2 - axisWidth - CGFloat(dayCount) * gap) / CGFloat(max(1, dayCount))
    }
}

struct ScheduleShareImage<Grid: View>: View {
    let layout: ScheduleShareImageLayout
    let title: String
    let subtitle: String
    let week: Int
    @ViewBuilder let grid: () -> Grid

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.system(size: layout.isDayView ? 21 : 24, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("第 \(week) 周")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.themeText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.themeTint(0.09), in: Capsule())
                    .fixedSize()
            }
            .frame(height: layout.headerHeight, alignment: .top)

            grid()

            HStack(spacing: 9) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppBrand.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(AppBrand.subtitle)
                        .font(.system(size: 9, weight: .medium))
                }
                Spacer()
                Text(layout.isDayView ? "日课表" : "周课表")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(height: layout.footerHeight, alignment: .bottom)
        }
        .padding(layout.inset)
        .frame(width: layout.width)
        .background(.scheduleCanvas)
        .environment(\.scheduleHasBackgroundImage, false)
        // 分享出去的是一张静态课表：不标今天和现在，日视图的课不因为上完而变灰。
        .environment(\.scheduleStaticRendering, true)
        .environment(\.dynamicTypeSize, .medium)
    }
}
