#if DEBUG
import SwiftUI

/// Debug 专用入口。此视图使用内存样本，不创建 AppStore / NativeScheduleStore。
/// MyApp 的 AppStore 位于仅正常启动使用的 NormalAppRoot；Demo 分支不构造它。
struct ScheduleStyleDemoRoot: View {
    private let configuration = ScheduleStyleDemoConfiguration()
    @State private var calendarReady = false

    init() {
        // 月历摘要目前从 ScheduleSlot.all 取时间；仅替换进程内的作息，不写偏好或课表。
        ScheduleSlot.all = ScheduleStyleDemoData.clocks
    }

    var body: some View {
        Group {
            if calendarReady {
                ScheduleStyleDemoContent(configuration: configuration)
                    .task { await publishReady() }
            } else {
                ProgressView("准备示例课表")
            }
        }
        .environment(\.scheduleStyle, configuration.style)
        .environment(\.colorScheme, configuration.dark ? .dark : .light)
        .preferredColorScheme(configuration.dark ? .dark : .light)
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .environment(\.calendar, ScheduleStyleDemoData.calendar)
        .environment(\.timeZone, ScheduleStyleDemoData.calendar.timeZone)
        .environment(\.dynamicTypeSize, .large)
        .environment(\.appThemeBrand, ScheduleStyleDemoData.brand)
        .environment(\.appThemeBackgroundEnabled, true)
        .environment(\.scheduleHasBackgroundImage, false)
        .environment(\.scheduleBackgroundOpacity, 0)
        .environment(\.scheduleStaticRendering, false)
        .task {
            await ChineseCalendarInfo.prewarm(year: 2027)
            guard !Task.isCancelled else { return }
            calendarReady = true
        }
    }

    private func publishReady() async {
        // 让月历的 scrollPosition 与首帧布局完成；脚本还会在收到标记后等待稳定帧。
        do {
            try await Task.sleep(for: .seconds(1))
            let environment = ProcessInfo.processInfo.environment
            guard environment["NAPTABLE_STYLE_DEMO"] == "1",
                  let runID = environment["NAPTABLE_DEMO_RUN_ID"] else { return }
            let marker: [String: String] = [
                "runID": runID, "style": configuration.style.rawValue,
                "view": configuration.view.rawValue, "dark": configuration.dark ? "1" : "0",
                "date": ScheduleStyleDemoData.today, "time": "11:05", "fixture": "1"
            ]
            let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("schedule-style-demo-ready.json")
            try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys]).write(to: url, options: .atomic)
        } catch {
            print("[ScheduleStyleDemo] 就绪标记未写入：\(error)")
        }
    }
}

private struct ScheduleStyleDemoConfiguration {
    enum Surface: String { case week, day, month }
    let style: ScheduleStyle
    let view: Surface
    let dark: Bool

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        style = environment["NAPTABLE_DEMO_STYLE"].flatMap(ScheduleStyle.init(rawValue:)) ?? .minimal
        view = environment["NAPTABLE_DEMO_VIEW"].flatMap(Surface.init(rawValue:)) ?? .week
        dark = environment["NAPTABLE_DEMO_DARK"] == "1"
    }
}

private struct ScheduleStyleDemoContent: View {
    let configuration: ScheduleStyleDemoConfiguration
    @State private var monthAnchor = "2027-04-01"
    @State private var selectedDate = ScheduleStyleDemoData.today

