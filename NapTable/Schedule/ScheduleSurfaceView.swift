import SwiftUI

// Ported from ../CPU-Web/ios_next (CpuTime) `NativeScheduleView.swift`.
//
// The layout, spacing, glass styling and interaction model are kept as close to
// the original as possible; only the platform-shim spellings were changed so the
// same file builds on iOS and macOS. Data comes from `NativeScheduleStore`,
// which `ScheduleStore.swift` implements on top of NapTable's AppStore.

import SwiftUI

/// The native timetable surface. Data loading and authentication stay in
/// NativeScheduleStore so the SwiftUI surface can also be embedded beside the
/// existing web routes.
struct NativeScheduleView: View {
    @ObservedObject private var store: NativeScheduleStore
    @ObservedObject private var preferences = NativeSchedulePreferences.shared
    private let onAddTable: () -> Void
    private let onLogin: () -> Void
    private let showsWatch: Bool
    private let onWatch: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @State private var selectedDay = 1
    @State private var didInitializeDay = false
    @State private var viewMode: SurfaceViewMode = .week
    @State private var selectedCourse: SelectedCourse?
    @State private var addCourseContext: AddCourseContext?
    @State private var weekPickerPresented = false
    @State private var freeCoursesPresented = false
    #if DEBUG
    @State private var debugCropImage: DebugCropImage?
    @State private var debugCropOpacity = BackgroundCropEditor.Opacity(light: 0.18, dark: 0.28)
    #endif
    // Horizontal week paging state. The track holds the previous, current and
    // next week so a swipe drags the neighbouring timetable into view instead
    // of replacing the grid in place.
    // Native pagers own the horizontal pan and keep the current page under the
    // finger. The center page is restored after a transition commits the new
    // week/day to the store, so vertical scrolling never competes with a
    // hand-written DragGesture.
    @State private var weekPageSelection = 1
    @State private var dayPageSelection = 1
    @State private var weekPaging = false
    @State private var dayPaging = false
    @State private var weekTransitionToken = 0
    @State private var dayTransitionToken = 0
    // 月视图的两个位置：正在显示的月份和选中的那一天，都是 `yyyy-MM-dd`。
    @State private var monthAnchor = ""
    @State private var selectedMonthDate = ""
    @State private var pendingMonthDay: String?

    init(
        store: NativeScheduleStore,
        onLogin: @escaping () -> Void = {},
        onAddTable: @escaping () -> Void = {},
        showsWatch: Bool = false,
        onWatch: @escaping () -> Void = {}
    ) {
        _store = ObservedObject(wrappedValue: store)
        self.onAddTable = onAddTable
        self.onLogin = onLogin
        self.showsWatch = showsWatch
        self.onWatch = onWatch
    }

    /// 当前外观下铺在课表后面的图。深色没单独设图时沿用浅色的，反之亦然；
    /// 「显示背景图片」关着就是没有。
    private var displayedBackground: ScheduleBackgroundImage? {
        preferences.visibleBackgroundImage(dark: colorScheme == .dark)
    }

    /// 顶栏和课表区域自己的底色。有背景图片时必须透明，否则整张图会被这层
    /// 底色盖住；图片下面那层 `appGroupedBackground` 由 `body` 的背景统一铺满全屏。
    private var chromeBackground: Color {
        displayedBackground == nil ? Color.appGroupedBackground : .clear
    }

    private var showsFreeTimeEntry: Bool {
        preferences.showFreeTimeCourses && store.result != nil && !weeklyFreeCourses().isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Keep the controls pinned while the timetable is being swiped.
            // The Web version treats this region as chrome outside its pager.
            if let result = store.result {
                scheduleHeader(result)
                    .padding(.horizontal, Self.contentInset)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                    .background(chromeBackground)
            }

            if showsFreeTimeEntry {
                freeTimeEntry(weeklyFreeCourses())
                    .padding(.horizontal, Self.contentInset)
                    .padding(.vertical, 8)
                    .background(chromeBackground)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    // A timetable already on screen is never replaced by a
                    // state card. Authorization and refresh problems appear as
                    // a banner above it instead.
                    if let result = store.result {
                        if isUnauthorized {
                            authorizationBanner
                                .padding(.horizontal, Self.contentInset)
                        } else if !isLoading, let message = errorMessage {
                            errorBanner(message)
                                .padding(.horizontal, Self.contentInset)
                        }

                        let adjustments = visibleAdjustments(result)
                        if !adjustments.isEmpty {
                            adjustmentBanner(adjustments)
                                .padding(.horizontal, Self.contentInset)
                        }

                        switch viewMode {
                        case .week:
                            weekGrid(result)
                        case .day:
                            dayGrid(result)
                        case .month:
                            monthCalendar(result)
                        }
                    } else if isUnauthorized {
                        authorizationState
                            .padding(.horizontal, Self.contentInset)
                    } else if isLoading {
                        loadingState
                            .padding(.horizontal, Self.contentInset)
                    } else if let message = errorMessage {
                        errorState(message)
                            .padding(.horizontal, Self.contentInset)
                    } else {
                        loadingState
                            .padding(.horizontal, Self.contentInset)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(chromeBackground.ignoresSafeArea(.container, edges: [.horizontal, .bottom]))
            }
            // Keep slot heights stable when the pinned free-time entry changes.
            // Smaller screens scroll to the final period instead of squeezing text.
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: showsFreeTimeEntry)
        .environment(\.scheduleHasBackgroundImage, displayedBackground != nil)
        .background {
            ZStack {
                Color.appGroupedBackground
                if let image = displayedBackground {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFill()
                        .opacity(preferences.backgroundOpacity(dark: colorScheme == .dark))
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            }
            .ignoresSafeArea()
        }
        .task {
            viewMode = SurfaceViewMode(rawValue: preferences.defaultView) ?? .week
            adoptSelectionIfNeeded()
            if viewMode == .month { seedMonthSelection(store.result) }
            #if DEBUG
            // A headless simulator has no window server, so a surface that only
            // opens on a tap cannot be screenshotted. CpuTime solves the same
            // problem with `CPU_DEBUG_TAB`; this is the NapTable equivalent.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                applyDebugSheetIfNeeded()
            }
            #endif
        }
        .refreshable {
            await store.refresh()
        }
        .onChange(of: store.result?.currentSemester) { _, _ in
            adoptSelectionIfNeeded()
        }
        .onChange(of: store.result?.currentWeek) { _, _ in
            adoptSelectionIfNeeded()
        }
        .onChange(of: store.selectedWeek) { _, _ in
            guard !weekPaging, !dayPaging else { return }
            finishMonthDaySelectionIfReady()
            if pendingMonthDay == nil, !visibleDays.contains(selectedDay) { selectedDay = visibleDays.last ?? 1 }
            resetPagerSelections()
        }
        .onChange(of: store.calendar) { _, _ in
            finishMonthDaySelectionIfReady()
        }
        .onChange(of: preferences.showWeekend) { _, _ in
            // Hiding the weekend while 周六/周日 is selected would leave the day
            // view pointing at a column that is no longer drawn.
            if !visibleDays.contains(selectedDay) { selectedDay = visibleDays.last ?? 1 }
            resetPagerSelections()
        }
        .onChange(of: viewMode) { _, mode in
            resetPagerSelections()
            // 进入月视图时跟随当前浏览到的那一天，而不是停在上次翻到的月份。
            if mode == .month { seedMonthSelection(store.result, reset: true) }
        }
        .onDisappear {
            weekTransitionToken &+= 1
            dayTransitionToken &+= 1
            weekPaging = false
            dayPaging = false
        }
        .sheet(item: $selectedCourse) { selection in
            Group {
                if store.isReadOnly {
                    SharedCourseDetailView(course: selection.course)
                } else {
                    NativeCourseEditorSheet(selection: selection, store: store)
                }
            }
                .appSheetDetents([.large])
                .appDragIndicatorVisible()
        }
        .sheet(item: $addCourseContext) { context in
            NativeCourseEditorSheet(
                selection: nil,
                store: store,
                defaultDay: context.day,
                defaultWeek: context.week,
                defaultStartSlot: context.startSlot
            )
            .appSheetDetents([.large])
            .appDragIndicatorVisible()
        }
        .sheet(isPresented: $weekPickerPresented) {
            weekPicker
                .appSheetDetents([.medium, .large])
        }
        .sheet(isPresented: $freeCoursesPresented) {
            freeTimeSheet()
                .appSheetDetents([.medium, .large])
                .appDragIndicatorVisible()
        }
        #if DEBUG && os(iOS)
        .fullScreenCover(item: $debugCropImage) { item in
            NavigationStack {
                // 调试截图用：不透明度只在这一页里变，摆放也不写回设置。
                BackgroundCropEditor(image: item.image, initialPlacement: item.placement,
                                     opacity: $debugCropOpacity,
                                     onDone: { debugCropImage = nil }, onCommit: { _, _ in })
            }
        }
        #endif
        .alert("教务课表已更新", isPresented: scheduleChangeNoticePresented) {
            Button("我知道了") { store.dismissScheduleChangeNotice() }
        } message: {
            Text(scheduleChangeNoticeMessage)
        }
    }

