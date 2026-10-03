import SwiftUI

/// 月视图：课表界面的第三种视图，和「日」「周」共用同一个顶栏切换。
///
/// 周视图和日视图都是按节次画网格的课表；月视图不再画网格，而是一张日历：每天一
/// 格，格子里是公历日、农历/节日和表示当天课程数量的横条，点击日期展开课程清
/// 单。教学周信息保留在每行左侧的「周」栏里，这样月历和学期周次仍能对上。
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

    private static let weekdayLabels = ["一", "二", "三", "四", "五", "六", "日"]
    private static let gutterWidth: CGFloat = 20

    var body: some View {
        GeometryReader { geometry in
            // 外层测量未被标签栏遮挡的高度；滚动视口和每页则延伸到屏幕底部。
            let pageHeight = geometry.size.height + geometry.safeAreaInsets.bottom
            if #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) {
                monthScroller(contentHeight: geometry.size.height, pageHeight: pageHeight)
                    .onScrollPhaseChange { _, phase in
                        if phase == .idle { commitVisibleMonth() }
                    }
            } else {
                monthScroller(contentHeight: geometry.size.height, pageHeight: pageHeight)
                    .onChange(of: visibleMonth) { _, _ in commitVisibleMonth() }
            }
        }
        .padding(.horizontal, 12)
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
                    monthGrid(buildDays(anchor: month), height: contentHeight)
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

    private func monthGrid(_ days: [Day], height: CGFloat) -> some View {
        let rows = weeks(days)
        let courseScale = max(6, days.map { $0.courses.count }.max() ?? 0)
        let rowHeight = max(0, (height - 38) / CGFloat(max(1, rows.count)))
        return VStack(spacing: 0) {
            HStack(spacing: 2) {
                Text("周")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: Self.gutterWidth)
                ForEach(Array(Self.weekdayLabels.enumerated()), id: \.offset) { index, label in
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            ForEach(rows, id: \.first?.date) { row in
                HStack(spacing: 2) {
                    Text(row.compactMap { dateIndex[$0.date]?.week }.first.map(String.init) ?? "")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: Self.gutterWidth)
                    ForEach(row) { day in
                        dayCell(day, height: rowHeight, courseScale: courseScale)
                    }
                }
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.secondary.opacity(0.12)).frame(height: 0.5)
                }
            }
        }
        .padding(.top, 10)
    }

    private func dayCell(_ day: Day, height: CGFloat, courseScale: Int) -> some View {
        let isSelected = day.date == selectedDate
        let isToday = day.date == todayDate
        return Button {
            onSelect(day)
            // 邻月日期对应其实际月份。
            if monthKey(day.date) != monthKey(monthAnchor) {
                monthAnchor = monthKey(day.date)
            }
        } label: {
            VStack(spacing: 4) {
                Text("\(day.number)")
                    .font(.system(size: 20, weight: isToday || isSelected ? .semibold : .regular))
                    .foregroundStyle(isToday || isSelected ? Color.white : numberColor(day, isSelected: false, isToday: false))
                    .frame(width: 32, height: 32)
                    .background {
                        if isToday {
                            Circle().fill(Color.red)
                        } else if isSelected {
                            Circle().fill(colorScheme == .dark ? Color.white.opacity(0.25) : Color.primary)
                        }
                    }
                Text(day.subtitle)
                    .font(.system(size: 10, weight: .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(subtitleColor(day, isSelected: isSelected))
                    .opacity(day.inMonth ? 1 : 0.4)
                courseBar(day, scale: courseScale)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.horizontal, 2)
            .frame(height: height, alignment: .top)
            .clipped()
            .overlay(alignment: .topTrailing) {
                if let adjustment = day.adjustment {
                    Text(adjustment.badge)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .fixedSize()
                        .frame(width: 13, height: 13, alignment: .center)
                        // 小字号汉字做光学居中，仅移动文字，不移动底色。
                        .offset(x: 0.2)
                        .background(
                            (adjustment.kind == .off ? Color.pink : Color.orange).opacity(0.9),
                            in: RoundedRectangle(cornerRadius: 3, style: .continuous)
                        )
                        .padding(.top, 1)
                        .padding(.trailing, 1)
                        .opacity(day.inMonth ? 1 : 0.45)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(day))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }

    /// 同月使用一致的比例，课程越多横条越长；空课日不画横条。
    private func courseBar(_ day: Day, scale: Int) -> some View {
        Capsule()
            .fill(Color.cpuBrand)
            .scaleEffect(x: CGFloat(day.courses.count) / CGFloat(scale), y: 1, anchor: .center)
            .frame(height: 4)
            .padding(.horizontal, 4)
            .padding(.top, 2)
            .opacity(day.courses.isEmpty ? 0 : (day.inMonth ? 0.85 : 0.3))
            .accessibilityHidden(true)
    }

    private func numberColor(_ day: Day, isSelected: Bool, isToday: Bool) -> Color {
        guard day.inMonth else { return .secondary.opacity(0.45) }
        if isToday || isSelected { return Color.cpuBrand }
        if day.isStatutoryHoliday { return .pink }
        return day.weekday >= 6 ? .secondary : .primary
    }

    private func subtitleColor(_ day: Day, isSelected: Bool) -> Color {
        if day.isStatutoryHoliday { return .pink }
        return .secondary
    }

    private func accessibilityLabel(_ day: Day) -> String {
        var parts = ["\(day.number) 日", day.subtitle]
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
        ScrollView {
            selectedDayCard
                .padding(16)
        }
        .appSheetDetents([.medium, .large])
    }

    private var selectedDayCard: some View {
        let courses = day.courses
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedTitle)
                        .font(.headline)
                    Text(selectedSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if slot != nil {
                    Button {
                        onOpenDay()
                    } label: {
                        Label("日视图", systemImage: "calendar.day.timeline.left")
                            .font(.caption.weight(.semibold))
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.cpuBrand)
                }
            }

            if let adjustment = day.adjustment {
                Label(adjustment.detail, systemImage: "calendar.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(adjustment.kind == .off ? Color.pink : Color.orange)
            }

            if slot == nil {
                Text("这一天不在当前学期的教学周内。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if courses.isEmpty {
                Text(day.adjustment?.kind == .off ? "这一天放假，没有课程。" : "这一天没有课程。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(courses) { block in
                    agendaRow(block)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { ScheduleSurface(cornerRadius: 16, isCard: true) }
    }

    private func agendaRow(_ block: NativeScheduleCourseBlock) -> some View {
        Button {
            onCourseSelected(block)
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(ScheduleCourseTint.accent(for: block.course.name, scheme: colorScheme, solid: themeSettings.solidCourseColor))
                    .frame(width: 4, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(block.course.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(metadata(block))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(timeRange(block))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("查看或修改课程"))
    }

    private func metadata(_ block: NativeScheduleCourseBlock) -> String {
        let values = [
            block.course.location?.trimmedNonEmpty,
            block.course.teacher?.trimmedNonEmpty,
            "第 \(block.startSlot)-\(block.endSlot) 节",
        ].compactMap { $0 }
        return values.joined(separator: " · ")
    }

    private func timeRange(_ block: NativeScheduleCourseBlock) -> String {
        let slots = ScheduleSlot.all
        guard let start = slots.first(where: { $0.number == block.startSlot }) else { return "--:--" }
        let end = slots.first(where: { $0.number == block.endSlot }) ?? start
        return "\(start.start)\n\(end.end)"
    }

    private var selectedTitle: String {
        let pieces = day.date.split(separator: "-")
        guard pieces.count == 3, let month = Int(pieces[1]) else { return day.date }
        let labels = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        return "\(month) 月 \(day.number) 日 · \(labels[min(max(day.weekday, 1), 7) - 1])"
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
