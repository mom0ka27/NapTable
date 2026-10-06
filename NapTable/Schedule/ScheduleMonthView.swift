import SwiftUI

/// 月视图：课表界面的第三种视图，和「日」「周」共用同一个顶栏切换。
///
/// 月历与当天安排共用一块内容面板；点日期更新预览，点「当天安排」打开完整清单。
/// 农历和课程圆点作为辅助信息，教学周保留在当天安排的副标题里。
struct NativeScheduleMonthView: View {
    /// 所显示月份里的任意一天（`yyyy-MM-dd`）。
    @Binding var monthAnchor: String
    let contentRevision: Date?
    let selectedDate: String
    let todayDate: String?
    /// 日期 -> (教学周, 星期几)。来自课表日历，学期外的日期查不到。
    let dateIndex: [String: NativeScheduleMonthView.DaySlot]
    /// (星期几, 教学周) -> 当天课程。调休已经在里面解析过了。
    let blocks: (Int, Int) -> [NativeScheduleCourseBlock]
    /// 日期 -> 这一天的调休安排。
    let adjustments: [String: ResolvedCalendarAdjustment]
    let onSelect: (Day) -> Void
    let onOpenDetails: (Day) -> Void
    var isEditable = true
    let onCoursePreview: (Day, NativeScheduleCourseBlock) -> Void
    let onCourseSelected: (Day, NativeScheduleCourseBlock) -> Void
    let onMoveMonth: (Int) -> Void

    struct DaySlot: Equatable {
        let week: Int
        let day: Int
    }

    @State private var visibleMonth: String?
    @State private var dataCache = MonthDataCache()
    @State private var calendarGeneration = 0

    private struct WarmKey: Equatable {
        let year: Int
        let holidayRevision: Int
    }

    private var warmKey: WarmKey {
        WarmKey(year: Int((visibleMonth ?? monthAnchor).prefix(4)) ?? 2026,
                holidayRevision: ChineseCalendarInfo.holidayRevision)
    }