    private var isLoading: Bool {
        store.state == .loading
    }

    private var isUnauthorized: Bool {
        store.state == .unauthorized
    }

    private var errorMessage: String? {
        let value = store.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private var scheduleChangeNoticePresented: Binding<Bool> {
        Binding(
            get: { store.scheduleChangeNotice != nil },
            set: { if !$0 { store.dismissScheduleChangeNotice() } }
        )
    }

    private var scheduleChangeNoticeMessage: String {
        store.scheduleChangeNotice?.details.joined(separator: "\n")
            ?? "教务原始课表发生了变化，请重新核对课程安排。"
    }

    /// NapTable also stores courses with no fixed weekday ("自由时间课程").
    /// CpuTime has no such concept, so instead of dropping them they get their
    /// own opaque entry pinned above the scrolling timetable.
    private func weeklyFreeCourses() -> [NativeScheduleCourse] {
        let week = weekNumber(store.selectedWeek)
        return store.freeCourses.filter { course in
            guard let week else { return true }
            return course.weekList.isEmpty || course.weekList.contains(week)
        }
    }

    private func freeTimeEntry(_ courses: [NativeScheduleCourse]) -> some View {
        Button {
            freeCoursesPresented = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "clock.badge.questionmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.cpuBrand)
                VStack(alignment: .leading, spacing: 2) {
                    Text("有 \(courses.count) 门自由时间课程")
                        .font(.subheadline.weight(.semibold))
                    Text("点击查看安排")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            // A plain card, not glass: this row is a NapTable addition, and the
            // glass material belongs to the CpuTime controls around the grid.
            .background(ScheduleCardSurface(hasBackground: displayedBackground != nil))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel("有 \(courses.count) 门自由时间课程，点击查看安排")
    }

    private func freeTimeSheet() -> some View {
        NavigationStack {
            List {
                Section {
                    ForEach(weeklyFreeCourses()) { course in
                        Button {
                            selectedCourse = SelectedCourse(course: course, day: 0, bigSlot: 0, startSlot: 0, endSlot: 0)
                            freeCoursesPresented = false
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(course.name)
                                    .font(.body.weight(.semibold))
                                if let weeks = course.weeks.nilIfEmpty {
                                    Text(weeks).font(.caption).foregroundStyle(.secondary)
                                }
                                if let teacher = course.teacher?.trimmedNonEmpty {
                                    Text(teacher).font(.caption).foregroundStyle(.secondary)
                                }
                                if let location = course.location?.trimmedNonEmpty {
                                    Text(location).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("这些课程没有固定星期，不会出现在课表网格里。")
                }
            }
            .navigationTitle("自由时间课程")
            .appInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .appTrailing) {
                    Button("完成") { freeCoursesPresented = false }
                }
            }
        }
    }

    private func scheduleHeader(_ result: NativeScheduleResult) -> some View {
        // 三种视图共用同一个行距，否则切到日视图时上面的周次那行会跳 4pt。
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                semesterMenu(result)
                    .frame(maxWidth: .infinity)

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在更新课表")
                }

                if showsWatch {
                    Button(action: onWatch) {
                        Image(systemName: "applewatch")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .modifier(ScheduleGlassControl(cornerRadius: 17))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .accessibilityLabel("Apple Watch 课表同步")
                }

                Picker("课表视图", selection: $viewMode) {
                    // Keep the same order as Web's view switch: 日 / 周，月历接在后面。
                    Text("日").tag(SurfaceViewMode.day)
                    Text("周").tag(SurfaceViewMode.week)
                    Text("月").tag(SurfaceViewMode.month)
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .frame(width: 120)
                .accessibilityLabel("切换课表视图")

                Button {
                    switch viewMode {
                    case .day: jumpToCurrentDay(result)
                    case .week: jumpToCurrentWeek(result)
                    case .month: jumpToCurrentMonth()
                    }
                } label: {
                    Image(systemName: "location.north.line")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .modifier(ScheduleGlassControl(cornerRadius: 17))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .accessibilityLabel(jumpButtonLabel)
                .disabled(isViewingCurrentPosition(result))

                scheduleToolsMenu(result)
            }

            // 月视图翻的是月份，周导航在这里换成月份导航。
            if viewMode == .month {
                monthNavigator()
            } else {
                weekNavigator(result)
            }

            // Web's day view keeps the week navigator and the seven-day strip
            // as separate controls. The strip is the compact day selector;
            // the grid below can therefore start directly at the first slot.
            if viewMode == .day {
                dayPicker(result)
            }

        }
    }

    private func weekNavigator(_ result: NativeScheduleResult) -> some View {
        HStack(spacing: 6) {
            weekStepButton(
                systemName: "chevron.left",
                label: "上一周",
                enabled: canMoveWeek(-1, result: result)
            ) {
                moveWeek(-1, result: result)
            }

            Button {
                weekPickerPresented = true
            } label: {
                VStack(spacing: 2) {
                    Text(weekTitle(result))
                        .font(.headline)
                        .lineLimit(1)
                    if let range = weekRange(result), !range.isEmpty {
                        Text(range)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 42)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("选择周次")

            weekStepButton(
                systemName: "chevron.right",
                label: "下一周",
                enabled: canMoveWeek(1, result: result)
            ) {
                moveWeek(1, result: result)
            }
        }
    }

    private func monthNavigator() -> some View {
        HStack(spacing: 6) {
            weekStepButton(systemName: "chevron.left", label: "上一月", enabled: true) {
                moveMonth(-1)
            }

            VStack(spacing: 2) {
                Text(monthTitle)
                    .font(.headline)
                    .lineLimit(1)
                if let lunar = ChineseCalendarInfo.info(forDate: monthAnchor)?.lunar.yearLabel {
                    Text("农历\(lunar)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 42)

            weekStepButton(systemName: "chevron.right", label: "下一月", enabled: true) {
                moveMonth(1)
            }
        }
    }

    private func semesterMenu(_ result: NativeScheduleResult) -> some View {
        let selected = result.semesters.first { $0.value == store.selectedSemester }
        let own = result.semesters.filter { !$0.isShared }
        let shared = result.semesters.filter(\.isShared)
        let selection = Binding(
            get: { store.selectedSemester },
            set: { value in
                guard value != store.selectedSemester else { return }
                Task { await store.selectSemester(value) }
            }
        )
        return Menu {
            // An inline Picker lets the system draw the checkmark column, so
            // every name lines up whether or not it is selected.
            Picker("课表", selection: selection) {
                Section("我的课表") {
                    ForEach(own) { Text($0.label).tag($0.value) }
                }
                if !shared.isEmpty {
                    Section("共享课表") {
                        ForEach(shared) {
                            Label($0.label, systemImage: "person.2").tag($0.value)
                        }
                    }
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("添加课表", systemImage: "plus", action: onAddTable)
        } label: {
            HStack(spacing: 6) {
                if selected?.isShared == true {
                    Image(systemName: "person.2.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(semesterTitle(result))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            // Reserve the available header width regardless of the selected name.
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(ScheduleCardSurface(hasBackground: displayedBackground != nil), in: Capsule())
        }
        // A source change may also animate the free-time entry below the header.
        // Keep the menu's anchor and label out of that layout animation.
        .transaction { $0.animation = nil }
        .accessibilityLabel("选择课表")
        .accessibilityValue(selected.map { $0.isShared ? "共享课表 \($0.label)" : $0.label } ?? "")
    }

    /// Harmony's schedule surface keeps refresh, editing and presentation
    /// choices in one overflow menu. The iOS header exposes the same groups
    /// without making a companion-device entry carry unrelated work.
    private func scheduleToolsMenu(_ result: NativeScheduleResult) -> some View {
        Menu {
            Section("课表") {
                Button("选择周次", systemImage: "calendar") { weekPickerPresented = true }
                Button("添加课程", systemImage: "plus") {
                    presentAddCourse(
                        day: selectedDay,
                        week: Int(store.selectedWeek),
                        startSlot: 1
                    )
                }
                .disabled(store.isReadOnly)
                if showsFreeTimeEntry {
                    Button("自由时间", systemImage: "clock.badge.checkmark") {
                        freeCoursesPresented = true
                    }
                }
            }
            Section("分享") {
                Button("分享当前课表", systemImage: "square.and.arrow.up") {
                    exportScheduleImage(result)
                }
                Button("导出本周日历", systemImage: "calendar.badge.plus") {
                    exportCurrentWeek(result)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 34, height: 34)
                .modifier(ScheduleGlassControl(cornerRadius: 17))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel("更多课表操作")
    }

    private func weekStepButton(
        systemName: String,
        label: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if systemName == "chevron.right" {
                    Text(label)
                    Image(systemName: systemName)
                } else {
                    Image(systemName: systemName)
                    Text(label)
                }
            }
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(minWidth: 68, minHeight: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .primary : .tertiary)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    /// 日视图的星期条：一行「星期 + 日期圆点」，选中项用品牌色实心圆，今天是描边圆，
    /// 有课的那天在下面点一个小点。比原来的方框 + 「周一 09.15」两行文字清爽得多。
    private func dayPicker(_ result: NativeScheduleResult) -> some View {
        let week = weekNumber(store.selectedWeek)
        return HStack(spacing: 2) {
            ForEach(visibleDays, id: \.self) { day in
                let isSelected = selectedDay == day
                let isToday = dayIsToday(day, week: week, result: result)
                let hasCourses = !blocks(for: day, week: week, result: result).isEmpty
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        selectedDay = day
                        if let date = rawDayDate(day, week: week, result: result) {
                            selectedMonthDate = date
                            monthAnchor = date
                        }
                    }
                } label: {
                    VStack(spacing: 5) {
                        Text(dayShortLabel(day))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(dayStripLabelColor(day, isSelected: isSelected))
                            .lineLimit(1)

                        ZStack {
                            Circle()
                                .fill(isSelected ? Color.cpuBrand : Color.clear)
                            if isToday && !isSelected {
                                Circle()
                                    .strokeBorder(Color.cpuBrand.opacity(0.55), lineWidth: 1)
                            }
                            Text(dayNumber(day, week: week, result: result) ?? "–")
                                .font(.system(size: 15, weight: isSelected || isToday ? .semibold : .regular, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(isSelected ? Color.white : (isToday ? Color.cpuBrand : Color.primary))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(width: 32, height: 32)

                        Circle()
                            .fill(isSelected ? Color.cpuBrand : Color.cpuBrand.opacity(0.4))
                            .frame(width: 4, height: 4)
                            .opacity(hasCourses ? 1 : 0)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(dayLabel(day)) \(dayDate(day, week: week, result: result) ?? "")")
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
            }
        }
        .padding(.top, 2)
    }

    private func dayStripLabelColor(_ day: Int, isSelected: Bool) -> Color {
        if isSelected { return Color.cpuBrand }
        return day >= 6 ? Color.pink.opacity(0.75) : Color.secondary
    }

    private func weekGrid(_ result: NativeScheduleResult) -> some View {
        let rowHeight = weekGridRowHeight
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                let contentWidth = proxy.size.width - 2 * Self.contentInset
                weekPager(result: result, width: proxy.size.width, rowHeight: rowHeight) { week in
                    let days = visibleDays(week: week, result: result)
                    let dayCount = CGFloat(days.count)
                    let columnWidth = max(
                        24,
                        (contentWidth - Self.slotAxisWidth - (dayCount - 1) * Self.columnGap) / dayCount
                    )
                    scheduleRows(
                        result: result,
                        week: week,
                        days: days,
                        columnWidth: columnWidth,
                        compactCards: preferences.density == "compact",
                        rowHeight: rowHeight,
                        showsDateHeader: preferences.showDateHeader
                    )
                        .frame(minWidth: contentWidth, alignment: .leading)
                        .padding(.horizontal, Self.contentInset)
                }
            }
            .frame(height: Self.scheduleGridHeight(
                rowHeight: rowHeight,
                slotCount: slotCount(week: weekNumber(store.selectedWeek), result: result),
                includesDateHeader: preferences.showDateHeader
            ))
        }
    }

    private func dayGrid(_ result: NativeScheduleResult) -> some View {
        let rowHeight = dayGridRowHeight
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                let contentWidth = proxy.size.width - 2 * Self.contentInset
                let columnWidth = max(220, contentWidth - Self.slotAxisWidth - Self.columnGap)
                dayPager(result: result, width: proxy.size.width, rowHeight: rowHeight) { page in
                    scheduleRows(
                        result: result,
                        week: page.week.flatMap(Int.init),
                        days: [page.day],
                        columnWidth: columnWidth,
                        compactCards: preferences.density == "compact",
                        rowHeight: rowHeight,
                        showsDateHeader: false
                    )
                    .frame(width: contentWidth, alignment: .leading)
                    .padding(.horizontal, Self.contentInset)
                }
            }
            .frame(height: Self.scheduleGridHeight(
                rowHeight: rowHeight,
                slotCount: slotCount(week: weekNumber(store.selectedWeek), result: result),
                includesDateHeader: false
            ))
        }
    }

    // MARK: 月视图

    private func monthCalendar(_ result: NativeScheduleResult) -> some View {
        NativeScheduleMonthView(
            monthAnchor: monthAnchor.isEmpty ? (Self.todayDate ?? "") : monthAnchor,
            selectedDate: selectedMonthDate,
            todayDate: Self.todayDate,
            dateIndex: monthDateIndex,
            blocks: { day, week in blocks(for: day, week: week, result: result) },
            adjustments: store.calendar?.adjustments ?? [:],
            onSelect: { date in
                selectMonthDate(date, result: result)
            },
            onOpenDay: { date in
                openDayView(date)
            },
            onCourseSelected: { block, date in
                guard let slot = monthDateIndex[date] else { return }
                let effective = effectiveSlot(day: slot.day, week: slot.week, result: result)
                selectedCourse = SelectedCourse(
                    course: block.course,
                    day: effective.day,
                    bigSlot: block.bigSlot,
                    startSlot: block.startSlot,
                    endSlot: block.endSlot
                )
            }
        )
    }

    /// 日期 -> 教学周与星期几。学期日历之外的日期查不到，月历会把它当成非教学日。
    private var monthDateIndex: [String: NativeScheduleMonthView.DaySlot] {
        guard let calendar = store.calendar else { return [:] }
        var index: [String: NativeScheduleMonthView.DaySlot] = [:]
        for week in calendar.weeks {
            for (offset, date) in week.days.enumerated() where !date.isEmpty {
                index[date] = NativeScheduleMonthView.DaySlot(week: week.week, day: offset + 1)
            }
        }
        return index
    }

    private var monthTitle: String {
        let anchor = monthAnchor.isEmpty ? (Self.todayDate ?? "") : monthAnchor
        let pieces = anchor.split(separator: "-")
        guard pieces.count >= 2, let year = Int(pieces[0]), let month = Int(pieces[1]) else { return anchor }
        return "\(year) 年 \(month) 月"
    }

    private func moveMonth(_ offset: Int) {
        let anchor = monthAnchor.isEmpty ? (Self.todayDate ?? "") : monthAnchor
        guard let date = ChineseCalendarInfo.date(fromDate: anchor),
              let moved = ChineseCalendarInfo.gregorian.date(byAdding: .month, value: offset, to: date) else {
            return
        }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            monthAnchor = ChineseCalendarInfo.dateString(moved)
        }
    }

    /// 月视图打开某一天：切到日视图，必要时先把周次切过去。
    private func openDayView(_ date: String) {
        guard monthDateIndex[date] != nil, let result = store.result else { return }
        selectMonthDate(date, result: result)
        viewMode = .day
    }

    private func selectMonthDate(_ date: String, result: NativeScheduleResult) {
        selectedMonthDate = date
        pendingMonthDay = nil
        guard let slot = monthDateIndex[date] else { return }
        let days = visibleDays(week: slot.week, result: result)
        guard days.contains(slot.day) else { return }
        didInitializeDay = true
        if store.selectedWeek == String(slot.week) {
            selectedDay = slot.day
            resetPagerSelections()
        } else {
            pendingMonthDay = date
            selectedDay = slot.day
            store.commitWeekSelection(String(slot.week))
        }
    }

    private func finishMonthDaySelectionIfReady() {
        guard let date = pendingMonthDay,
              let slot = monthDateIndex[date], String(slot.week) == store.selectedWeek,
              let week = store.calendar?.weeks.first(where: { $0.week == slot.week }),
              week.days.indices.contains(slot.day - 1), week.days[slot.day - 1] == date else { return }
        selectedDay = slot.day
        pendingMonthDay = nil
    }

    private func jumpToCurrentMonth() {
        guard let today = Self.todayDate else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            selectedMonthDate = today
            monthAnchor = today
        }
        if let result = store.result { selectMonthDate(today, result: result) }
    }

    /// 进入月视图时，先跟随当前浏览到的那一天；它不在学期里就退回今天。
    private func seedMonthSelection(_ result: NativeScheduleResult?, reset: Bool = false) {
        let browsing = result.flatMap { rawDayDate(selectedDay, week: weekNumber(store.selectedWeek), result: $0) }
        let fallback = browsing ?? Self.todayDate ?? ChineseCalendarInfo.dateString(.now)
        if reset || selectedMonthDate.isEmpty { selectedMonthDate = fallback }
        if reset || monthAnchor.isEmpty { monthAnchor = selectedMonthDate }
    }

    private var jumpButtonLabel: String {
        switch viewMode {
        case .day: return "跳转到今日"
        case .week: return "回到本周"
        case .month: return "回到本月"
        }
    }

    private func isViewingCurrentPosition(_ result: NativeScheduleResult) -> Bool {
        switch viewMode {
        case .day: return isViewingCurrentDay(result)
        case .week: return isViewingCurrentWeek(result) && isSelectionToday
        case .month:
            guard let today = Self.todayDate else { return true }
            return selectedMonthDate == today && monthAnchor.prefix(7) == today.prefix(7)
        }
    }

    private var isSelectionToday: Bool {
        guard let today = Self.todayDate else { return true }
        return selectedMonthDate == today && monthAnchor.prefix(7) == today.prefix(7)
            && selectedDay == Self.chinaWeekday
    }

    /// 每周独立判断调休日和周末课程，翻页时不会漏掉相邻周的周末安排。
    private var visibleDays: [Int] {
        guard let result = store.result else { return preferences.visibleDays }
        return visibleDays(week: weekNumber(store.selectedWeek), result: result)
    }

    private func visibleDays(week: Int?, result: NativeScheduleResult) -> [Int] {
        let pinnedDays = Set((6...7).filter {
            adjustment(day: $0, week: week, result: result) != nil
                || !blocks(for: $0, week: week, result: result).isEmpty
        })
        return preferences.visibleDays(pinnedDays: pinnedDays)
    }

    /// 这一周要画几行。按整周最晚的一节课算，同一周翻到哪天行数都不变。
    private func slotCount(week: Int?, result: NativeScheduleResult) -> Int {
        let lastOccupied = (1...7)
            .flatMap { blocks(for: $0, week: week, result: result) }
            .map(\.endSlot)
            .max() ?? 0
        return preferences.visibleSlotCount(total: ScheduleSlot.all.count, lastOccupiedSlot: lastOccupied)
    }

    /// 还没有课表数据时（加载中）按没有课算。
    private var emptySlotCount: Int {
        preferences.visibleSlotCount(total: ScheduleSlot.all.count, lastOccupiedSlot: 0)
    }

    private var weekGridRowHeight: CGFloat {
        switch preferences.density {
        case "compact": 40
        case "relaxed": 52
        default: NativeScheduleDayColumn.slotHeight
        }
    }

    /// The day layout carries an extra weekday picker above the grid, so it
    /// keeps the same 3pt deficit it had when both heights were constants.
    private var dayGridRowHeight: CGFloat {
        switch preferences.density {
        case "compact": 37
        case "relaxed": 49
        default: NativeScheduleDayColumn.daySlotHeight
        }
    }

    /// Daily mode uses the same native page controller as the weekly pager. A
    /// page is one day; crossing Sunday/Monday commits the adjacent week after
    /// the system animation has carried the page off screen.
    private func dayPager<Page: View>(
        result: NativeScheduleResult,
        width: CGFloat,
        rowHeight: CGFloat = NativeScheduleDayColumn.daySlotHeight,
        @ViewBuilder page: @escaping (NativeScheduleDayPage) -> Page
    ) -> some View {
        let previous = adjacentDayPage(-1, result: result)
        let current = NativeScheduleDayPage(week: store.selectedWeek.nilIfEmpty, day: selectedDay)
        let next = adjacentDayPage(1, result: result)
        return TabView(selection: $dayPageSelection) {
            dayPagerPage(id: 0, value: previous, width: width, rowHeight: rowHeight, page: page)
            dayPagerPage(id: 1, value: current, width: width, rowHeight: rowHeight, page: page)
            dayPagerPage(id: 2, value: next, width: width, rowHeight: rowHeight, page: page)
        }
        .appPageTabViewStyle()
        .frame(width: width, alignment: .leading)
        .clipped()
        .onAppear { dayPageSelection = 1 }
        .onChange(of: dayPageSelection) { _, selection in
            handleDayPageSelection(selection, result: result)
        }
    }

    @ViewBuilder
    private func dayPagerPage<Page: View>(
        id: Int,
        value: NativeScheduleDayPage?,
        width: CGFloat,
        rowHeight: CGFloat,
        @ViewBuilder page: @escaping (NativeScheduleDayPage) -> Page
    ) -> some View {
        Group {
            if let value {
                page(value)
                    .frame(width: width, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                Color.clear
                    .frame(width: width, height: Self.scheduleGridHeight(rowHeight: rowHeight, includesDateHeader: false))
            }
        }
        .tag(id)
        .accessibilityHidden(id != 1)
    }

    /// The system page style owns the horizontal pan, rubber-banding and
    /// velocity curve. Only the semantic selection is committed here, after a
    /// short delay that lets the native page finish its visible transition.
    private func weekPager<Page: View>(
        result: NativeScheduleResult,
        width: CGFloat,
        rowHeight: CGFloat = NativeScheduleDayColumn.slotHeight,
        @ViewBuilder page: @escaping (Int?) -> Page
    ) -> some View {
        let previous = adjacentWeekValue(-1, result: result).flatMap(weekNumber)
        let current = weekNumber(store.selectedWeek)
        let next = adjacentWeekValue(1, result: result).flatMap(weekNumber)
        return TabView(selection: $weekPageSelection) {
            weekPagerPage(id: 0, value: previous, width: width, rowHeight: rowHeight, page: page)
            weekPagerPage(id: 1, value: current, width: width, rowHeight: rowHeight, page: page)
            weekPagerPage(id: 2, value: next, width: width, rowHeight: rowHeight, page: page)
        }
        .appPageTabViewStyle()
        .frame(width: width, alignment: .leading)
        .clipped()
        .onAppear { weekPageSelection = 1 }
        .onChange(of: weekPageSelection) { _, selection in
            handleWeekPageSelection(selection, result: result)
        }
    }

    @ViewBuilder
    private func weekPagerPage<Page: View>(
        id: Int,
        value: Int?,
        width: CGFloat,
        rowHeight: CGFloat,
        @ViewBuilder page: @escaping (Int?) -> Page
    ) -> some View {
        Group {
            if let value {
                page(value)
                    .frame(width: width, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                Color.clear
                    .frame(width: width, height: Self.scheduleGridHeight(rowHeight: rowHeight))
            }
        }
        .tag(id)
        .accessibilityHidden(id != 1)
    }

    private func handleWeekPageSelection(_ selection: Int, result: NativeScheduleResult) {
        guard selection != 1, !weekPaging, selectedCourse == nil, addCourseContext == nil else { return }
        let direction = selection == 2 ? 1 : -1
        guard let target = adjacentWeekValue(direction, result: result) else {
            resetPagerSelections()
            return
        }
        weekPaging = true
        weekTransitionToken &+= 1
        let token = weekTransitionToken
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, token == weekTransitionToken else { return }
            store.commitWeekSelection(target)
            if !visibleDays.contains(selectedDay) { selectedDay = visibleDays.last ?? 1 }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                weekPageSelection = 1
                weekPaging = false
            }
        }
    }

    private func handleDayPageSelection(_ selection: Int, result: NativeScheduleResult) {
        guard selection != 1, !dayPaging, selectedCourse == nil, addCourseContext == nil else { return }
        let direction = selection == 2 ? 1 : -1
        guard let target = adjacentDayPage(direction, result: result) else {
            resetPagerSelections()
            return
        }
        dayPaging = true
        dayTransitionToken &+= 1
        let token = dayTransitionToken
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, token == dayTransitionToken else { return }
            if let week = target.week, week != store.selectedWeek {
                store.commitWeekSelection(week)
            }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                selectedDay = target.day
                if let date = rawDayDate(target.day, week: target.week.flatMap(Int.init), result: result) {
                    selectedMonthDate = date
                    monthAnchor = date
                }
                dayPageSelection = 1
                dayPaging = false
            }
        }
    }

    private func resetPagerSelections() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            weekPageSelection = 1
            dayPageSelection = 1
        }
    }

    private func scheduleRows(
        result: NativeScheduleResult,
        week: Int?,
        days: [Int],
        columnWidth: CGFloat,
        compactCards: Bool,
        rowHeight: CGFloat = NativeScheduleDayColumn.slotHeight,
        showsDateHeader: Bool = true
    ) -> some View {
        let slotCount = slotCount(week: week, result: result)
        return HStack(alignment: .top, spacing: Self.columnGap) {
            slotAxis(rowHeight: rowHeight, slotCount: slotCount, showsHeader: showsDateHeader)

            ForEach(days, id: \.self) { day in
                let slot = effectiveSlot(day: day, week: week, result: result)
                NativeScheduleDayColumn(
                    day: day,
                    dateText: dayDate(day, week: week, result: result),
                    isToday: dayIsToday(day, week: week, result: result),
                    adjustment: adjustment(day: day, week: week, result: result),
                    columnWidth: columnWidth,
                    rowHeight: rowHeight,
                    slotCount: slotCount,
                    compactCards: compactCards,
                    showsDateHeader: showsDateHeader,
                    blocks: blocks(for: day, week: week, result: result),
                    onCourseSelected: { block in
                        selectedCourse = SelectedCourse(
                            course: block.course,
                            day: slot.day,
                            bigSlot: block.bigSlot,
                            startSlot: block.startSlot,
                            endSlot: block.endSlot
                        )
                    },
                    onEmptySlot: { value in
                        presentAddCourse(day: slot.day, week: slot.week, startSlot: value)
                    }
                )
            }
        }
    }

    private func slotAxis(
        rowHeight: CGFloat = NativeScheduleDayColumn.slotHeight,
        slotCount: Int = ScheduleSlot.all.count,
        showsHeader: Bool = true
    ) -> some View {
        VStack(spacing: 0) {
            if showsHeader {
                Text("节次")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.slotAxisWidth, height: NativeScheduleDayColumn.dateHeaderHeight)
            }

            VStack(spacing: NativeScheduleDayColumn.slotGap) {
                ForEach(ScheduleSlot.all.prefix(slotCount), id: \.number) { slot in
                    VStack(spacing: 2) {
                        Text("\(slot.number)")
                            .font(.caption.weight(.bold).monospacedDigit())
                        Text(slot.start)
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(slot.end)
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: Self.slotAxisWidth, height: rowHeight)
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(Color.appSeparator.opacity(0.5))
                            .frame(width: 0.5)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// 日视图显示当天的调休详情；周、月视图只保留日期角标。
    private func visibleAdjustments(_ result: NativeScheduleResult) -> [ResolvedCalendarAdjustment] {
        guard let calendar = store.calendar, !calendar.adjustments.isEmpty else { return [] }
        let week = weekNumber(store.selectedWeek)
        switch viewMode {
        case .day:
            return [adjustment(day: selectedDay, week: week, result: result)].compactMap { $0 }
        case .week, .month:
            return []
        }
    }

    private func adjustmentBanner(_ adjustments: [ResolvedCalendarAdjustment]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "calendar.badge.exclamationmark")
                .foregroundStyle(Color.orange)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(adjustments) { item in
                    Text(adjustmentLine(item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// 「10.11 周六 · 上 10.9 周四的课」
    private func adjustmentLine(_ value: ResolvedCalendarAdjustment) -> String {
        var head = shortDate(value.date)
        if let date = WeekCalculator.parseDay(value.date) {
            head += " " + WeekCalculator.weekdayName(WeekCalculator.weekday(date))
        }
        return "\(head) · \(value.detail)"
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var loadingState: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("课表").font(.title2.bold())
                Spacer()
                ProgressView().controlSize(.small)
                Text("正在同步课表").font(.caption).foregroundStyle(.secondary)
            }
            .frame(minHeight: 34)

            Text("课程安排加载后会显示在这里")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 42)

            GeometryReader { proxy in
                HStack(alignment: .top, spacing: 0) {
                    slotAxis(rowHeight: weekGridRowHeight, slotCount: emptySlotCount)
                    ForEach(visibleDays, id: \.self) { day in
                        NativeScheduleDayColumn(
                            day: day,
                            dateText: nil,
                            isToday: day == Self.chinaWeekday,
                            adjustment: nil,
                            columnWidth: max(1, (proxy.size.width - Self.slotAxisWidth) / CGFloat(visibleDays.count)),
                            rowHeight: weekGridRowHeight,
                            slotCount: emptySlotCount,
                            compactCards: true,
                            showsDateHeader: true,
                            blocks: [],
                            onCourseSelected: { _ in },
                            onEmptySlot: { _ in }
                        )
                    }
                }
            }
            .frame(height: Self.scheduleGridHeight(rowHeight: weekGridRowHeight, slotCount: emptySlotCount))
            .accessibilityHidden(true)
        }
    }

    private var authorizationBanner: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "lock")
                .foregroundStyle(.orange)
            Text(errorMessage ?? "教务授权已失效，课表可能不是最新的")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("去登录", action: onLogin)
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Color.cpuBrand)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var authorizationState: some View {
        StateCard(
            systemImage: "lock",
            title: "需要教务授权",
            message: "登录教务后，原生课表才能读取课程安排",
            actionTitle: "去登录",
            action: onLogin,
            showsProgress: false
        )
    }

    private func errorState(_ message: String) -> some View {
        StateCard(
            systemImage: "exclamationmark.triangle",
            title: "课表读取失败",
            message: message,
            actionTitle: "重试",
            action: refresh,
            showsProgress: false
        )
    }

    private var weekPicker: some View {
        NavigationStack {
            ScrollView {
                if let result = store.result, !result.weeks.isEmpty {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5),
                        spacing: 8
                    ) {
                        ForEach(result.weeks, id: \.value) { week in
                            let isSelected = week.value == store.selectedWeek
                            let isCurrent = Int(week.value) == store.calendar?.currentWeek
                            Button {
                                weekPickerPresented = false
                                Task { await store.selectWeek(week.value) }
                            } label: {
                                Text(week.value)
                                    .font(.subheadline.weight(.medium))
                                    .frame(maxWidth: .infinity, minHeight: 40)
                                .foregroundStyle(isSelected ? Color.white : (isCurrent ? Color.cpuBrand : .primary))
                                    .background {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(isSelected ? Color.cpuBrand : Color.appSecondaryGroupedBackground)
                                    }
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(isCurrent && !isSelected ? Color.cpuBrand : Color.appSeparator.opacity(0.35), lineWidth: 1)
                                    }
                            }
                            .buttonStyle(.plain)
                            .disabled(isLoading)
                            .accessibilityLabel("第 \(week.value) 周")
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                } else {
                    Text("暂无可选周次")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 160)
                }
            }
            .scrollIndicators(.hidden)
            .navigationTitle("选择周次")
            .appInlineNavigationTitle()
            .toolbar {
                if let result = store.result, !isViewingCurrentPosition(result) {
                    ToolbarItem(placement: .appLeading) {
                        Button("回到本周") {
                            weekPickerPresented = false
                            jumpToCurrentWeek(result)
                        }
                    }
                }
                ToolbarItem(placement: .appTrailing) {
                    Button("完成") {
                        weekPickerPresented = false
                    }
                }
            }
        }
    }

    private func adoptSelectionIfNeeded() {
        guard let result = store.result else { return }
        if store.selectedSemester.isEmpty {
            store.selectedSemester = store.calendar?.currentSemester.nilIfEmpty ?? result.currentSemester
        }
        if store.selectedWeek.isEmpty {
            let currentWeek = store.calendar.map { $0.currentWeek }.flatMap { $0 > 0 ? String($0) : nil }
            store.selectedWeek = currentWeek ?? result.currentWeek
        }
        if !didInitializeDay {
            selectedDay = visibleDays.first(where: { dayIsToday($0, result: result) }) ?? visibleDays.first ?? 1
            didInitializeDay = true
        }
    }

    private func requestLoad(force: Bool = false) {
        let semester = store.selectedSemester.isEmpty ? nil : store.selectedSemester
        let week = store.selectedWeek.isEmpty ? nil : store.selectedWeek
        Task { @MainActor in
            await store.load(semester: semester, week: week, force: force)
        }
    }

    private func loadAsync(force: Bool = false) async {
        let semester = store.selectedSemester.isEmpty ? nil : store.selectedSemester
        let week = store.selectedWeek.isEmpty ? nil : store.selectedWeek
        await store.load(semester: semester, week: week, force: force)
    }

    private func refresh() {
        requestLoad(force: true)
    }

    /// Renders the currently visible grid into a shareable PNG. Ported from
    /// CpuTime 4.0, which replaced the plain-text share with the actual image.
    @MainActor
    private func exportScheduleImage(_ result: NativeScheduleResult) {
        let week = Int(store.selectedWeek) ?? Int(result.currentWeek) ?? 1
        let isDayView = viewMode == .day
        let canvasWidth: CGFloat = isDayView ? 620 : 980
        let gridWidth = canvasWidth - 48
        let exportDays = visibleDays
        let columnWidth = isDayView
            ? max(220, gridWidth - Self.slotAxisWidth - Self.columnGap)
            : max(
                72,
                (gridWidth - Self.slotAxisWidth - CGFloat(exportDays.count - 1) * Self.columnGap)
                    / CGFloat(exportDays.count)
            )
        let grid: AnyView
        if isDayView {
            grid = AnyView(
                scheduleRows(
                    result: result,
                    week: week,
                    days: [selectedDay],
                    columnWidth: columnWidth,
                    compactCards: false,
                    rowHeight: dayGridRowHeight,
                    showsDateHeader: false
                )
            )
        } else {
            grid = AnyView(
                scheduleRows(
                    result: result,
                    week: week,
                    days: exportDays,
                    columnWidth: columnWidth,
                    compactCards: false,
                    rowHeight: weekGridRowHeight,
                    showsDateHeader: preferences.showDateHeader
                )
            )
        }

        let content = VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("我上早八")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.cpuBrand)
                    Text("\(semesterTitle(result)) · 第 \(week) 周")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isDayView {
                    Text("\(dayLabel(selectedDay)) · \(dayDate(selectedDay, week: week, result: result) ?? "")")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else if let range = weekRange(result), !range.isEmpty {
                    Text(range)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            grid
        }
        .padding(24)
        .frame(width: canvasWidth, alignment: .leading)
        .background(Color.appGroupedBackground)

        guard let data = content.platformRenderedImageData() else { return }
        let suffix = isDayView ? "日课表" : "周课表"
        PlatformSharePresenter.present(
            data: data,
            fileName: "我上早八-第\(week)周-\(suffix).png",
            mimeType: "image/png"
        )
    }

    private func exportCurrentWeek(_ result: NativeScheduleResult) {
        guard let week = Int(store.selectedWeek), let calendar = store.calendar,
              let weekData = calendar.weeks.first(where: { $0.week == week }) else {
            return
        }
        let fileName = "课表-\(store.selectedSemester)-第\(week)周.ics"
        let ics = NativeScheduleICSExporter.make(
            result: result,
            week: weekData,
            periods: store.periods,
            adjustments: calendar.adjustments
        )
        PlatformSharePresenter.present(text: ics, fileName: fileName)
    }

    private func presentAddCourse(day: Int, week: Int?, startSlot: Int) {
        guard !store.isReadOnly else { return }
        addCourseContext = AddCourseContext(
            day: min(max(day, 1), 7),
            week: week ?? Int(store.selectedWeek) ?? 1,
            startSlot: min(max(startSlot, 1), ScheduleSlot.all.count)
        )
    }

    #if DEBUG
    /// Opens one of the surface's sheets from an environment variable so a
    /// headless simulator can screenshot it. Mirrors CpuTime's `CPU_DEBUG_TAB`.
    /// Usage: `SIMCTL_CHILD_NAPTABLE_DEBUG_SHEET=editor xcrun simctl launch …`
    private struct DebugCropImage: Identifiable {
        let id = UUID()
        let image: CGImage
        var placement = NativeSchedulePreferences.BackgroundPlacement()
    }

    private func applyDebugSheetIfNeeded() {
        guard let raw = ProcessInfo.processInfo.environment["NAPTABLE_DEBUG_SHEET"] else { return }
        switch raw {
        case "editor":
            presentAddCourse(day: 2, week: Int(store.selectedWeek) ?? 1, startSlot: 3)
        case "weekPicker":
            weekPickerPresented = true
        case "free":
            freeCoursesPresented = true
        case "crop":
            // 相册选择器没法在无界面模拟器里点，直接拿 NAPTABLE_DEBUG_CROP_IMAGE 指向的文件打开编辑页。
            guard let path = ProcessInfo.processInfo.environment["NAPTABLE_DEBUG_CROP_IMAGE"],
                  let data = FileManager.default.contents(atPath: path),
                  let image = BackgroundCropEditor.decode(data) else { return }
            debugCropOpacity = .init(light: preferences.backgroundOpacity, dark: preferences.backgroundOpacityDark)
            debugCropImage = DebugCropImage(image: image)
        case "recrop":
            // 和设置里的「调整位置和大小」一样：原图加上次的摆放。
            guard let data = preferences.backgroundSourceData(dark: colorScheme == .dark)
                    ?? preferences.backgroundSourceData(dark: colorScheme != .dark),
                  let image = BackgroundCropEditor.decode(data) else { return }
            debugCropOpacity = .init(light: preferences.backgroundOpacity, dark: preferences.backgroundOpacityDark)
            debugCropImage = DebugCropImage(image: image, placement: preferences.backgroundPlacement(dark: colorScheme == .dark))
        case "detail":
            guard let result = store.result else { return }
            for cell in result.cells {
                guard let course = cell.courses.first else { continue }
                selectedCourse = SelectedCourse(
                    course: course,
                    day: cell.day,
                    bigSlot: cell.bigSlot,
                    startSlot: course.startSlot ?? cell.bigSlot * 2 - 1,
                    endSlot: course.endSlot ?? cell.bigSlot * 2
                )
                return
            }
        default:
            break
        }
    }
    #endif

    private func moveWeek(_ offset: Int, result: NativeScheduleResult) {
        guard !weekPaging, let target = adjacentWeekValue(offset, result: result) else { return }
        guard viewMode == .week else {
            Task { await store.selectWeek(target) }
            return
        }
        guard let currentIndex = result.weeks.firstIndex(where: { $0.value == store.selectedWeek }),
              let targetIndex = result.weeks.firstIndex(where: { $0.value == target }) else { return }
        let selection = targetIndex > currentIndex ? 2 : 0
        withAnimation(.easeInOut(duration: 0.3)) {
            weekPageSelection = selection
        }
    }

    private func moveDay(_ offset: Int, result: NativeScheduleResult) {
        guard offset != 0, adjacentDayPage(offset, result: result) != nil, !dayPaging else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            dayPageSelection = offset > 0 ? 2 : 0
        }
    }

    private func adjacentDayPage(_ offset: Int, result: NativeScheduleResult) -> NativeScheduleDayPage? {
        guard offset != 0 else { return nil }
        let days = visibleDays
        let currentIndex = days.firstIndex(of: selectedDay) ?? 0
        let targetIndex = currentIndex + offset
        if days.indices.contains(targetIndex) {
            return NativeScheduleDayPage(week: store.selectedWeek.nilIfEmpty, day: days[targetIndex])
        }
        let weekOffset = offset > 0 ? 1 : -1
        guard let targetWeek = adjacentWeekValue(weekOffset, result: result) else { return nil }
        let targetDays = visibleDays(week: weekNumber(targetWeek), result: result)
        return NativeScheduleDayPage(week: targetWeek, day: offset > 0 ? (targetDays.first ?? 1) : (targetDays.last ?? 5))
    }

    private func adjacentWeekValue(_ offset: Int, result: NativeScheduleResult) -> String? {
        guard let currentIndex = result.weeks.firstIndex(where: { $0.value == store.selectedWeek }) else {
            return nil
        }
        let targetIndex = currentIndex + offset
        guard result.weeks.indices.contains(targetIndex) else { return nil }
        return result.weeks[targetIndex].value
    }

    private func jumpToCurrentWeek(_ result: NativeScheduleResult) {
        if let today = Self.todayDate {
            selectedMonthDate = today
            monthAnchor = today
        }
        pendingMonthDay = nil
        selectedDay = store.calendar?.weeks.first(where: { $0.week == store.calendar?.currentWeek })
            .flatMap { week in Self.todayDate.flatMap(week.days.firstIndex(of:)).map { $0 + 1 } }
            ?? Self.chinaWeekday
        didInitializeDay = true
        resetPagerSelections()
        guard !isViewingCurrentWeek(result) else { return }
        guard let calendar = store.calendar,
              calendar.currentWeek > 0,
              let semester = calendar.currentSemester.nilIfEmpty,
              let week = calendar.weeks.first(where: { $0.week == calendar.currentWeek }),
              let today = Self.todayDate,
              week.days.contains(today) else {
            store.selectedSemester = ""
            store.selectedWeek = ""
            selectedDay = Self.chinaWeekday
            didInitializeDay = true
            Task {
                await store.load(semester: nil, week: nil, force: true)
            }
            return
        }
        Task {
            await store.load(semester: semester, week: String(calendar.currentWeek), force: false)
        }
    }

    /// Daily mode has two independent selections: the teaching week and the
    /// weekday page. Returning to the current week alone left the selected
    /// weekday untouched, so the button became a no-op whenever another day
    /// in the same week was open.
    private func jumpToCurrentDay(_ result: NativeScheduleResult) {
        pendingMonthDay = nil
        if let today = Self.todayDate {
            selectedMonthDate = today
            monthAnchor = today
        }
        guard let calendar = store.calendar,
              calendar.currentWeek > 0,
              let semester = calendar.currentSemester.nilIfEmpty,
              let week = calendar.weeks.first(where: { $0.week == calendar.currentWeek }),
              let today = Self.todayDate else {
            selectedDay = Self.chinaWeekday
            didInitializeDay = true
            store.selectedSemester = ""
            store.selectedWeek = ""
            Task { await store.load(semester: nil, week: nil, force: true) }
            return
        }

        let targetDay = week.days.firstIndex(of: today).map { $0 + 1 } ?? Self.chinaWeekday
        let targetWeek = String(calendar.currentWeek)
        let sameWeek = store.selectedSemester == semester && store.selectedWeek == targetWeek

        guard sameWeek else {
            selectedDay = targetDay
            didInitializeDay = true
            Task { await store.load(semester: semester, week: targetWeek, force: false) }
            return
        }

        guard selectedDay != targetDay else { return }
        didInitializeDay = true
        // "返回今日" is a position reset, not a day swipe. Reusing the swipe
        // track here made a same-week jump animate in the wrong direction and
        // briefly exposed the neighbouring day. Commit every related state in
        // one animation-free transaction.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selectedDay = targetDay
            dayPageSelection = 1
        }
    }

    private func canMoveWeek(_ offset: Int, result: NativeScheduleResult) -> Bool {
        guard let currentIndex = result.weeks.firstIndex(where: { $0.value == store.selectedWeek }) else {
            return false
        }
        return result.weeks.indices.contains(currentIndex + offset)
    }

    private func isViewingCurrentWeek(_ result: NativeScheduleResult) -> Bool {
        guard let calendar = store.calendar,
              calendar.currentWeek > 0,
              let currentSemester = calendar.currentSemester.nilIfEmpty,
              let week = calendar.weeks.first(where: { $0.week == calendar.currentWeek }),
              let today = Self.todayDate,
              week.days.contains(today) else {
            return false
        }
        return store.selectedSemester == currentSemester && store.selectedWeek == String(calendar.currentWeek)
    }

    private func isViewingCurrentDay(_ result: NativeScheduleResult) -> Bool {
        guard isViewingCurrentWeek(result), dayIsToday(selectedDay, result: result) else { return false }
        return true
    }

    /// CpuTime switches semesters here; NapTable stores several course tables,
    /// so the same control selects the table.
    private func semesterTitle(_ result: NativeScheduleResult) -> String {
        result.semesters.first(where: { $0.value == store.selectedSemester })?.label
            ?? store.selectedSemester
            .nilIfEmpty
            ?? "选择课表"
    }

    private func weekTitle(_ result: NativeScheduleResult) -> String {
        if let label = result.weeks.first(where: { $0.value == store.selectedWeek })?.label, !label.isEmpty {
            return label
        }
        return store.selectedWeek.isEmpty ? "选择周次" : "第 \(store.selectedWeek) 周"
    }

    private func weekRange(_ result: NativeScheduleResult) -> String? {
        guard let weekNumber = Int(store.selectedWeek), let calendar = store.calendar,
              let item = calendar.weeks.first(where: { $0.week == weekNumber }) else {
            return nil
        }
        if !item.monday.isEmpty && !item.sunday.isEmpty {
            return "\(shortDate(item.monday)) - \(shortDate(item.sunday))"
        }
        return nil
    }

    private func dayDate(_ day: Int, result: NativeScheduleResult) -> String? {
        dayDate(day, week: weekNumber(store.selectedWeek), result: result)
    }

    private func dayDate(_ day: Int, week: Int?, result: NativeScheduleResult) -> String? {
        guard let value = rawDayDate(day, week: week, result: result) else { return nil }
        return shortDate(value)
    }

    private func dayIsToday(_ day: Int, result: NativeScheduleResult) -> Bool {
        dayIsToday(day, week: weekNumber(store.selectedWeek), result: result)
    }

    private func dayIsToday(_ day: Int, week: Int?, result: NativeScheduleResult) -> Bool {
        guard let value = rawDayDate(day, week: week, result: result), let today = Self.todayDate else {
            return false
        }
        return value == today
    }

    private func rawDayDate(_ day: Int, week: Int?, result: NativeScheduleResult) -> String? {
        guard let weekNumber = week, let calendar = store.calendar,
              let item = calendar.weeks.first(where: { $0.week == weekNumber }),
              item.days.indices.contains(day - 1) else {
            return nil
        }
        return item.days[day - 1]
    }

    private func weekNumber(_ value: String) -> Int? {
        Int(value.trimmingCharacters(in: .whitespaces))
    }

    private func shortDate(_ value: String) -> String {
        let pieces = value.split(separator: "-")
        guard pieces.count >= 3 else { return value }
        return "\(pieces[pieces.count - 2]).\(pieces[pieces.count - 1])"
    }

    /// 星期条上的单字星期：一、二……日。
    private func dayShortLabel(_ day: Int) -> String {
        let labels = ["一", "二", "三", "四", "五", "六", "日"]
        return labels.indices.contains(day - 1) ? labels[day - 1] : "\(day)"
    }

    /// 星期条上的日期数字（去掉前导零）。
    private func dayNumber(_ day: Int, week: Int?, result: NativeScheduleResult) -> String? {
        guard let value = rawDayDate(day, week: week, result: result) else { return nil }
        guard let last = value.split(separator: "-").last, let number = Int(last) else { return nil }
        return String(number)
    }

    private func dayLabel(_ day: Int) -> String {
        ["周一", "周二", "周三", "周四", "周五", "周六", "周日"].indices.contains(day - 1)
            ? ["周一", "周二", "周三", "周四", "周五", "周六", "周日"][day - 1]
            : "周\(day)"
    }

    /// 这一天的调休安排。日期取自课表日历，所以周视图、日视图和月视图查到的是同一条。
    private func adjustment(day: Int, week: Int?, result: NativeScheduleResult) -> ResolvedCalendarAdjustment? {
        guard let date = rawDayDate(day, week: week, result: result) else { return nil }
        return store.calendar?.adjustments[date]
    }

    /// 调休之后这一列实际代表的「星期几 / 第几周」。编辑和新增课程都要按这个存，
    /// 否则在补班那天改课会把课挪到周六。
    private func effectiveSlot(day: Int, week: Int?, result: NativeScheduleResult) -> (day: Int, week: Int?) {
        guard let adjustment = adjustment(day: day, week: week, result: result),
              adjustment.kind == .swap, let sourceDay = adjustment.sourceDay else {
            return (day, week)
        }
        return (sourceDay, adjustment.sourceWeek ?? week)
    }

    private func blocks(for day: Int, week: Int?, result: NativeScheduleResult) -> [NativeScheduleCourseBlock] {
        // 调休：这一列画的不一定是它自己那个星期几。放假就什么都不画，补班就画
        // 「上哪一天的课」那一天的课；两者都按日期查，和周次分页无关。
        var sourceDay = day
        var sourceWeek = week
        if let adjustment = adjustment(day: day, week: week, result: result) {
            if adjustment.suppressesCourses { return [] }
            sourceDay = adjustment.sourceDay ?? day
            sourceWeek = adjustment.sourceWeek
        }
        let rawBlocks = result.cells
            .filter { $0.day == sourceDay }
            .flatMap { cell in
                cell.courses.enumerated().compactMap { index, course -> NativeScheduleCourseBlock? in
                    if let sourceWeek, !course.weekList.isEmpty, !course.weekList.contains(sourceWeek) {
                        return nil
                    }
                    let fallbackStart = cell.bigSlot * 2 - 1
                    let fallbackEnd = cell.bigSlot * 2
                    var start = min(max(course.startSlot ?? fallbackStart, 1), ScheduleSlot.all.count)
                    var end = min(max(course.endSlot ?? fallbackEnd, start), ScheduleSlot.all.count)
                    // Match the Web timetable's handling of a course repeated
                    // in several large-period cells by the school parser.
                    if end < fallbackStart || start > fallbackEnd {
                        start = min(max(fallbackStart, 1), ScheduleSlot.all.count)
                        end = min(max(fallbackEnd, start), ScheduleSlot.all.count)
                    }
                    return NativeScheduleCourseBlock(
                        id: "\(week.map(String.init) ?? "-")-\(day)-\(cell.bigSlot)-\(index)-\(course.name)",
                        course: course,
                        bigSlot: cell.bigSlot,
                        startSlot: start,
                        endSlot: end
                    )
                }
            }
            .sorted { lhs, rhs in
                if lhs.startSlot != rhs.startSlot { return lhs.startSlot < rhs.startSlot }
                return lhs.endSlot < rhs.endSlot
            }

        let families = Dictionary(grouping: rawBlocks) { block in
            [block.course.customId ?? "", block.course.name, block.course.teacher ?? "",
             block.course.location ?? "", block.course.weeks].joined(separator: "\u{1F}")
        }
        var merged: [NativeScheduleCourseBlock] = []
        for family in families.values {
            var current: NativeScheduleCourseBlock?
            for block in family.sorted(by: { $0.startSlot < $1.startSlot }) {
                if let previous = current, block.startSlot <= previous.endSlot + 1 {
                    current = NativeScheduleCourseBlock(id: previous.id, course: previous.course,
                        bigSlot: previous.bigSlot,
                        startSlot: previous.startSlot, endSlot: max(previous.endSlot, block.endSlot))
                } else {
                    if let current { merged.append(current) }
                    current = block
                }
            }
            if let current { merged.append(current) }
        }
        var laneEnds: [Int] = []
        return merged.sorted(by: { ($0.startSlot, $0.endSlot, $0.id) < ($1.startSlot, $1.endSlot, $1.id) }).map { block in
            let lane = laneEnds.firstIndex(where: { $0 < block.startSlot }) ?? laneEnds.count
            if lane == laneEnds.count {
                laneEnds.append(block.endSlot)
            } else {
                laneEnds[lane] = block.endSlot
            }
            return block.withLane(lane)
        }
    }

    /// Horizontal page margin of the scrolling content.
    private static let contentInset: CGFloat = 16
    private static let slotAxisWidth: CGFloat = 38
    private static let columnGap: CGFloat = 4

    /// The drawn teaching slots plus the date header, sized to keep a complete
    /// day visible above the native tab bar on an iPhone-sized surface.
    private static func scheduleGridHeight(
        rowHeight: CGFloat = NativeScheduleDayColumn.slotHeight,
        slotCount: Int = ScheduleSlot.all.count,
        includesDateHeader: Bool = true
    ) -> CGFloat {
        (includesDateHeader ? NativeScheduleDayColumn.dateHeaderHeight : 0)
            + CGFloat(slotCount) * rowHeight
            + CGFloat(max(0, slotCount - 1)) * NativeScheduleDayColumn.slotGap
    }

    private static var todayDate: String? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: .now)
    }

    private static var chinaWeekday: Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let weekday = calendar.component(.weekday, from: .now)
        return weekday == 1 ? 7 : weekday - 1
    }
}

private enum SurfaceViewMode: String, Hashable {
    case week
    case day
    case month
}

struct NativeScheduleCourseBlock: Identifiable {
    let id: String
    let course: NativeScheduleCourse
    let bigSlot: Int
    let startSlot: Int
    let endSlot: Int
    let lane: Int

    init(id: String, course: NativeScheduleCourse, bigSlot: Int, startSlot: Int, endSlot: Int, lane: Int = 0) {
        self.id = id
        self.course = course
        self.bigSlot = bigSlot
        self.startSlot = startSlot
        self.endSlot = endSlot
        self.lane = lane
    }

    func withLane(_ lane: Int) -> NativeScheduleCourseBlock {
        NativeScheduleCourseBlock(id: id, course: course, bigSlot: bigSlot, startSlot: startSlot, endSlot: endSlot, lane: lane)
    }
}

struct SelectedCourse: Identifiable {
    let id = UUID()
    let course: NativeScheduleCourse
    let day: Int
    let bigSlot: Int
    let startSlot: Int
    let endSlot: Int
}

private struct AddCourseContext: Identifiable {
    let id = UUID()
    let day: Int
    let week: Int
    let startSlot: Int
}

private struct NativeScheduleDayPage: Equatable {
    let week: String?
    let day: Int
}

private struct StateCard: View {
    let systemImage: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?
    let showsProgress: Bool

    var body: some View {
        VStack(spacing: 12) {
            if showsProgress {
                ProgressView()
                    .controlSize(.large)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Color.cpuBrand)
            }

            Text(title)
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 250)
        .padding(24)
        .background(Color.appSecondaryGroupedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

#Preview {
    Text("NativeScheduleView requires a NativeScheduleStore")
}