    private var style: ScheduleStyle { configuration.style }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                .padding(.horizontal, 16)
            switch configuration.view {
            case .week:
                ScrollView {
                    weekGrid.padding(.horizontal, 16)
                }
            case .day:
                ScrollView {
                    NativeScheduleDayTimeline(
                        blocks: ScheduleStyleDemoData.blocks(day: 3, week: 7),
                        clocks: ScheduleStyleDemoData.clocks,
                        day: 3,
                        nowMinutes: ScheduleStyleDemoData.nowMinutes,
                        completedBeforeMinutes: ScheduleStyleDemoData.nowMinutes,
                        isEditable: false,
                        onCourseSelected: { _ in }
                    )
                    .padding(.horizontal, 16)
                    // 正式日视图上下留有按压余量（`pressInset`），简约卡片探出顶边的「已结束」角标才不被裁掉。
                    .padding(.vertical, 16)
                }
            case .month:
                NativeScheduleMonthView(
                    monthAnchor: $monthAnchor,
                    contentRevision: ScheduleStyleDemoData.now,
                    selectedDate: selectedDate,
                    todayDate: ScheduleStyleDemoData.today,
                    dateIndex: ScheduleStyleDemoData.dateIndex,
                    blocks: { ScheduleStyleDemoData.blocks(day: $0, week: $1) },
                    adjustments: ScheduleStyleDemoData.adjustments,
                    onSelect: { selectedDate = $0.date },
                    onOpenDetails: { selectedDate = $0.date },
                    isEditable: false,
                    onCoursePreview: { _, _ in },
                    onCourseSelected: { _, _ in },
                    onMoveMonth: { offset in
                        guard let date = ChineseCalendarInfo.date(fromDate: monthAnchor),
                              let next = ScheduleStyleDemoData.calendar.date(byAdding: .month, value: offset, to: date)
                        else { return }
                        monthAnchor = ChineseCalendarInfo.dateString(next)
                        selectedDate = monthAnchor
                    }
                )
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if let canvas = style.canvasColor(dark: configuration.dark) {
                canvas.ignoresSafeArea()
            } else {
                Rectangle().fill(.scheduleCanvas).ignoresSafeArea()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("示例课表").font(.system(size: 20, weight: .bold, design: style.fontDesign))
                Spacer()
                Text(style.title + " · " + ["week": "周", "day": "日", "month": "月"][configuration.view.rawValue]!)
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(style.inkColor(dark: configuration.dark))
            HStack {
                Text("第 7 周 · 4.5–4.11")
                Spacer()
                Text("周三 11:05")
            }
            .font(.system(size: 14, weight: .medium, design: style.fontDesign))
            .foregroundStyle(.themeText)
            Text("2027 年 4 月 · 固定示例，休／班非官方安排")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var weekGrid: some View {
        GeometryReader { geometry in
            let axisWidth: CGFloat = 32
            // 和正式周视图一样，只有简约和格子在两天之间留缝。
            let gap: CGFloat = style == .minimal || style == .grid ? 3 : 0
            let rowHeight = NativeScheduleDayColumn.slotHeight
            // 表格的格线贴着面板边画，不留内边距，和正式周视图一致。
            let panelPadding: CGFloat = style == .table ? 0 : 6
            let columnWidth = max(12, (geometry.size.width - 2 * panelPadding - axisWidth - gap * 7) / 7)
            HStack(alignment: .top, spacing: gap) {
                VStack(spacing: 0) {
                    Text("4月")
                        .font(.caption2)
                        .frame(height: NativeScheduleDayColumn.dateHeaderHeight)
                    VStack(spacing: NativeScheduleDayColumn.slotGap) {
                        ForEach(ScheduleStyleDemoData.clocks) { clock in
                            VStack(spacing: 2) {
                                Text(String(clock.number)).font(.system(size: 13, weight: .bold, design: style.fontDesign))
                                Text(clock.start).font(.system(size: 8, design: style.fontDesign))
                            }
                            .monospacedDigit()
                            .frame(height: rowHeight)
                        }
                    }
                }
                .foregroundStyle(.secondary)
                .frame(width: axisWidth)

                ForEach(1...7, id: \.self) { day in
                    NativeScheduleDayColumn(
                        day: day,
                        dateText: "4.\(day + 4)",
                        headerDateText: String(day + 4),
                        isToday: day == 3,
                        adjustment: ScheduleStyleDemoData.adjustments["2027-04-" + String(format: "%02d", day + 4)],
                        columnWidth: columnWidth,
                        rowHeight: rowHeight,
                        slotCount: ScheduleStyleDemoData.clocks.count,
                        clocks: ScheduleStyleDemoData.clocks,
                        compactCards: true,
                        showsDateHeader: true,
                        isEditable: false,
                        blocks: ScheduleStyleDemoData.blocks(day: day, week: 7),
                        onCourseSelected: { _ in },
                        onEmptySlot: { _ in },
                        // 和正式周视图一样只把「现在」传给今天那列：格子的现在线、当前课程描边、站牌反白才会出现。
                        nowMinutes: day == 3 ? ScheduleStyleDemoData.nowMinutes : nil
                    )
                }
            }
            .background(alignment: .topLeading) {
                if style == .table {
                    ScheduleTableRules(
                        headerHeight: NativeScheduleDayColumn.dateHeaderHeight, rowHeight: rowHeight,
                        slotCount: ScheduleStyleDemoData.clocks.count, axisWidth: axisWidth,
                        columnWidth: columnWidth, dayCount: 7,
                        joined: { column, row in
                            ScheduleStyleDemoData.blocks(day: column + 1, week: 7)
                                .contains { $0.startSlot <= row && row < $0.endSlot }
                        }
                    )
                }
            }
            .padding(.horizontal, panelPadding)
            .padding(.bottom, panelPadding)
            // 正式组件负责每列风格；此处只补主视图私有的简约横线与公共面板。
            .background {
                if style == .minimal {
                    Canvas { context, size in
                        var path = Path()
                        for row in 0..<ScheduleStyleDemoData.clocks.count {
                            let y = NativeScheduleDayColumn.dateHeaderHeight
                                + CGFloat(row) * (rowHeight + NativeScheduleDayColumn.slotGap)
                                - NativeScheduleDayColumn.slotGap / 2
                            path.move(to: CGPoint(x: axisWidth + 6, y: y))
                            path.addLine(to: CGPoint(x: size.width - 6, y: y))
                        }
                        context.stroke(path, with: .color(.scheduleCellBorder(dark: configuration.dark)), lineWidth: 0.5)
                    }
                }
            }
            .background { ScheduleSurface(cornerRadius: 20, isPanel: true, showsBorder: style != .table) }
        }
        .frame(height: NativeScheduleDayColumn.dateHeaderHeight
               + CGFloat(ScheduleStyleDemoData.clocks.count) * (NativeScheduleDayColumn.slotHeight + NativeScheduleDayColumn.slotGap) + 3)
    }
}

/// 与 HTML 示意图共用第 7 周日期、11 节作息和课程；不复制网页绘图。
private enum ScheduleStyleDemoData {
    static let today = "2027-04-07"
    static let nowMinutes = 11 * 60 + 5
    static let brand = ScheduleLiveActivityRGB(red: 0.91, green: 0.39, blue: 0.55)
    static let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        value.firstWeekday = 2
        return value
    }()
    static let now = calendar.date(from: DateComponents(year: 2027, month: 4, day: 7, hour: 11, minute: 5))!
    static let semesterStart = calendar.date(from: DateComponents(year: 2027, month: 2, day: 22))!
    static let clocks: [ScheduleSlot] = [
        ("08:00", "08:45"), ("08:55", "09:40"), ("10:00", "10:45"), ("10:55", "11:40"),
        ("14:00", "14:45"), ("14:55", "15:40"), ("16:00", "16:45"), ("16:55", "17:40"),
        ("19:00", "19:45"), ("19:55", "20:40"), ("20:50", "21:35")
    ].enumerated().map { ScheduleSlot(number: $0.offset + 1, start: $0.element.0, end: $0.element.1) }

    static let adjustments: [String: ResolvedCalendarAdjustment] = [
        "2027-04-05": .init(date: "2027-04-05", kind: .off, sourceDate: nil, sourceWeek: nil,
                            sourceDay: nil, note: "示例", badge: "休", detail: "清明假期（示例）"),
        "2027-04-11": .init(date: "2027-04-11", kind: .swap, sourceDate: "2027-04-05", sourceWeek: 7,
                            sourceDay: 1, note: "示例", badge: "班", detail: "补周一课程（示例）")
    ]

    static let dateIndex: [String: NativeScheduleMonthView.DaySlot] = {
        var result: [String: NativeScheduleMonthView.DaySlot] = [:]
        for offset in 0..<(17 * 7) {
            let date = calendar.date(byAdding: .day, value: offset, to: semesterStart)!
            result[ChineseCalendarInfo.dateString(date)] = .init(week: offset / 7 + 1, day: offset % 7 + 1)
        }
        return result
    }()

    static func blocks(day: Int, week: Int) -> [NativeScheduleCourseBlock] {
        if week == 7 && day == 1 { return [] }
        let sourceDay = week == 7 && day == 7 ? 1 : day
        let lessons: [(Int, Int, String, String, String)]
        switch sourceDay {
        case 1: lessons = [(1, 2, "高等数学A(二)", "教1-201", "王老师"), (3, 4, "体育(羽毛球)", "体育馆", "钱老师")]
        case 2: lessons = [(1, 2, "线性代数", "教2-110", "李老师"), (3, 4, "大学英语(二)", "外语楼305", "Smith"), (7, 8, "程序设计基础", "实验楼B402", "陈老师")]
        case 3: lessons = [(1, 2, "高等数学A(二)", "教1-201", "王老师"), (3, 4, "中国近现代史纲要", "教3-101", "刘老师"), (5, 6, "大学物理", "教4-203", "赵老师"), (9, 10, "形势与政策", "报告厅", "孙老师")]
        case 4: lessons = [(1, 2, "数据结构", "教1-305", "周老师"), (3, 4, "大学英语(二)", "外语楼305", "Smith"), (6, 7, "大学物理实验", "物理楼210", "吴老师")]
        case 5: lessons = [(1, 2, "线性代数", "教2-110", "李老师"), (3, 4, "程序设计基础", "实验楼B402", "陈老师"), (5, 6, "思想道德与法治", "教3-202", "郑老师")]
        default: lessons = []
        }
        return lessons.map { start, end, name, location, teacher in
            let id = "demo-\(week)-\(day)-\(start)"
            let course = NativeScheduleCourse(name: name, teacher: teacher, weeks: "1–17周", weekList: Array(1...17),
                                              location: location, startSlot: start, endSlot: end, sourceKey: id)
            return NativeScheduleCourseBlock(id: id, course: course, bigSlot: (start + 1) / 2,
                                             startSlot: start, endSlot: end)
        }
    }
}
#endif