    /// 不发布变化的派生缓存，限量保存最近浏览的月份。
    private final class MonthDataCache {
        var contentRevision: Date?
        var holidayRevision = -1
        var generation = -1
        var days: [String: [Day]] = [:]
        var indexDates: [String: DaySlot] = [:]
        var indexToday = ""
        var months: [String] = []
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scheduleStyle) private var style
    @Environment(\.appThemeBrand) private var themeBrand
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.scheduleStaticRendering) private var staticRendering
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scheduleHasBackgroundImage) private var hasBackground
    @ScaledMetric(relativeTo: .body) private var previewRowHeight: CGFloat = 60
    @ScaledMetric(relativeTo: .headline) private var previewHeaderHeight: CGFloat = 50
    @ObservedObject private var themeSettings = NativeThemeSettings.shared

    private static let weekdayLabels = ["一", "二", "三", "四", "五", "六", "日"]

    var body: some View {
        GeometryReader { geometry in
            // 外层测量未被标签栏遮挡的高度；滚动视口和每页则延伸到屏幕底部。
            let pageHeight = geometry.size.height + geometry.safeAreaInsets.bottom
            let styledRows = style == .minimal ? 0 : weeks(buildDays(anchor: monthAnchor)).count
            let minimumHeight = style == .minimal ? 640 : minimumStyledPageHeight(rows: styledRows)
            if geometry.size.height < 480 || dynamicTypeSize.isAccessibilitySize
                || (style != .minimal && geometry.size.height < minimumHeight) {
                // 横屏和大字号下让整页自然滚动，完整安排始终能被访问。
                ScrollView(.vertical, showsIndicators: false) {
                    monthPage(buildDays(anchor: monthAnchor), height: max(minimumHeight, geometry.size.height))
                        .padding(.bottom, 16)
                }
                .modifier(ScheduleScrollTopFade())
            } else if #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) {
                monthScroller(contentHeight: geometry.size.height, pageHeight: pageHeight)
                    .onScrollPhaseChange { _, phase in
                        if phase == .idle { commitVisibleMonth() }
                    }
            } else {
                monthScroller(contentHeight: geometry.size.height, pageHeight: pageHeight)
                    .onChange(of: visibleMonth) { _, _ in commitVisibleMonth() }
            }
        }
        // 月历和周视图的面板共用页边距，切换视图时内容边缘保持不变。
        .padding(.horizontal, 16)
        .task(id: warmKey) {
            await ChineseCalendarInfo.prewarm(year: warmKey.year)
            guard !Task.isCancelled else { return }
            calendarGeneration &+= 1
        }
        .onAppear { visibleMonth = monthKey(monthAnchor) }
        .onChange(of: monthKey(monthAnchor)) { _, target in
            guard visibleMonth != target else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                visibleMonth = target
            }
        }
        .accessibilityAction(named: Text("上个月")) { onMoveMonth(-1) }
        .accessibilityAction(named: Text("下个月")) { onMoveMonth(1) }
    }

    private func monthScroller(contentHeight: CGFloat, pageHeight: CGFloat) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(pageMonths, id: \.self) { month in
                    monthPage(buildDays(anchor: month), height: contentHeight)
                        .frame(height: pageHeight, alignment: .top)
                        .id(month)
                }
            }
            .scrollTargetLayout()
        }
        .frame(height: pageHeight, alignment: .top)
        .ignoresSafeArea(.container, edges: .bottom)
        .scrollTargetBehavior(.paging)
        // 程序跳转与分页吸附共用页顶，向前返回时不再按另一条边对齐。
        .scrollPosition(id: $visibleMonth, anchor: .top)
        .modifier(ScheduleScrollTopFade(pageHeight: pageHeight))
    }

    private func commitVisibleMonth() {
        guard let visibleMonth, visibleMonth != monthKey(monthAnchor) else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { monthAnchor = visibleMonth }
    }

    private func monthKey(_ date: String) -> String {
        String(date.prefix(7)) + "-01"
    }

    private var pageMonths: [String] {
        let today = todayDate ?? monthKey(monthAnchor)
        if dataCache.indexDates == dateIndex, dataCache.indexToday == today,
           !dataCache.months.isEmpty { return dataCache.months }
        dataCache.indexDates = dateIndex
        dataCache.indexToday = today
        let calendar = ChineseCalendarInfo.gregorian
        // 围绕今天及学期范围扩展，翻页时不移动数据窗口或重置滚动位置。
        let dates = Array(dateIndex.keys) + [todayDate ?? monthAnchor]
        guard let first = dates.min(), let last = dates.max(),
              let start = ChineseCalendarInfo.date(fromDate: monthKey(first)),
              let end = ChineseCalendarInfo.date(fromDate: monthKey(last)) else { return [] }
        let distance = calendar.dateComponents([.month], from: start, to: end).month ?? 0
        let months = (-120...(max(0, distance) + 120)).compactMap { offset in
            calendar.date(byAdding: .month, value: offset, to: start)
                .map(ChineseCalendarInfo.dateString)
        }
        dataCache.months = months
        return months
    }

    // MARK: 月历

    @ViewBuilder
    private func monthPage(_ days: [Day], height: CGFloat) -> some View {
        if style == .minimal {
            minimalMonthPage(days, height: height)
        } else {
            styledMonthPage(days, height: height)
        }
    }

    private var styledMinimumRowHeight: CGFloat { style == .table ? 88 : 62 }

    private func styledGridOverhead(rows: Int) -> CGFloat {
        switch style {
        case .grid: 44 + CGFloat(max(0, rows - 1)) * 5
        case .paper: 78
        // 表格只有 28 高的星期表头，上下不留白，见 `styledMonthGrid`。
        case .table: 28
        default: 44
        }
    }

    private func minimumStyledPageHeight(rows: Int) -> CGFloat {
        CGFloat(rows) * styledMinimumRowHeight + styledGridOverhead(rows: rows)
            + previewHeaderHeight + previewRowHeight + 48
    }

    private func styledMonthPage(_ days: [Day], height: CGFloat) -> some View {
        let rows = max(1, weeks(days).count)
        let overhead = styledGridOverhead(rows: rows)
        let summaryOverhead = previewHeaderHeight + 48
        let room = height - CGFloat(rows) * styledMinimumRowHeight - overhead - summaryOverhead
        let count = room >= previewRowHeight * 2 + 8 ? 2 : 1
        let previewHeight = CGFloat(count) * previewRowHeight + CGFloat(count - 1) * 8
        let rowHeight = min(style == .table ? 104 : 78,
                            max(styledMinimumRowHeight, (height - overhead - summaryOverhead - previewHeight) / CGFloat(rows)))
        return VStack(spacing: 0) {
            styledMonthGrid(days, rowHeight: rowHeight)
            if let selected = selectedDay(in: days) {
                // 表格的外框底边已经把月历和摘要分开，不再叠一条分隔线。
                if style != .table {
                    Rectangle().fill(styleRule).frame(height: style == .board ? 2 : 0.7)
                        .padding(.horizontal, 12)
                }
                styledSelectedDaySummary(selected, previewCount: count, previewHeight: previewHeight)
            }
        }
        .foregroundStyle(styleInk)
        .modifier(ScheduleHolidayFireworks())
        .background {
            // Dense text uses a flat readable base; there is no per-cell material blur.
            if style == .paper || style == .board {
                (style.canvasColor(dark: colorScheme == .dark) ?? Color.clear)
                    .opacity(hasBackground ? 0.96 : 1)
            } else {
                ScheduleSurface(cornerRadius: style == .grid ? 12 : 0, isPanel: true, showsBorder: style != .table)
            }
        }
        .overlay {
            if style == .paper {
                Rectangle().strokeBorder(styleInk.opacity(0.6), lineWidth: 1.2)
                    .overlay { Rectangle().inset(by: 3).stroke(styleRule, lineWidth: 0.6) }
                    .allowsHitTesting(false)
            } else if style == .table {
                // 月历和下面的摘要共用这一圈外框，粗细、颜色和月历的格线一致。
                Rectangle().strokeBorder(styleRule, lineWidth: 0.6).allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func minimalMonthPage(_ days: [Day], height: CGFloat) -> some View {
        let rowCount = max(1, weeks(days).count)
        let gridSpacing = 52 + CGFloat(rowCount - 1) * 6
        let availablePreviewHeight = height - CGFloat(rowCount) * 54 - gridSpacing - previewHeaderHeight - 56
        let previewCount = availablePreviewHeight >= previewRowHeight * 2 + 8 ? 2 : 1
        let previewHeight = CGFloat(previewCount) * previewRowHeight + CGFloat(previewCount - 1) * 8
        let summaryHeight = previewHeaderHeight + previewHeight + 44
        // 为预览固定留出空间，选中有课 / 无课日期时，月历不会上下跳动。
        let rowHeight = min(68, max(54, (height - summaryHeight - gridSpacing - 12) / CGFloat(rowCount)))
        return VStack(spacing: 0) {
            monthGrid(days, rowHeight: rowHeight)
            if let selected = selectedDay(in: days) {
                Rectangle()
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.06))
                    .frame(height: 0.5)
                    .padding(.horizontal, 16)
                selectedDaySummary(selected, previewCount: previewCount, previewHeight: previewHeight)
            }
        }
        .modifier(ScheduleHolidayFireworks())
        .background { ScheduleSurface(cornerRadius: 20, isPanel: true) }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// 邻月的补位日期不接管本月摘要，翻页时始终展示这一页的内容。
    private func selectedDay(in days: [Day]) -> Day? {
        if let selected = days.first(where: { $0.inMonth && $0.date == selectedDate }) { return selected }
        if let today = days.first(where: { $0.inMonth && $0.date == todayDate }) { return today }
        return days.first(where: \.inMonth)
    }

    @ViewBuilder
    private func monthGrid(_ days: [Day], rowHeight: CGFloat) -> some View {
        if style == .minimal {
            minimalMonthGrid(days, rowHeight: rowHeight)
        } else {
            styledMonthGrid(days, rowHeight: rowHeight)
        }
    }

    private func minimalMonthGrid(_ days: [Day], rowHeight: CGFloat) -> some View {
        let rows = weeks(days)
        let selection = selectedDay(in: days)?.date
        return VStack(spacing: 12) {
            HStack(spacing: 4) {
                // 星期一行都用次要元信息灰；周末不再单独调淡，靠下面的日期数字区分。
                ForEach(Array(Self.weekdayLabels.enumerated()), id: \.offset) { _, label in
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.scheduleMeta)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 16)

            VStack(spacing: 6) {
                ForEach(rows, id: \.first?.date) { row in
                    HStack(spacing: 4) {
                        ForEach(row) { day in
                            dayCell(day, isSelected: day.date == selection, height: rowHeight)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func styledMonthGrid(_ days: [Day], rowHeight: CGFloat) -> some View {
        let rows = weeks(days)
        let selection = selectedDay(in: days)?.date
        VStack(spacing: style == .grid ? 6 : 0) {
            if style == .paper, let date = days.first(where: \.inMonth)?.date {
                Text(paperMonthTitle(date))
                    .font(.system(.subheadline, design: style.fontDesign).weight(.semibold))
                    .foregroundStyle(styleInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 30)
                    .padding(.horizontal, 12)
            }
            HStack(spacing: 0) {
                ForEach(Array(Self.weekdayLabels.enumerated()), id: \.offset) { index, label in
                    Text(label)
                        .font(.system(size: style == .paper ? 12 : 11,
                                      weight: style == .board ? .bold : .medium,
                                      design: style.fontDesign))
                        .foregroundStyle(index >= 5 ? styleInk.opacity(0.62) : styleInk.opacity(0.78))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: style == .table || style == .board ? 28 : 22)
            .background {
                if style == .table {
                    Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.045)
                } else {
                    Color.clear
                }
            }
            .overlay(alignment: .bottom) {
                if style == .table { Rectangle().fill(styleRule).frame(height: 0.6) }
            }
            if style == .paper {
                Rectangle()
                    .fill(styleInk.opacity(0.24))
                    .frame(height: 0.8)
                    .padding(.horizontal, 12)
            }
            VStack(spacing: style == .grid ? 5 : 0) {
                ForEach(rows, id: \.first?.date) { row in
                    HStack(spacing: style == .grid ? 5 : 0) {
                        ForEach(row) { day in
                            styledDayCell(day, isSelected: day.date == selection, height: rowHeight)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if style == .board {
                            Rectangle()
                                .fill(styleInk.opacity(colorScheme == .dark ? 0.24 : 0.16))
                                .frame(height: 0.6)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, style == .table || style == .board ? 0 : 10)
        // 表格的表头底色和格线要贴住外框：留白会在框里多出一条没有底色的空带。
        .padding(.vertical, style == .paper ? 12 : (style == .table ? 0 : 8))
    }

    private func dayCell(_ day: Day, isSelected: Bool, height: CGFloat) -> some View {
        let isToday = day.date == todayDate
        return Button {
            onSelect(day)
            if monthKey(day.date) != monthKey(monthAnchor) {
                monthAnchor = monthKey(day.date)
            }
        } label: {
            VStack(spacing: 3) {
                Text("\(day.number)")
                    .font(.system(size: 18, weight: isSelected || isToday ? .bold : .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(numberColor(day, isSelected: isSelected, isToday: isToday))
                    .frame(width: 30, height: 30)
                    .background {
                        ZStack {
                            Circle()
                                .fill(isSelected ? AnyShapeStyle(.themeFill) : AnyShapeStyle(.clear))
                            if isToday && !isSelected {
                                Circle()
                                    .strokeBorder(.themeText, lineWidth: 1)
                            }
                        }
                        .mask {
                            // 挖空圆形右上角，让角标嵌入；自定义背景也能透过缺口显示。
                            // 缺口和角标同心，四边各留 2pt。
                            Rectangle()
                                .overlay(alignment: .topTrailing) {
                                    if day.adjustment != nil {
                                        Circle()
                                            .frame(width: ScheduleAdjustmentBadge.size + 4,
                                                   height: ScheduleAdjustmentBadge.size + 4)
                                            .offset(x: 7, y: -7)
                                            .blendMode(.destinationOut)
                                    }
                                }
                                .compositingGroup()
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if let adjustment = day.adjustment {
                            ScheduleAdjustmentBadge(adjustment: adjustment)
                                .offset(x: 5, y: -5)
                        }
                    }

                Text(day.subtitle.isEmpty ? " " : day.subtitle)
                    .font(.system(size: 10, weight: day.isFestival ? .medium : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(subtitleColor(day))
                    .opacity(day.inMonth ? 1 : 0.6)

                courseIndicator(day)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(day))
        .accessibilityHint("选择日期，查看下方的课程预览")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityActions {
            if !day.courses.isEmpty {
                Button("查看当天安排") { onOpenDetails(day) }
            }
        }
    }

    private func styledDayCell(_ day: Day, isSelected: Bool, height: CGFloat) -> some View {
        let isToday = day.date == todayDate && !staticRendering
        return Button {
            onSelect(day)
            if monthKey(day.date) != monthKey(monthAnchor) {
                monthAnchor = monthKey(day.date)
            }
        } label: {
            styledDayLabel(day, isSelected: isSelected, isToday: isToday, height: height)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(day))
        .accessibilityHint("选择日期，查看下方的课程预览")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityActions {
            if !day.courses.isEmpty {
                Button("查看当天安排") { onOpenDetails(day) }
            }
        }
    }

    @ViewBuilder
    private func styledDayLabel(_ day: Day, isSelected: Bool, isToday: Bool, height: CGFloat) -> some View {
        let outsideOpacity = day.inMonth ? 1.0 : 0.65
        switch style {
        case .grid:
            VStack(spacing: 2) {
                styledDateNumber(day, isSelected: isSelected, isToday: isToday)
                Text(day.subtitle.isEmpty ? " " : day.subtitle)
                    .font(.system(size: 9, weight: day.isFestival ? .medium : .regular, design: style.fontDesign))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(styledSubtitleColor(day))
                courseIndicator(day)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .opacity(outsideOpacity)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: style.layout.cornerRadius)
                        .fill(Color.scheduleCellSurface(hasBackground: hasBackground, dark: colorScheme == .dark))
                    if day.adjustment?.kind == .off {
                        RoundedRectangle(cornerRadius: style.layout.cornerRadius).fill(holidayColor.opacity(0.14))
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: style.layout.cornerRadius, style: .continuous)
                    .strokeBorder(isToday || isSelected ? styleAccent : styleRule,
                                  lineWidth: isToday || isSelected ? style.layout.borderWidth : 0.7)
            }
            .overlay(alignment: .topTrailing) { styledAdjustmentBadge(day.adjustment).padding(2) }
        case .table:
            let limit = height >= 98 ? 3 : 2
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 3) {
                    styledDateNumber(day, isSelected: isSelected, isToday: isToday)
                    Spacer(minLength: 0)
                    styledAdjustmentBadge(day.adjustment)
                }
                .padding(.horizontal, 4)
                .padding(.top, 3)
                Text(day.subtitle.isEmpty ? " " : day.subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(styledSubtitleColor(day))
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                ForEach(Array(day.courses.prefix(limit))) { block in
                    HStack(spacing: 2) {
                        Rectangle()
                            .fill(ScheduleCourseTint.accent(for: block.course.name, scheme: colorScheme,
                                                           solid: themeSettings.solidCourseColor))
                            .frame(width: 2)
                        Text(shortCourseName(block))
                            .font(.system(size: 9, weight: .semibold, design: style.fontDesign))
                            .lineLimit(1)
                            .foregroundStyle(styleInk)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 12)
                    .background(courseFill(block))
                    .padding(.horizontal, 2)
                }
                if day.courses.count > limit {
                    Text("+\(day.courses.count - limit)")
                        .font(.system(size: 9, weight: .semibold, design: style.fontDesign))
                        .foregroundStyle(styleInk.opacity(0.7))
                        .padding(.leading, 4)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height, alignment: .top)
            .opacity(outsideOpacity)
            .background(isToday ? styleAccent.opacity(colorScheme == .dark ? 0.18 : 0.10) : Color.clear)
            .background(day.weekday >= 6 ? styleInk.opacity(0.04) : Color.clear)
            // 每格只画右边和下边：相邻两格各描一圈会把共用的边叠深一倍；外框由整页统一画，
            // 见 `styledMonthPage`。最后一行的下边就是月历和摘要之间的那条线。
            .overlay(alignment: .trailing) {
                if day.weekday < 7 { Rectangle().fill(styleRule).frame(width: 0.6) }
            }
            .overlay(alignment: .bottom) { Rectangle().fill(styleRule).frame(height: 0.6) }
        case .paper:
            VStack(spacing: 1) {
                ZStack(alignment: .topTrailing) {
                    styledDateNumber(day, isSelected: isSelected, isToday: isToday)
                    styledAdjustmentBadge(day.adjustment)
                        .offset(x: 7, y: -2)
                }
                Text(day.subtitle.isEmpty ? " " : day.subtitle)
                    .font(.system(size: 10, weight: day.isFestival ? .semibold : .regular, design: style.fontDesign))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(styledSubtitleColor(day))
                Rectangle()
                    .fill(styleInk.opacity(day.courses.isEmpty ? 0.18 : 0.62))
                    .frame(width: day.courses.isEmpty ? 8 : min(24, 6 + CGFloat(day.courses.count) * 4), height: 1.5)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .opacity(outsideOpacity)
            .background(isSelected ? styleAccent.opacity(0.08) : Color.clear)
            .overlay(alignment: .bottom) {
                if isSelected {
                    Rectangle().fill(styleAccent).frame(width: 16, height: 2)
                }
            }
        case .board:
            VStack(spacing: 3) {
                Text(String(format: "%02d", day.number))
                    .font(.system(size: 17, weight: isToday || isSelected ? .bold : .semibold, design: .monospaced))
                    .monospacedDigit()
                    .underline(isToday)
                Text(day.courses.isEmpty ? "—" : "\(day.courses.count) 门")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                Text(day.subtitle.isEmpty ? " " : day.subtitle)
                    .font(.system(size: 9, design: .monospaced))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .opacity(outsideOpacity)
            .foregroundStyle(isSelected ? style.canvasColor(dark: colorScheme == .dark) ?? .white : styleInk)
            .background(isSelected ? styleInk : Color.clear)
            .overlay(alignment: .topTrailing) {
                styledAdjustmentBadge(day.adjustment)
                    .padding(2)
                    .background(style.canvasColor(dark: colorScheme == .dark))
            }
        case .minimal:
            EmptyView()
        }
    }

    @ViewBuilder
    private func styledDateNumber(_ day: Day, isSelected: Bool, isToday: Bool) -> some View {
        Text("\(day.number)")
            .font(.system(size: style == .paper ? 19 : (style == .table ? 14 : 16),
                          weight: isSelected || isToday ? .bold : .medium,
                          design: style.fontDesign))
            .monospacedDigit()
            .foregroundStyle(styledNumberColor(day, isSelected: isSelected, isToday: isToday))
            .frame(width: style == .table ? nil : 32, height: style == .table ? 22 : 30)
            .padding(.horizontal, style == .table ? 3 : 0)
            .background {
                if isSelected && style != .paper && style != .board {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(styleFill)
                } else if isToday && style == .paper {
                    Circle().stroke(styleAccent, lineWidth: 1.3)
                } else {
                    Color.clear
                }
            }
    }

    private var styleInk: Color { style.inkColor(dark: colorScheme == .dark) }

    private var styleAccent: Color {
        style.styleAccent(dark: colorScheme == .dark,
                          fallback: ThemePalette.of(themeBrand).text(dark: colorScheme == .dark))
    }

    private var styleFill: Color {
        style == .grid || style == .table
            ? ThemePalette.of(themeBrand).fill(dark: colorScheme == .dark) : styleAccent
    }

    private var styleOnAccent: Color {
        style == .paper || style == .board ? (style.canvasColor(dark: colorScheme == .dark) ?? .white) : .white
    }

    private var styleRule: Color { styleInk.opacity(contrast == .increased ? 0.6 : 0.24) }

    private func styledNumberColor(_ day: Day, isSelected: Bool = false, isToday: Bool = false) -> Color {
        if isSelected && style != .paper && style != .board { return styleOnAccent }
        if isToday && style != .board { return styleAccent }
        if day.adjustment?.kind == .off || day.isStatutoryHoliday {
            return style == .paper ? styleAccent : holidayColor
        }
        return styleInk
    }

    private func styledSubtitleColor(_ day: Day) -> Color {
        if day.isStatutoryHoliday { return style == .paper ? styleAccent : holidayColor }
        if day.isFestival || (day.date == todayDate && !staticRendering) { return styleAccent }
        return styleInk.opacity(contrast == .increased ? 0.9 : 0.72)
    }

    @ViewBuilder
    private func styledAdjustmentBadge(_ adjustment: ResolvedCalendarAdjustment?) -> some View {
        if let adjustment {
            if style == .paper || style == .board {
                Text(adjustment.badge)
                    .font(.system(size: 9, weight: .bold, design: style.fontDesign))
                    .foregroundStyle(adjustment.kind == .off ? styleOnAccent : styleInk)
                    .frame(width: 12, height: 12)
                    .background(adjustment.kind == .off ? styleAccent : Color.clear)
                    .overlay { Rectangle().stroke(styleInk, lineWidth: adjustment.kind == .off ? 0 : 1) }
                    .accessibilityHidden(true)
            } else {
                ScheduleAdjustmentBadge(adjustment: adjustment)
            }
        }
    }

    private func courseFill(_ block: NativeScheduleCourseBlock) -> Color {
        let swatch = ScheduleCourseTint.swatch(for: block.course.name, solid: themeSettings.solidCourseColor)
        return NativeScheduleCourseCard.fill(for: swatch, dark: colorScheme == .dark, hasBackground: hasBackground)
    }

    /// 月历每行最多四个字；不猜测课程的官方简称，完整名称保留在预览和读屏中。
    private func shortCourseName(_ block: NativeScheduleCourseBlock) -> String {
        let name = block.course.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.count <= 4 ? name : String(name.prefix(3)) + "…"
    }

    private func chineseNumber(_ value: Int) -> String {
        let digits = ["〇", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
        guard (0...31).contains(value) else { return String(value) }
        if value < 10 { return digits[value] }
        let tens = value < 20 ? "十" : digits[value / 10] + "十"
        return tens + (value % 10 == 0 ? "" : digits[value % 10])
    }

    private func paperMonthTitle(_ date: String) -> String {
        let parts = date.split(separator: "-")
        let digits = ["〇", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
        guard parts.count == 3, let month = Int(parts[1]) else { return date }
        let year = parts[0].compactMap { $0.wholeNumberValue }.map { digits[$0] }.joined()
        return year + "年 · " + chineseNumber(month) + "月"
    }

    private func styledSummaryTitle(_ day: Day) -> String {
        let parts = day.date.split(separator: "-")
        guard parts.count >= 2, let month = Int(parts[1]) else { return summaryTitle(day) }
        if style == .paper { return "\(chineseNumber(month))月\(chineseNumber(day.number))日" }
        return summaryTitle(day)
    }

    @ViewBuilder
    private func selectedDaySummary(_ day: Day, previewCount: Int, previewHeight: CGFloat) -> some View {
        if style == .minimal {
            minimalSelectedDaySummary(day, previewCount: previewCount, previewHeight: previewHeight)
        } else {
            styledSelectedDaySummary(day, previewCount: previewCount, previewHeight: previewHeight)
        }
    }

    private func minimalSelectedDaySummary(_ day: Day, previewCount: Int, previewHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(summaryTitle(day))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if day.date == todayDate {
                            Text("今天")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.themeText)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 3)
                                .background(.themeTint(0.10), in: Capsule())
                        }
                    }
                    Text(summarySubtitle(day))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !day.courses.isEmpty {
                    Button { onOpenDetails(day) } label: {
                        HStack(spacing: 4) {
                            Text("共 \(day.courses.count) 门")
                                .font(.caption.weight(.medium))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(.themeText)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看当天安排")
                    .accessibilityValue("\(day.courses.count) 门课程")
                }
            }
            .frame(minHeight: previewHeaderHeight)

            Group {
                if day.courses.isEmpty {
                    emptyDaySummary(day)
                        .frame(maxHeight: .infinity)
                } else {
                    VStack(spacing: 8) {
                        ForEach(Array(day.courses.prefix(previewCount))) { block in
                            summaryCourseRow(block, day: day)
                                .frame(height: previewRowHeight)
                        }
                    }
                }
            }
            .frame(height: previewHeight, alignment: .top)
        }
        .padding(16)
    }

    private func styledSelectedDaySummary(_ day: Day, previewCount: Int, previewHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: style == .paper ? 10 : 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(styledSummaryTitle(day))
                    .font(.system(size: style == .paper ? 17 : 16,
                                  weight: style == .board ? .bold : .semibold,
                                  design: style.fontDesign))
                    .foregroundStyle(styleInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                if day.date == todayDate && !staticRendering {
                    Text(style == .paper ? "今日" : "今天")
                        .font(.system(size: 10, weight: .bold, design: style.fontDesign))
                        .foregroundStyle(style == .paper || style == .board ? styleOnAccent : styleAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background {
                            if style == .board {
                                Rectangle().fill(styleAccent)
                            } else if style == .paper {
                                Capsule().fill(styleAccent)
                            } else {
                                Capsule().fill(styleAccent.opacity(0.12))
                            }
                        }
                }
                Spacer(minLength: 0)
                if !day.courses.isEmpty {
                    Button { onOpenDetails(day) } label: {
                        Text("共 \(day.courses.count) 门")
                            .font(.system(size: 11, weight: .semibold, design: style.fontDesign))
                            .foregroundStyle(style == .paper ? styleAccent : styleInk.opacity(0.72))
                            .frame(minHeight: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看当天安排")
                }
            }
            // 和右侧按钮一样高：选到没课的日期时这一行不变矮，摘要和面板底边不跟着跳。
            .frame(minHeight: 36)
            Text(summarySubtitle(day))
                .font(.system(size: 11, weight: .regular, design: style.fontDesign))
                .foregroundStyle(styleInk.opacity(0.64))
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Group {
                if day.courses.isEmpty {
                    emptyDaySummary(day)
                        .frame(maxHeight: .infinity)
                } else {
                    VStack(spacing: style == .paper ? 4 : 6) {
                        ForEach(Array(day.courses.prefix(previewCount))) { block in
                            styledSummaryCourseRow(block, day: day)
                                .frame(height: previewRowHeight)
                        }
                    }
                }
            }
            .frame(height: previewHeight, alignment: .top)
        }
        .padding(.horizontal, style == .table ? 10 : 16)
        .padding(.vertical, 12)
    }

    private func styledSummaryCourseRow(_ block: NativeScheduleCourseBlock, day: Day) -> some View {
        ScheduleMonthStyledCourseRow(block: block, metadata: summaryMetadata(block), compact: true)
            .modifier(ScheduleCourseInteraction(
                cornerRadius: CGFloat(style.layout.cornerRadius),
                isEditable: isEditable,
                onPreview: { onCoursePreview(day, block) },
                onEdit: { onCourseSelected(day, block) }
            ))
    }

    private func emptyDaySummary(_ day: Day) -> some View {
        ScheduleEmptyDayView(
            note: day.adjustment?.detail,
            holidayGreeting: ChineseCalendarInfo.restGreeting(forDate: day.date),
            outsideTerm: dateIndex[day.date] == nil,
            compact: true
        )
        .id(day.date)
    }

    /// 和日视图一样，时间独立成列，课程使用同一套淡彩。
    private func summaryCourseRow(_ block: NativeScheduleCourseBlock, day: Day) -> some View {
        let swatch = ScheduleCourseTint.swatch(for: block.course.name, solid: themeSettings.solidCourseColor)
        return Group {
            HStack(spacing: 10) {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(startTime(block))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text(endTime(block))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()
                .frame(width: 46, alignment: .trailing)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(startTime(block)) 至 \(endTime(block))")

                HStack(spacing: 10) {
                    Capsule()
                        .fill(swatch.accent(scheme: colorScheme).opacity(0.55))
                        .frame(width: 3, height: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(block.course.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(summaryMetadata(block))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .frame(maxHeight: .infinity)
                .background(
                    NativeScheduleCourseCard.fill(for: swatch, dark: colorScheme == .dark, hasBackground: hasBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
            }
            .contentShape(Rectangle())
        }
        .modifier(ScheduleCourseInteraction(
            cornerRadius: 14,
            isEditable: isEditable,
            onPreview: { onCoursePreview(day, block) },
            onEdit: { onCourseSelected(day, block) }
        ))
    }

    private func summaryTitle(_ day: Day) -> String {
        let labels = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        let weekday = labels[min(max(day.weekday, 1), 7) - 1]
        let parts = day.date.split(separator: "-")
        guard parts.count >= 2, let month = Int(parts[1]) else { return "\(day.number)日" }
        return "\(month)月\(day.number)日 · \(weekday)"
    }

    private func summarySubtitle(_ day: Day) -> String {
        var parts: [String] = []
        if let slot = dateIndex[day.date] { parts.append("第 \(slot.week) 周") }
        if let info = ChineseCalendarInfo.cachedInfo(forDate: day.date) {
            parts.append(info.lunar.fullLabel)
            if day.adjustment == nil, let badge = info.badge { parts.append(badge) }
        }
        return parts.joined(separator: " · ")
    }

    private func summaryMetadata(_ block: NativeScheduleCourseBlock) -> String {
        let values = [
            block.course.location?.trimmedNonEmpty,
            block.course.teacher?.trimmedNonEmpty,
            block.startSlot == block.endSlot ? "第 \(block.startSlot) 节" : "第 \(block.startSlot)–\(block.endSlot) 节",
        ].compactMap { $0 }
        return values.joined(separator: " · ")
    }

    private func startTime(_ block: NativeScheduleCourseBlock) -> String {
        ScheduleSlot.all.first(where: { $0.number == block.startSlot })?.start ?? "--:--"
    }

    private func endTime(_ block: NativeScheduleCourseBlock) -> String {
        ScheduleSlot.all.first(where: { $0.number == block.endSlot })?.end ?? startTime(block)
    }

    /// 课程指示器：简洁的小圆点
    private func courseIndicator(_ day: Day) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(day.courses.prefix(3).enumerated()), id: \.offset) { _, block in
                Circle()
                    .fill(ScheduleCourseTint.accent(
                        for: block.course.name,
                        scheme: colorScheme,
                        solid: themeSettings.solidCourseColor
                    ))
                    .frame(width: 4, height: 4)
            }
            if day.courses.count > 3 {
                Circle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3, height: 3)
            }
        }
        .frame(height: 6)
        .opacity(day.inMonth ? 1 : 0.5)
        .accessibilityHidden(true)
    }

    private func numberColor(_ day: Day, isSelected: Bool, isToday: Bool) -> AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.themeOnFill) }
        guard day.inMonth else { return AnyShapeStyle(Color.secondary.opacity(0.6)) }
        if isToday { return AnyShapeStyle(.themeText) }
        return AnyShapeStyle(day.weekday >= 6 ? Color.secondary : Color.primary)
    }

    private func subtitleColor(_ day: Day) -> AnyShapeStyle {
        guard day.isFestival else { return AnyShapeStyle(.secondary) }
        if day.isStatutoryHoliday { return AnyShapeStyle(holidayColor) }
        return AnyShapeStyle(.themeText)
    }

    /// 法定节日名的字色。浅色和「休」角标同一个红（面板上 4.68:1），深色角标那个红压在
    /// 深底上不够亮，保留浅一档的粉。
    private var holidayColor: Color {
        colorScheme == .dark ? Color(red: 1, green: 0.55, blue: 0.65) : ScheduleAdjustmentBadge.offColor
    }

    private func accessibilityLabel(_ day: Day) -> String {
        var parts = ["\(day.number) 日", day.subtitle]
        if style != .minimal {
            parts[0] = day.date
            if !day.inMonth { parts.append("相邻月份") }
        }
        if day.date == todayDate { parts.append("今天") }
        if let slot = dateIndex[day.date] { parts.append("第 \(slot.week) 周") }
        if let adjustment = day.adjustment { parts.append(adjustment.detail) }
        parts.append(day.courses.isEmpty ? "没有课程" : "\(day.courses.count) 门课程")
        if style == .table { parts.append(day.courses.map { $0.course.name }.joined(separator: "、")) }
        return parts.joined(separator: "，")
    }

    // MARK: 月份网格数据

    struct Day: Identifiable {
        let date: String
        let number: Int
        let inMonth: Bool
        /// 1...7，周一为 1。
        let weekday: Int
        let subtitle: String
        let isFestival: Bool
        let isStatutoryHoliday: Bool
        let adjustment: ResolvedCalendarAdjustment?
        let courses: [NativeScheduleCourseBlock]

        var id: String { date }
    }

    private func weeks(_ days: [Day]) -> [[Day]] {
        stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
    }

    private func buildDays(anchor: String? = nil) -> [Day] {
        let key = monthKey(anchor ?? monthAnchor)
        let revision = ChineseCalendarInfo.holidayRevision
        if dataCache.contentRevision != contentRevision || dataCache.holidayRevision != revision
            || dataCache.generation != calendarGeneration {
            dataCache.days.removeAll(keepingCapacity: true)
            dataCache.contentRevision = contentRevision
            dataCache.holidayRevision = revision
            dataCache.generation = calendarGeneration
        }
        if let days = dataCache.days[key] { return days }
        let days = makeDays(anchor: key)
        if dataCache.days.count >= 12 { dataCache.days.removeAll(keepingCapacity: true) }
        dataCache.days[key] = days
        return days
    }

    private func makeDays(anchor: String) -> [Day] {
        let calendar = ChineseCalendarInfo.gregorian
        guard let anchor = ChineseCalendarInfo.date(fromDate: anchor),
              let monthRange = calendar.range(of: .day, in: .month, for: anchor),
              let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: anchor)) else {
            return []
        }
        let month = calendar.component(.month, from: anchor)
        // 网格从这个月第一天所在的周一开始，铺满整周为止。
        let leading = (calendar.component(.weekday, from: firstOfMonth) + 5) % 7
        let total = Int(ceil(Double(leading + monthRange.count) / 7)) * 7
        return (0..<total).compactMap { offset -> Day? in
            guard let date = calendar.date(byAdding: .day, value: offset - leading, to: firstOfMonth) else { return nil }
            let key = ChineseCalendarInfo.dateString(date)
            let info = ChineseCalendarInfo.cachedInfo(forDate: key)
            // 节日名称只显示在当天，连休期间的其余日期仍显示农历。
            let festival = info?.festivals.first ?? info?.solarTerm
            let slot = dateIndex[key]
            let weekdayIndex = (calendar.component(.weekday, from: date) + 5) % 7 + 1
            return Day(
                date: key,
                number: calendar.component(.day, from: date),
                inMonth: calendar.component(.month, from: date) == month,
                weekday: weekdayIndex,
                subtitle: festival ?? info?.lunar.shortLabel ?? "",
                isFestival: festival != nil,
                isStatutoryHoliday: info?.isStatutoryHoliday ?? false,
                adjustment: adjustments[key],
                courses: slot.map { blocks($0.day, $0.week) } ?? []
            )
        }
    }
}

/// 弹窗固定展示被点击的日期，由课表主视图管理呈现与后续跳转。
struct NativeScheduleMonthDayDetails: View {
    let day: NativeScheduleMonthView.Day
    let slot: NativeScheduleMonthView.DaySlot?
    let onOpenDay: () -> Void
    var isEditable = true
    let onCoursePreview: (NativeScheduleCourseBlock) -> Void
    let onCourseSelected: (NativeScheduleCourseBlock) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scheduleStyle) private var style
    @ObservedObject private var themeSettings = NativeThemeSettings.shared

    var body: some View {
        // sheet 自己就是一层底，内容直接排在上面，不再套一张白卡片。
        ScrollView {
            content
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 16)
        }
        .modifier(ScheduleHolidayFireworks())
        .scrollBounceBehavior(.basedOnSize)
        .appSoftTopScrollEdge()
        .appSheetDetents([.medium, .large])
        .background {
            if let canvas = style.canvasColor(dark: colorScheme == .dark) {
                canvas.ignoresSafeArea()
            }
        }
    }

    private var content: some View {
        let courses = day.courses
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedTitle)
                        .font(.title2.weight(.bold))
                        .fontDesign(style == .minimal ? .default : style.fontDesign)
                        .accessibilityAddTraits(.isHeader)
                    Text(selectedSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if slot != nil {
                    Button {
                        onOpenDay()
                    } label: {
                        Text("日视图")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(.themeTint(colorScheme == .dark ? 0.2 : 0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.themeText)
                    .accessibilityLabel("在日视图中打开")
                }
            }

            if let adjustment = day.adjustment {
                // 和月历格子里同一个角标，说明文字用正文色。
                HStack(spacing: 8) {
                    ScheduleAdjustmentBadge(adjustment: adjustment)
                    Text(adjustment.detail)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                }
                .accessibilityElement(children: .combine)
            }

            if slot == nil {
                ScheduleEmptyDayView(holidayGreeting: ChineseCalendarInfo.restGreeting(forDate: day.date), outsideTerm: true)
            } else if courses.isEmpty {
                ScheduleEmptyDayView(holidayGreeting: ChineseCalendarInfo.restGreeting(forDate: day.date))
            } else {
                VStack(spacing: 8) {
                    ForEach(courses) { block in
                        agendaRow(block)
                    }
                }
            }
        }
        .foregroundStyle(style.inkColor(dark: colorScheme == .dark))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 一门课一块淡彩：和日视图的课程卡片同色，时间放右边。
    @ViewBuilder
    private func agendaRow(_ block: NativeScheduleCourseBlock) -> some View {
        if style == .minimal {
            minimalAgendaRow(block)
        } else {
            ScheduleMonthStyledCourseRow(block: block, metadata: metadata(block))
                .modifier(ScheduleCourseInteraction(
                    cornerRadius: CGFloat(style.layout.cornerRadius),
                    isEditable: isEditable,
                    onPreview: { onCoursePreview(block) },
                    onEdit: { onCourseSelected(block) }
                ))
        }
    }

    private func minimalAgendaRow(_ block: NativeScheduleCourseBlock) -> some View {
        let swatch = ScheduleCourseTint.swatch(for: block.course.name, solid: themeSettings.solidCourseColor)
        return Group {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(block.course.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(metadata(block))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(startTime(block))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text(endTime(block))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                NativeScheduleCourseCard.fill(for: swatch, dark: colorScheme == .dark),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .modifier(ScheduleCourseInteraction(
            cornerRadius: 16,
            isEditable: isEditable,
            onPreview: { onCoursePreview(block) },
            onEdit: { onCourseSelected(block) }
        ))
    }

    private func metadata(_ block: NativeScheduleCourseBlock) -> String {
        let values = [
            block.course.location?.trimmedNonEmpty,
            block.course.teacher?.trimmedNonEmpty,
            block.startSlot == block.endSlot ? "第 \(block.startSlot) 节" : "\(block.startSlot)–\(block.endSlot) 节",
        ].compactMap { $0 }
        return values.joined(separator: " · ")
    }

    private func startTime(_ block: NativeScheduleCourseBlock) -> String {
        ScheduleSlot.all.first(where: { $0.number == block.startSlot })?.start ?? "--:--"
    }

    private func endTime(_ block: NativeScheduleCourseBlock) -> String {
        ScheduleSlot.all.first(where: { $0.number == block.endSlot })?.end ?? startTime(block)
    }

    private var selectedTitle: String {
        let pieces = day.date.split(separator: "-")
        guard pieces.count == 3, let month = Int(pieces[1]) else { return day.date }
        let labels = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        return "\(month)月\(day.number)日 \(labels[min(max(day.weekday, 1), 7) - 1])"
    }

    private var selectedSubtitle: String {
        var parts: [String] = []
        if let slot { parts.append("第 \(slot.week) 周") }
        if let info = ChineseCalendarInfo.cachedInfo(forDate: day.date) {
            parts.append(info.lunar.fullLabel)
            if let badge = info.badge { parts.append(badge) }
        }
        return parts.joined(separator: " · ")
    }
}
