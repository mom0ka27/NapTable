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
            if geometry.size.height < 480 || dynamicTypeSize.isAccessibilitySize {
                // 横屏和大字号下让整页自然滚动，完整安排始终能被访问。
                ScrollView(.vertical, showsIndicators: false) {
                    monthPage(buildDays(anchor: monthAnchor), height: max(640, geometry.size.height))
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

    private func monthPage(_ days: [Day], height: CGFloat) -> some View {
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

    private func monthGrid(_ days: [Day], rowHeight: CGFloat) -> some View {
        let rows = weeks(days)
        let selection = selectedDay(in: days)?.date
        return VStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(Array(Self.weekdayLabels.enumerated()), id: \.offset) { index, label in
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.secondary.opacity(index >= 5 ? 0.65 : 1))
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
                    .frame(height: 24)

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
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.cpuBrand.opacity(colorScheme == .dark ? 0.20 : 0.10) : .clear)
            }
            .overlay {
                if isToday {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.cpuBrand.opacity(isSelected ? 0.45 : 0.3), lineWidth: 1)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let adjustment = day.adjustment {
                    Text(adjustment.badge)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(adjustment.kind == .off ? holidayColor : Color.orange)
                        .padding(.top, 3)
                        .padding(.trailing, 3)
                        .opacity(day.inMonth ? 1 : 0.4)
                        .accessibilityHidden(true)
                }
            }
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

    private func selectedDaySummary(_ day: Day, previewCount: Int, previewHeight: CGFloat) -> some View {
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
                                .foregroundStyle(Color.cpuBrand)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 3)
                                .background(Color.cpuBrand.opacity(0.10), in: Capsule())
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
                        .foregroundStyle(Color.cpuBrand)
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
        return Button { onCourseSelected(day, block) } label: {
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
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("查看或修改课程")
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

    private func numberColor(_ day: Day, isSelected: Bool, isToday: Bool) -> Color {
        guard day.inMonth else { return .secondary.opacity(0.6) }
        if isSelected { return Color.cpuBrand }
        if isToday { return Color.cpuBrand }
        return day.weekday >= 6 ? .secondary : .primary
    }

    private func subtitleColor(_ day: Day) -> Color {
        if day.isStatutoryHoliday { return holidayColor }
        if day.isFestival { return Color.cpuBrand }
        return .secondary
    }

    private var holidayColor: Color {
        colorScheme == .dark ? Color(red: 1, green: 0.55, blue: 0.65) : Color.pink.opacity(0.8)
    }

    private func accessibilityLabel(_ day: Day) -> String {
        var parts = ["\(day.number) 日", day.subtitle]
        if day.date == todayDate { parts.append("今天") }
        if let slot = dateIndex[day.date] { parts.append("第 \(slot.week) 周") }
        if let adjustment = day.adjustment { parts.append(adjustment.detail) }
        parts.append(day.courses.isEmpty ? "没有课程" : "\(day.courses.count) 门课程")
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
            let slot = dateIndex[key]
            let weekdayIndex = (calendar.component(.weekday, from: date) + 5) % 7 + 1
            return Day(
                date: key,
                number: calendar.component(.day, from: date),
                inMonth: calendar.component(.month, from: date) == month,
                weekday: weekdayIndex,
                subtitle: info?.displayLabel ?? "",
                isFestival: info?.badge != nil,
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
    let onCourseSelected: (NativeScheduleCourseBlock) -> Void

    @Environment(\.colorScheme) private var colorScheme
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
    }

    private var content: some View {
        let courses = day.courses
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedTitle)
                        .font(.title2.weight(.bold))
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
                            .background(Color.cpuBrand.opacity(colorScheme == .dark ? 0.2 : 0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.cpuBrand)
                    .accessibilityLabel("在日视图中打开")
                }
            }

            if let adjustment = day.adjustment {
                Label(adjustment.detail, systemImage: "calendar.badge.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(adjustment.kind == .off ? Color.pink : Color.orange)
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 一门课一块淡彩：和日视图的课程卡片同色，时间放右边。
    private func agendaRow(_ block: NativeScheduleCourseBlock) -> some View {
        let swatch = ScheduleCourseTint.swatch(for: block.course.name, solid: themeSettings.solidCourseColor)
        return Button {
            onCourseSelected(block)
        } label: {
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
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("查看或修改课程"))
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
