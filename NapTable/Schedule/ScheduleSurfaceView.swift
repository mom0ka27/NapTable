import SwiftUI
import Observation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Ported from ../CPU-Web/ios_next (CpuTime) `NativeScheduleView.swift`.
//
// The layout and interaction model are kept close to the original; the surface
// styling has since moved to flat content with glass only on the floating header
// controls (see `ScheduleGlass.swift`). Platform-shim spellings let the same file
// build on iOS and macOS. Data comes from `NativeScheduleStore`,
// which `ScheduleStore.swift` implements on top of NapTable's AppStore.

import SwiftUI

/// The native timetable surface. Data loading and authentication stay in
/// NativeScheduleStore so the SwiftUI surface can also be embedded beside the
/// existing web routes.
struct NativeScheduleView: View {
    @ObservedObject private var store: NativeScheduleStore
    @ObservedObject private var preferences = NativeSchedulePreferences.shared
    @ObservedObject private var purchases = PurchaseManager.shared
    private let onAddTable: () -> Void
    private let onLogin: () -> Void
    private let showsWatch: Bool
    private let onWatch: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scheduleStyle) private var style
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .headline) private var timelineCardHeight: CGFloat = NativeScheduleDayTimeline.standardCardHeight

    @State private var selectedDay = 1
    @State private var didInitializeDay = false
    @State private var viewMode: SurfaceViewMode = .week
    @State private var selectedCourse: SelectedCourse?
    @State private var addCourseContext: AddCourseContext?
    @State private var weekPickerPresented = false
    @State private var freeCoursesPresented = false
    #if DEBUG
    @State private var debugCropImage: DebugCropImage?
    @State private var debugCropOpacity = BackgroundCropEditor.Opacity(light: 0.3, dark: 0.4)
    #endif
    @State private var courseBlockCache = CourseBlockCache()
    @State private var monthIndexCache = MonthIndexCache()
    // 月视图的两个位置：正在显示的月份和选中的那一天，都是 `yyyy-MM-dd`。
    @State private var monthAnchor = ""
    @State private var selectedMonthDate = ""
    @State private var pendingMonthDay: String?
    @State private var monthDayDetails: MonthDaySelection?
    @State private var pendingMonthAction: MonthDayAction?
    @State private var transitionCapture = ScheduleTransitionCapture()
    @State private var outgoingSchedule: PlatformImage?
    @State private var outgoingOpacity = 0.0
    @State private var sourceTransitionID = UUID()

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

    private var displayedTableID: Int? {
        guard purchases.allowsPerTableBackgrounds,
              !store.selectedSemester.hasPrefix("share:") else { return nil }
        return Int(store.selectedSemester)
    }

    /// 顶栏和课表区域自己的底色。有背景图片时必须透明，否则整张图会被这层
    /// 底色盖住；图片下面那层 `scheduleCanvas` 由 `body` 的背景统一铺满全屏。
    private var chromeBackground: AnyShapeStyle {
        displayedBackground == nil ? AnyShapeStyle(.scheduleCanvas) : AnyShapeStyle(.clear)
    }

    private var showsFreeTimeEntry: Bool {
        // 入口是否显示只取决于整张课表，翻周时仅更新角标，不改变顶栏尺寸。
        preferences.showFreeTimeCourses && store.result != nil && !store.freeCourses.isEmpty
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

            // 视口始终占满顶栏下的空间，不随课表节数变化；旧截图在这个固定视口里淡出。
            GeometryReader { viewport in
                ScheduleOuterContainer(scrolls: viewMode != .month) {
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

                            switch viewMode {
                            case .week:
                                weekGrid(result)
                            case .day:
                                dayGrid(result, viewportHeight: max(0, viewport.size.height - 16))
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
                    .padding(.bottom, viewMode == .month ? 0 : 8)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(chromeBackground, ignoresSafeAreaEdges: [.horizontal, .bottom])
                }
                .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
                .background { ScheduleTransitionAnchor(capture: transitionCapture) }
                .overlay(alignment: .topLeading) {
                    if let outgoingSchedule {
                        Image(platformImage: outgoingSchedule)
                            .resizable()
                            // 截图保留捕获时的尺寸，不按新课表的高度缩放或居中。
                            .frame(width: outgoingSchedule.size.width, height: outgoingSchedule.size.height)
                            .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
                            .clipped()
                            .opacity(outgoingOpacity)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .environment(\.scheduleHasBackgroundImage, displayedBackground != nil)
        .environment(\.scheduleBackgroundOpacity, preferences.backgroundOpacity(dark: colorScheme == .dark))
        .background {
            ZStack {
                Rectangle().fill(.scheduleCanvas)
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
            preferences.activate(tableID: displayedTableID)
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
        .onChange(of: store.result?.currentSemester) { _, _ in
            adoptSelectionIfNeeded()
        }
        .onChange(of: store.selectedSemester, initial: true) { _, _ in
            preferences.activate(tableID: displayedTableID)
        }
        .onChange(of: purchases.allowsPerTableBackgrounds) { _, _ in
            preferences.activate(tableID: displayedTableID)
        }
        .onAppear {
            // Settings can temporarily activate another table while this view
            // remains alive in the tab bar.
            preferences.activate(tableID: displayedTableID)
        }
        .onChange(of: store.result?.currentWeek) { _, _ in
            adoptSelectionIfNeeded()
        }
        .onChange(of: store.selectedWeek) { _, _ in
            finishMonthDaySelectionIfReady()
            if pendingMonthDay == nil, !visibleDays.contains(selectedDay) { selectedDay = visibleDays.last ?? 1 }
        }
        .onChange(of: store.calendar) { _, _ in
            finishMonthDaySelectionIfReady()
        }
        .onChange(of: preferences.showWeekend) { _, _ in
            // Hiding the weekend while 周六/周日 is selected would leave the day
            // view pointing at a column that is no longer drawn.
            if !visibleDays.contains(selectedDay) { selectedDay = visibleDays.last ?? 1 }
        }
        .onChange(of: viewMode) { _, mode in
            // 进入月视图时跟随当前浏览到的那一天，而不是停在上次翻到的月份。
            if mode == .month {
                seedMonthSelection(store.result, reset: true)
            } else {
                monthDayDetails = nil
            }
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { clearSourceTransition() }
        }
        .onDisappear { clearSourceTransition() }
        .sheet(item: $monthDayDetails, onDismiss: finishMonthDayAction) { selection in
            NativeScheduleMonthDayDetails(
                day: selection.day,
                slot: selection.slot,
                onOpenDay: {
                    pendingMonthAction = .openDay(selection.day.date)
                    monthDayDetails = nil
                },
                isEditable: !store.isReadOnly,
                onCoursePreview: { block in
                    pendingMonthAction = .course(block, date: selection.day.date, quickLook: true)
                    monthDayDetails = nil
                },
                onCourseSelected: { block in
                    pendingMonthAction = .course(block, date: selection.day.date, quickLook: false)
                    monthDayDetails = nil
                }
            )
        }
        .sheet(item: $selectedCourse) { selection in
            // 速览、共享课表详情和编辑页都在这一个 sheet 里切换，见 `ScheduleCourseSheet`。
            ScheduleCourseSheet(selection: selection, store: store, defaultWeek: Int(store.selectedWeek) ?? 1)
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

    /// 自由时间课程按当前浏览周次筛选，通过顶栏的固定入口查看。
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
            headerIcon("clock.badge.questionmark")
                .overlay(alignment: .topTrailing) {
                    Text(courses.count > 99 ? "99+" : String(courses.count))
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(courses.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.themeOnFill))
                        .padding(.horizontal, 3)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(courses.isEmpty ? AnyShapeStyle(.scheduleCanvas) : AnyShapeStyle(.themeFill), in: Capsule())
                        .offset(x: -1, y: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("自由时间课程")
        .accessibilityValue("本周 \(courses.count) 门，点击查看安排")
        .transaction { $0.animation = nil }
    }

    private func freeTimeSheet() -> some View {
        let courses = weeklyFreeCourses()
        return NavigationStack {
            List {
                Section {
                    if courses.isEmpty {
                        Text("本周没有自由时间课程")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(courses) { course in
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
            .appListBackground()
            .appSoftTopScrollEdge()
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
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在更新课表")
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
                .frame(width: 112)
                .accessibilityLabel("切换课表视图")

                headerActions(result)
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

    /// 周次一行：左边是可点开选周的标题和日期范围，右边两个小箭头翻周。
    /// 不再用三块大按钮，课表本身也能左右滑动翻周。
    private func weekNavigator(_ result: NativeScheduleResult) -> some View {
        HStack(alignment: .center, spacing: 0) {
            // 标题和日期范围直接放在同一条基线上；点这一行打开选周。
            // 「第 N 周」用主题色字表明能点（同系统日历左上角的月份按钮）；
            // 不加任何箭头，免得和课表选择的下拉箭头重复。
            Button {
                weekPickerPresented = true
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(weekTitle(result))
                        .font(.headline)
                        .fontDesign(navigatorTitleDesign)
                        .foregroundStyle(.themeText)
                    if let range = weekRange(result), !range.isEmpty {
                        Text(range)
                            .font(.subheadline)
                            .fontDesign(style == .minimal ? nil : style.fontDesign)
                            .foregroundStyle(navigatorSecondary)
                    }
                }
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.leading, Self.navigatorTitleInset)
                .frame(maxWidth: .infinity, minHeight: Self.navigatorHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("选择周次")
            .accessibilityValue([weekTitle(result), weekRange(result)].compactMap { $0 }.joined(separator: "，"))

            weekStepButton(
                systemName: "chevron.left",
                label: "上一周",
                enabled: canMoveWeek(-1, result: result)
            ) {
                moveWeek(-1, result: result)
            }

            weekStepButton(
                systemName: "chevron.right",
                label: "下一周",
                enabled: canMoveWeek(1, result: result)
            ) {
                moveWeek(1, result: result)
            }
        }
        // 翻页事务只作用于课表；周次、日期范围和箭头状态直接更新，
        // 避免返回本周时文字宽度跟着插值重排。
        .transaction { $0.animation = nil }
    }

    private func monthNavigator() -> some View {
        HStack(alignment: .center, spacing: 0) {
            Text(monthTitle)
                .font(.headline)
                .fontDesign(navigatorTitleDesign)
                .monospacedDigit()
                .foregroundStyle(.themeText)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.leading, Self.navigatorTitleInset)
                .frame(maxWidth: .infinity, minHeight: Self.navigatorHeight, alignment: .leading)
                .accessibilityAddTraits(.isHeader)

            weekStepButton(systemName: "chevron.left", label: "上个月", enabled: true) { moveMonth(-1) }
            weekStepButton(systemName: "chevron.right", label: "下个月", enabled: true) { moveMonth(1) }
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
                Task { await switchSchedule(to: value) }
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
            // A title with a disclosure chevron, like a navigation title menu.
            // It is the page's heading, so it gets no pill or glass of its own:
            // 标题字号撑起这一行，箭头放进主题色小圆里，一看就知道能点开切换。
            HStack(spacing: 6) {
                if selected?.isShared == true {
                    Image(systemName: "person.2.fill")
                        .font(.subheadline)
                        .foregroundStyle(.themeText)
                }
                Text(semesterTitle(result))
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.themeText)
                    .frame(width: 18, height: 18)
                    .background(.themeTint(0.12), in: Circle())
            }
            .foregroundStyle(.primary)
            // Menu 会按标签的自然宽度居中；在标签内部固定靠左，长短名称共用起点。
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Keep the menu's anchor and label out of navigation animations.
        .transaction { $0.animation = nil }
        .accessibilityLabel("选择课表")
        .accessibilityValue(selected.map { $0.isShared ? "共享课表 \($0.label)" : $0.label } ?? "")
    }

    @MainActor
    private func switchSchedule(to value: String) async {
        let transitionID = UUID()
        // 只截取屏幕上已有的画面；旧课表不会跟随新 store 重算，也无需再渲染一套网格。
        let image = reduceMotion ? nil : transitionCapture.snapshot()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            sourceTransitionID = transitionID
            outgoingSchedule = image
            outgoingOpacity = image == nil ? 0 : 1
        }
        await store.selectSemester(value)
        guard image != nil else { return }
        await Task.yield()
        guard sourceTransitionID == transitionID, !reduceMotion else { return }
        // 新课表一直保持完整不透明，旧画面从上方淡出，避免先变暗再恢复造成闪烁。
        withAnimation(.easeInOut(duration: 0.22), completionCriteria: .removed) {
            outgoingOpacity = 0
        } completion: {
            guard sourceTransitionID == transitionID else { return }
            clearSourceTransition()
        }
    }

    private func clearSourceTransition() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            sourceTransitionID = UUID()
            outgoingSchedule = nil
            outgoingOpacity = 0
        }
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
            headerIcon("ellipsis")
        }
        .accessibilityLabel("更多课表操作")
    }

    /// The header's icon buttons share one glass capsule, the way a toolbar
    /// groups its items. Glass is the floating control layer, so this is the
    /// only glass on the page besides the system tab bar and segmented control.
    private func headerActions(_ result: NativeScheduleResult) -> some View {
        HStack(spacing: 0) {
            if showsWatch {
                Button(action: onWatch) {
                    headerIcon("applewatch")
                }
                .accessibilityLabel("Apple Watch 课表同步")
            }

            // 显示设置开启时始终保留这个按钮，切换课表不会增减工具栏宽度。
            // 没有自由时间课程的课表显示灰色的 0，避免图标突然插入并挤动标题。
            if preferences.showFreeTimeCourses {
                freeTimeEntry(weeklyFreeCourses())
                    .foregroundStyle(store.freeCourses.isEmpty ? Color.secondary : Color.primary)
                    .disabled(store.freeCourses.isEmpty)
            }

            Button {
                switch viewMode {
                case .day: jumpToCurrentDay(result)
                case .week: jumpToCurrentWeek(result)
                case .month: jumpToCurrentMonth()
                }
            } label: {
                headerIcon("location.north.line")
            }
            .accessibilityLabel(jumpButtonLabel)
            .disabled(isViewingCurrentPosition(result))

            scheduleToolsMenu(result)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.horizontal, 2)
        .modifier(ScheduleGlassControl(cornerRadius: 18))
    }

    private func headerIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .medium))
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
    }

    private func weekStepButton(
        systemName: String,
        label: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 40, height: Self.navigatorHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? AnyShapeStyle(style.inkColor(dark: colorScheme == .dark)) : AnyShapeStyle(.tertiary))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    /// 日视图的星期条，画法跟着课表风格走，见 `ScheduleDayStrip`。
    private func dayPicker(_ result: NativeScheduleResult) -> some View {
        let week = weekNumber(store.selectedWeek)
        return ScheduleDayStrip(
            days: visibleDays.map { day in
                .init(day: day, number: dayNumber(day, week: week, result: result),
                      date: dayDate(day, week: week, result: result),
                      isToday: dayIsToday(day, week: week, result: result),
                      adjustment: adjustment(day: day, week: week, result: result),
                      courseCount: blocks(for: day, week: week, result: result).count)
            },
            selectedDay: selectedDay
        ) { day in
            withAnimation(.snappy(duration: 0.2)) {
                selectedDay = day
                if let date = rawDayDate(day, week: week, result: result) {
                    selectedMonthDate = date
                    monthAnchor = date
                }
            }
        }
    }

    /// 分页内容为全部节次预留高度，外框按当前和相邻页裁剪，避免下一页被截断。
    /// 整周放在一块面板上，空节次不再各画一个格子，只靠细分隔线分行。
    private func weekGrid(_ result: NativeScheduleResult) -> some View {
        let rowHeight = weekGridRowHeight
        let panelInsets = 2 * stylePanelPadding
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                let contentWidth = proxy.size.width - 2 * Self.contentInset
                weekPager(result: result, width: proxy.size.width, rowHeight: rowHeight) { week in
                    let days = visibleDays(week: week, result: result)
                    let dayCount = CGFloat(days.count)
                    // 节次轴和每一天之间都有一个间隔，n 天正好 n 个。
                    let columnWidth = max(
                        24,
                        (contentWidth - panelInsets - Self.slotAxisWidth - dayCount * styleColumnGap) / dayCount
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
                    .padding(stylePanelPadding)
                    .background { ScheduleSurface(cornerRadius: 20, isPanel: true, showsBorder: style.framesPanel) }
                    .frame(width: contentWidth, alignment: .leading)
                    .padding(.horizontal, Self.contentInset)
                }
                .frame(height: Self.scheduleGridHeight(
                    rowHeight: rowHeight,
                    includesDateHeader: preferences.showDateHeader
                ) + panelInsets, alignment: .top)
            }
            .frame(height: Self.scheduleGridHeight(
                rowHeight: rowHeight,
                slotCount: pagerSlotCount(
                    weeks: [adjacentWeekValue(-1, result: result), store.selectedWeek, adjacentWeekValue(1, result: result)],
                    result: result
                ),
                includesDateHeader: preferences.showDateHeader
            ) + panelInsets, alignment: .top)
            .clipped()
            .contentShape(Rectangle())
            .animation(nil, value: result.currentSemester)
        }
    }

    private func dayGrid(_ result: NativeScheduleResult, viewportHeight: CGFloat) -> some View {
        // 给首尾卡片的长按放大和阴影留出空间，避免横向分页器在上下沿裁切。
        // 随卡片高度增加留白，兼顾大字号；顶部滚动渐隐仍由外层统一处理。
        let pressInset = max(16, dayTimelineCardHeight * 0.02 + 8)
        // 无课状态按日期栏以下的可见空间居中，不受相邻日期的课程数量影响。
        // 横屏或大字号时至少保留内容所需高度，由外层继续提供纵向滚动。
        let emptyHeight = max(
            max(360, dayTimelineCardHeight * 2),
            viewportHeight - 2 * pressInset
        )
        let pages = [
            adjacentDayPage(-1, result: result),
            NativeScheduleDayPage(week: store.selectedWeek.nilIfEmpty, day: selectedDay),
            adjacentDayPage(1, result: result)
        ].compactMap { $0 }
        let height = pages.map { page in
            let courses = blocks(for: page.day, week: page.week.flatMap(Int.init), result: result)
            if style == .minimal {
                return courses.isEmpty ? emptyHeight : NativeScheduleDayTimeline.height(blocks: courses, cardHeight: dayTimelineCardHeight)
            }
            let week = page.week.flatMap(Int.init)
            return max(courses.isEmpty && (style == .paper || style == .board) ? emptyHeight : 0,
                ScheduleStyledDayView.height(style: style, blocks: courses,
                    clocks: periodSlots(on: rawDayDate(page.day, week: week, result: result)),
                    slotCount: slotCount(week: week, result: result), cardHeight: dayTimelineCardHeight,
                    hasNote: adjustment(day: page.day, week: week, result: result) != nil))
        }.max() ?? emptyHeight
        let pagerHeight = max(height, viewportHeight - 2 * pressInset) + 2 * pressInset
        return GeometryReader { proxy in
            dayPager(result: result, width: proxy.size.width) { page in
                dayTimeline(result: result, week: page.week.flatMap(Int.init), day: page.day, emptyHeight: emptyHeight)
                    .padding(.horizontal, Self.contentInset)
                    .padding(.vertical, pressInset)
            }
            .frame(height: pagerHeight, alignment: .top)
        }
        .frame(height: pagerHeight, alignment: .top)
        .clipped()
        .contentShape(Rectangle())
        .animation(nil, value: result.currentSemester)
    }

    /// `cardHeight` 为空时按当前字号和密度算；分享图传固定值。
    private func dayTimeline(result: NativeScheduleResult, week: Int?, day: Int, live: Bool = true,
                             emptyHeight: CGFloat = 0, cardHeight: CGFloat? = nil) -> some View {
        let date = rawDayDate(day, week: week, result: result)
        let clocks = periodSlots(on: date)
        let slot = effectiveSlot(day: day, week: week, result: result)
        let isToday = live && dayIsToday(day, week: week, result: result)
        func timeline(_ now: Date?) -> NativeScheduleDayTimeline {
            NativeScheduleDayTimeline(
                blocks: blocks(for: day, week: week, result: result),
                clocks: clocks,
                day: day,
                emptyNote: adjustment(day: day, week: week, result: result)?.detail,
                holidayGreeting: date.flatMap { ChineseCalendarInfo.restGreeting(forDate: $0) },
                nowMinutes: preferences.showNowIndicator ? now.map(nowMinutes) : nil,
                completedBeforeMinutes: date.flatMap { date in
                    guard let today = todayDate else { return nil }
                    if date < today { return 24 * 60 }
                    return date == today ? nowMinutes(now ?? .now) : nil
                },
                cardHeight: cardHeight ?? dayTimelineCardHeight,
                emptyHeight: emptyHeight,
                isEditable: !store.isReadOnly,
                onCourseSelected: { block in
                    selectedCourse = courseSelection(block, day: day, editDay: slot.day, clocks: clocks)
                },
                onCoursePreview: { block in
                    selectedCourse = courseSelection(block, day: day, editDay: slot.day, clocks: clocks,
                                                     quickLook: true)
                },
                slotCount: slotCount(week: week, result: result),
                onEmptySlot: { value in presentAddCourse(day: slot.day, week: slot.week, startSlot: value) }
            )
        }
        // 今天按分钟刷新课程状态；「现在」的节点和倒计时仍由设置控制。
        return Group {
            if isToday {
                TimelineView(.everyMinute) { context in timeline(context.date) }
            } else {
                timeline(nil)
            }
        }
    }

    // MARK: 月视图

    private func monthCalendar(_ result: NativeScheduleResult) -> some View {
        NativeScheduleMonthView(
            monthAnchor: Binding(
                get: { monthAnchor.isEmpty ? (todayDate ?? "") : monthAnchor },
                set: {
                    monthAnchor = $0
                    // 翻到新月份时把摘要落到该月第一天；点具体日期时，
                    // selectedMonthDate 已经属于目标月份，不会被这里覆盖。
                    let targetMonth = String($0.prefix(7))
                    if !targetMonth.isEmpty, !selectedMonthDate.hasPrefix(targetMonth) {
                        selectedMonthDate = targetMonth + "-01"
                    }
                }
            ),
            contentRevision: store.lastUpdatedAt,
            selectedDate: selectedMonthDate,
            todayDate: todayDate,
            dateIndex: monthDateIndex,
            blocks: { day, week in blocks(for: day, week: week, result: result) },
            adjustments: store.calendar?.adjustments ?? [:],
            onSelect: { day in
                selectMonthDate(day.date, result: result)
            },
            onOpenDetails: { day in
                selectMonthDate(day.date, result: result)
                monthDayDetails = MonthDaySelection(day: day, slot: monthDateIndex[day.date])
            },
            isEditable: !store.isReadOnly,
            onCoursePreview: { day, block in
                selectMonthDate(day.date, result: result)
                openMonthCourse(block, date: day.date, quickLook: true)
            },
            onCourseSelected: { day, block in
                selectMonthDate(day.date, result: result)
                openMonthCourse(block, date: day.date, quickLook: false)
            },
            onMoveMonth: moveMonth
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private struct MonthDaySelection: Identifiable {
        // 每次点击都有独立的呈现身份，同一日期在关闭后也能重新打开。
        let id = UUID()
        let day: NativeScheduleMonthView.Day
        let slot: NativeScheduleMonthView.DaySlot?
    }

    private enum MonthDayAction {
        case openDay(String)
        case course(NativeScheduleCourseBlock, date: String, quickLook: Bool)
    }

    private func finishMonthDayAction() {
        guard let action = pendingMonthAction else { return }
        pendingMonthAction = nil
        switch action {
        case .openDay(let date):
            openDayView(date)
        case .course(let block, let date, let quickLook):
            openMonthCourse(block, date: date, quickLook: quickLook)
        }
    }

    private func openMonthCourse(_ block: NativeScheduleCourseBlock, date: String, quickLook: Bool) {
        guard let result = store.result, let slot = monthDateIndex[date] else { return }
        let effective = effectiveSlot(day: slot.day, week: slot.week, result: result)
        selectedCourse = courseSelection(block, day: slot.day, editDay: effective.day,
                                         clocks: periodSlots(on: date), quickLook: quickLook)
    }

    /// 日期 -> 教学周与星期几。学期日历之外的日期查不到，月历会把它当成非教学日。
    private final class MonthIndexCache {
        var weeks: [NativeCalendarWeek] = []
        var index: [String: NativeScheduleMonthView.DaySlot] = [:]
    }

    private var monthDateIndex: [String: NativeScheduleMonthView.DaySlot] {
        guard let calendar = store.calendar else { return [:] }
        if monthIndexCache.weeks == calendar.weeks { return monthIndexCache.index }
        var index: [String: NativeScheduleMonthView.DaySlot] = [:]
        for week in calendar.weeks {
            for (offset, date) in week.days.enumerated() where !date.isEmpty {
                index[date] = NativeScheduleMonthView.DaySlot(week: week.week, day: offset + 1)
            }
        }
        monthIndexCache.weeks = calendar.weeks
        monthIndexCache.index = index
        return index
    }

    private var monthTitle: String {
        let anchor = monthAnchor.isEmpty ? (todayDate ?? "") : monthAnchor
        let pieces = anchor.split(separator: "-")
        guard pieces.count >= 2, let year = Int(pieces[0]), let month = Int(pieces[1]) else { return anchor }
        return "\(year) 年 \(month) 月"
    }

    private func moveMonth(_ offset: Int) {
        let anchor = monthAnchor.isEmpty ? (todayDate ?? "") : monthAnchor
        guard let date = ChineseCalendarInfo.date(fromDate: anchor),
              let moved = ChineseCalendarInfo.gregorian.date(byAdding: .month, value: offset, to: date) else {
            return
        }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            let movedString = ChineseCalendarInfo.dateString(moved)
            monthAnchor = movedString
            let targetMonth = String(movedString.prefix(7))
            if !selectedMonthDate.hasPrefix(targetMonth) {
                selectedMonthDate = targetMonth + "-01"
            }
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
        guard let today = todayDate else { return }
        // 先同步日期/周次；仅月份定位参与过渡，避免动画尾部再改布局。
        selectedMonthDate = today
        if let result = store.result { selectMonthDate(today, result: result) }
        monthAnchor = today
    }

    /// 进入月视图时，先跟随当前浏览到的那一天；它不在学期里就退回今天。
    private func seedMonthSelection(_ result: NativeScheduleResult?, reset: Bool = false) {
        let browsing = result.flatMap { rawDayDate(selectedDay, week: weekNumber(store.selectedWeek), result: $0) }
        let fallback = browsing ?? todayDate ?? ChineseCalendarInfo.dateString(.now)
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
            guard let today = todayDate else { return true }
            return selectedMonthDate == today && monthAnchor.prefix(7) == today.prefix(7)
        }
    }

    private var isSelectionToday: Bool {
        guard let today = todayDate else { return true }
        return selectedMonthDate == today && monthAnchor.prefix(7) == today.prefix(7)
            && selectedDay == chinaWeekday
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

    /// 分页器可见的几页里最多的行数。
    private func pagerSlotCount(weeks: [String?], result: NativeScheduleResult) -> Int {
        weeks.compactMap { $0 }
            .map { slotCount(week: weekNumber($0), result: result) }
            .max() ?? slotCount(week: nil, result: result)
    }

    /// 还没有课表数据时（加载中）按没有课算。
    private var emptySlotCount: Int {
        preferences.visibleSlotCount(total: ScheduleSlot.all.count, lastOccupiedSlot: 0)
    }

    private var weekGridRowHeight: CGFloat {
        switch preferences.density {
        case "compact": 40
        case "relaxed": 49
        default: NativeScheduleDayColumn.slotHeight
        }
    }

    private var dayTimelineCardHeight: CGFloat {
        switch preferences.density {
        case "compact": timelineCardHeight * 0.9
        case "relaxed": timelineCardHeight * 1.15
        default: timelineCardHeight
        }
    }

    /// 使用真实日期作为稳定分页标识，连续滑动不再等待计时器或回跳中间页。
    private func dayPager<Page: View>(
        result: NativeScheduleResult,
        width: CGFloat,
        @ViewBuilder page: @escaping (NativeScheduleDayPage) -> Page
    ) -> some View {
        let pages = result.weeks.flatMap { week in
            visibleDays(week: weekNumber(week.value), result: result).map {
                NativeScheduleDayPage(week: week.value, day: $0)
            }
        }
        return SchedulePagingScrollView(
            pages: pages,
            selection: Binding(
                get: { NativeScheduleDayPage(week: store.selectedWeek.nilIfEmpty, day: selectedDay) },
                set: {
                    guard store.result?.currentSemester == result.currentSemester else { return }
                    selectDayPage($0, result: result)
                }
            ),
            width: width,
            content: page
        )
        // 新课表从自己的浏览周次初始化，丢弃旧课表的惯性滚动和跳周动画。
        .id(result.currentSemester)
    }

    private func weekPager<Page: View>(
        result: NativeScheduleResult,
        width: CGFloat,
        rowHeight: CGFloat = NativeScheduleDayColumn.slotHeight,
        @ViewBuilder page: @escaping (Int?) -> Page
    ) -> some View {
        SchedulePagingScrollView(
            pages: result.weeks.map(\.value),
            singlePageJumps: true,
            selection: Binding(
                get: { store.selectedWeek },
                set: {
                    guard store.result?.currentSemester == result.currentSemester else { return }
                    store.commitWeekSelection($0)
                }
            ),
            width: width
        ) { week in
            page(weekNumber(week))
        }
        .id(result.currentSemester)
    }

    private func selectDayPage(_ target: NativeScheduleDayPage, result: NativeScheduleResult) {
        if let week = target.week, week != store.selectedWeek {
            store.commitWeekSelection(week)
        }
        selectedDay = target.day
        if let date = rawDayDate(target.day, week: target.week.flatMap(Int.init), result: result) {
            selectedMonthDate = date
            monthAnchor = date
        }
    }

    private func scheduleRows(
        result: NativeScheduleResult,
        week: Int?,
        days: [Int],
        columnWidth: CGFloat,
        compactCards: Bool,
        rowHeight: CGFloat = NativeScheduleDayColumn.slotHeight,
        showsDateHeader: Bool = true,
        showsNowLine: Bool = true
    ) -> some View {
        Group {
            if style != .minimal && showsNowLine && preferences.showNowIndicator {
                TimelineView(.everyMinute) { context in
                    scheduleRowsContent(result: result, week: week, days: days, columnWidth: columnWidth,
                        compactCards: compactCards, rowHeight: rowHeight, showsDateHeader: showsDateHeader,
                        showsNowLine: showsNowLine, currentMinutes: nowMinutes(context.date))
                }
            } else {
                scheduleRowsContent(result: result, week: week, days: days, columnWidth: columnWidth,
                    compactCards: compactCards, rowHeight: rowHeight, showsDateHeader: showsDateHeader,
                    showsNowLine: showsNowLine, currentMinutes: nil)
            }
        }
    }

    private func scheduleRowsContent(result: NativeScheduleResult, week: Int?, days: [Int], columnWidth: CGFloat,
                                     compactCards: Bool, rowHeight: CGFloat, showsDateHeader: Bool,
                                     showsNowLine: Bool, currentMinutes: Int?) -> some View {
        let slotCount = slotCount(week: week, result: result)
        let date = store.calendar?.weeks.first(where: { $0.week == week })?.days[safe: (days.first ?? 1) - 1]
        let clocks = (date.map { store.periods(on: $0) }?
            .map { ScheduleSlot(number: $0.number, start: $0.startTime, end: $0.endTime) }
            ?? ScheduleSlot.all)
        let headerHeight = showsDateHeader ? NativeScheduleDayColumn.dateHeaderHeight : 0
        let todayIndex = days.firstIndex { dayIsToday($0, week: week, result: result) }
        // 表格风格的格线要避开跨节的课，见 `ScheduleTableRules`。
        let tableBlocks = style == .table ? days.map { blocks(for: $0, week: week, result: result) } : []
        return HStack(alignment: .top, spacing: styleColumnGap) {
            slotAxis(rowHeight: rowHeight, slotCount: slotCount, showsHeader: showsDateHeader,
                     monthLabel: date.flatMap(monthLabel), clocks: clocks)

            ForEach(days, id: \.self) { day in
                let slot = effectiveSlot(day: day, week: week, result: result)
                let dayClocks = periodSlots(on: rawDayDate(day, week: week, result: result))
                NativeScheduleDayColumn(
                    day: day,
                    dateText: dayDate(day, week: week, result: result),
                    headerDateText: rawDayDate(day, week: week, result: result).flatMap(headerDayText),
                    isToday: dayIsToday(day, week: week, result: result),
                    adjustment: adjustment(day: day, week: week, result: result),
                    columnWidth: columnWidth,
                    rowHeight: rowHeight,
                    slotCount: slotCount,
                    clocks: dayClocks,
                    compactCards: compactCards,
                    showsDateHeader: showsDateHeader,
                    isEditable: !store.isReadOnly,
                    blocks: blocks(for: day, week: week, result: result),
                    onCourseSelected: { block in
                        selectedCourse = courseSelection(block, day: day, editDay: slot.day, clocks: dayClocks)
                    },
                    onCoursePreview: { block in
                        selectedCourse = courseSelection(block, day: day, editDay: slot.day, clocks: dayClocks,
                                                             quickLook: true)
                    },
                    onEmptySlot: { value in
                        presentAddCourse(day: slot.day, week: slot.week, startSlot: value)
                    },
                    nowMinutes: dayIsToday(day, week: week, result: result) ? currentMinutes : nil
                )
            }
        }
        .background(alignment: .topLeading) {
            if style == .minimal {
                ScheduleRowRules(
                headerHeight: headerHeight,
                rowHeight: rowHeight,
                slotCount: slotCount,
                leading: Self.slotAxisWidth + styleColumnGap / 2
                )
            } else if style == .table {
                // 垫在课程下面：线不压课名，跨节的课中间也不画线。
                ScheduleTableRules(headerHeight: headerHeight, rowHeight: rowHeight, slotCount: slotCount,
                                   axisWidth: Self.slotAxisWidth, columnWidth: columnWidth, dayCount: days.count,
                                   joined: { column, row in
                                       tableBlocks[column].contains { $0.startSlot <= row && row < $0.endSlot }
                                   })
            }
        }
        .overlay(alignment: .topLeading) {
            if showsNowLine, preferences.showNowIndicator, let todayIndex {
                TimelineView(.everyMinute) { context in
                    let minutes = nowMinutes(context.date)
                    if let y = nowOffset(minutes, clocks: Array(clocks.prefix(slotCount)), rowHeight: rowHeight) {
                        // 节次轴上一个时间胶囊，今天那列一条线，两者在同一高度连成「现在」。
                        ZStack(alignment: .topLeading) {
                            if style != .grid {
                            ScheduleNowLine(width: columnWidth)
                                .offset(
                                    x: Self.slotAxisWidth + styleColumnGap
                                        + CGFloat(todayIndex) * (columnWidth + styleColumnGap),
                                    y: headerHeight + y
                                )
                            }
                            ScheduleNowBadge(minutes: minutes)
                                .frame(width: Self.slotAxisWidth)
                                .offset(y: headerHeight + y - ScheduleNowBadge.height / 2)
                        }
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }

    /// 三种视图共用课程选择：速览写实际上课的星期；编辑仍按调休换算后的
    /// 星期存，见 `effectiveSlot`。
    private func courseSelection(
        _ block: NativeScheduleCourseBlock,
        day: Int,
        editDay: Int,
        clocks: [ScheduleSlot],
        quickLook: Bool = false
    ) -> SelectedCourse {
        SelectedCourse(
            course: block.course,
            day: editDay,
            bigSlot: block.bigSlot,
            startSlot: block.startSlot,
            endSlot: block.endSlot,
            schedule: ScheduleCourseTimeText(day: day, block: block, clocks: clocks).display,
            quickLook: quickLook
        )
    }

    /// 现在落在表上的纵向位置。课间停在两节之间的空隙里；第一节之前和最后一节
    /// 之后不画，免得一条线压在表头或表格外面。
    /// 课表所在时区的「现在」，按当天零点起的分钟数算。
    private func nowMinutes(_ now: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = store.timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private func nowOffset(_ current: Int, clocks: [ScheduleSlot], rowHeight: CGFloat) -> CGFloat? {
        let step = rowHeight + NativeScheduleDayColumn.slotGap
        for (index, slot) in clocks.enumerated() {
            guard let start = scheduleClockMinutes(slot.start), let end = scheduleClockMinutes(slot.end),
                  end > start else { return nil }
            if current < start {
                return index == 0 ? nil : CGFloat(index) * step - NativeScheduleDayColumn.slotGap / 2
            }
            if current <= end {
                return CGFloat(index) * step + rowHeight * CGFloat(current - start) / CGFloat(end - start)
            }
        }
        return nil
    }

    private func slotAxis(
        rowHeight: CGFloat = NativeScheduleDayColumn.slotHeight,
        slotCount: Int = ScheduleSlot.all.count,
        showsHeader: Bool = true,
        monthLabel: String? = nil,
        clocks: [ScheduleSlot] = ScheduleSlot.all
    ) -> some View {
        VStack(spacing: 0) {
            if showsHeader {
                // 表头只写几号，月份放在节次轴顶上，像日历一样读。
                Text(monthLabel ?? "节次")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.scheduleMeta)
                    .frame(width: Self.slotAxisWidth, height: NativeScheduleDayColumn.dateHeaderHeight)
            }

            VStack(spacing: NativeScheduleDayColumn.slotGap) {
                ForEach(clocks.prefix(slotCount), id: \.number) { slot in
                    if style != .minimal {
                        ScheduleStyledSlotLabel(slot: slot,
                            startsSession: clocks.first(where: { $0.number == slot.number - 1 }).map {
                                ScheduleStyleTime.session($0.start) != ScheduleStyleTime.session(slot.start)
                            } ?? true)
                            .frame(width: Self.slotAxisWidth, height: rowHeight)
                    } else {
                    // 简约保留原节号和开始时间。
                    VStack(spacing: 3) {
                        Text("\(slot.number)")
                            .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.primary)
                        Text(slot.start)
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.scheduleMeta)
                    }
                    .frame(width: Self.slotAxisWidth, height: rowHeight)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("第 \(slot.number) 节，\(slot.start) 至 \(slot.end)")
                    }
                }
            }
        }
    }

    /// 「10月」：节次轴顶上的月份。
    private func monthLabel(_ date: String) -> String? {
        let pieces = date.split(separator: "-")
        guard pieces.count >= 3, let month = Int(pieces[1]) else { return nil }
        return "\(month)月"
    }

    /// 周视图表头上的日期：只写几号，月份看节次轴顶上。
    private func headerDayText(_ date: String) -> String? {
        let pieces = date.split(separator: "-")
        guard pieces.count >= 3, let day = Int(pieces[2]) else { return nil }
        return String(day)
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
                let columnWidth = max(1, (proxy.size.width - Self.slotAxisWidth) / CGFloat(visibleDays.count))
                HStack(alignment: .top, spacing: 0) {
                    slotAxis(rowHeight: weekGridRowHeight, slotCount: emptySlotCount)
                    ForEach(visibleDays, id: \.self) { day in
                        NativeScheduleDayColumn(
                            day: day,
                            dateText: nil,
                            isToday: day == chinaWeekday,
                            adjustment: nil,
                            columnWidth: columnWidth,
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
                .background(alignment: .topLeading) {
                    if style == .table {
                        ScheduleTableRules(headerHeight: NativeScheduleDayColumn.dateHeaderHeight,
                                           rowHeight: weekGridRowHeight, slotCount: emptySlotCount,
                                           axisWidth: Self.slotAxisWidth, columnWidth: columnWidth,
                                           dayCount: visibleDays.count)
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
                .foregroundStyle(.themeText)
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
                                .foregroundStyle(isSelected ? AnyShapeStyle(.themeOnFill) : (isCurrent ? AnyShapeStyle(.themeText) : AnyShapeStyle(.primary)))
                                    .background {
                                        if isSelected {
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(.themeFill)
                                        } else {
                                            ScheduleSurface(cornerRadius: 10)
                                        }
                                    }
                                    .overlay {
                                        if isCurrent && !isSelected {
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .strokeBorder(.themeText, lineWidth: 1)
                                                .opacity(0.6)
                                        }
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
            .appSoftTopScrollEdge()
            // The sheet sits on its own background, never on the photo.
            .environment(\.scheduleHasBackgroundImage, false)
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

    /// 分享图单独计算比例，课程和调休数据仍使用当前浏览的课表。
    @MainActor
    private func exportScheduleImage(_ result: NativeScheduleResult) {
        let week = Int(store.selectedWeek) ?? Int(result.currentWeek) ?? 1
        let isDayView = viewMode == .day
        let exportDays = isDayView ? [selectedDay] : visibleDays
        let layout = ScheduleShareImageLayout(
            isDayView: isDayView,
            slotCount: slotCount(week: week, result: result),
            flushPanel: style == .table
        )
        let date = isDayView
            ? [dayLabel(selectedDay), dayDate(selectedDay, week: week, result: result)]
                .compactMap { $0 }.joined(separator: " · ")
            : weekRange(result)
        // 图上是静态的课表：不标今天和现在、不按已上完变灰（`ScheduleShareImage` 打开
        // `scheduleStaticRendering`），卡片高度也固定，不跟系统字号走。
        let content = ScheduleShareImage(
            layout: layout,
            title: semesterTitle(result),
            subtitle: date ?? "",
            week: week
        ) {
            if isDayView {
                dayTimeline(result: result, week: week, day: selectedDay, live: false,
                            cardHeight: layout.timelineCardHeight)
                    .frame(height: ScheduleStyledDayView.height(
                        style: style, blocks: blocks(for: selectedDay, week: week, result: result),
                        clocks: periodSlots(on: rawDayDate(selectedDay, week: week, result: result)),
                        slotCount: slotCount(week: week, result: result), cardHeight: layout.timelineCardHeight,
                        hasNote: adjustment(day: selectedDay, week: week, result: result) != nil, isStatic: true
                    ))
            } else {
                // 和屏幕上一样，整周套在一块面板里。
                scheduleRows(
                    result: result,
                    week: week,
                    days: exportDays,
                    columnWidth: layout.columnWidth(
                        dayCount: exportDays.count,
                        axisWidth: Self.slotAxisWidth,
                        gap: styleColumnGap
                    ),
                    compactCards: false,
                    rowHeight: layout.rowHeight,
                    showsDateHeader: true,
                    showsNowLine: false
                )
                .padding(layout.panelPadding)
                .background { ScheduleSurface(cornerRadius: 20, isPanel: true, showsBorder: style.framesPanel) }
            }
        }
        .environment(\.colorScheme, colorScheme)
        .environment(\.scheduleStyle, style)
        .environment(\.appThemeBrand, NativeThemeSettings.shared.brandRGB)
        .environment(\.appThemeBackgroundEnabled, NativeThemeSettings.shared.themeBackgroundEnabled)

        guard let data = content.platformRenderedImageData() else { return }
        let suffix = isDayView ? "日课表" : "周课表"
        PlatformSharePresenter.present(
            data: data,
            fileName: "\(AppBrand.name)-第\(week)周-\(suffix).png",
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
            seasonalPeriods: store.seasonalPeriods,
            adjustments: calendar.adjustments,
            timeZone: store.timeZone
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
        case "detail", "quickLook":
            // quickLook 是轻点周视图卡片弹出的课程速览。
            guard let result = store.result else { return }
            for cell in result.cells {
                guard let course = cell.courses.first else { continue }
                let block = NativeScheduleCourseBlock(
                    id: course.id, course: course, bigSlot: cell.bigSlot,
                    startSlot: course.startSlot ?? cell.bigSlot * 2 - 1,
                    endSlot: course.endSlot ?? cell.bigSlot * 2
                )
                selectedCourse = courseSelection(block, day: cell.day, editDay: cell.day,
                                                     clocks: ScheduleSlot.all, quickLook: raw == "quickLook")
                return
            }
        default:
            break
        }
    }
    #endif

    private func moveWeek(_ offset: Int, result: NativeScheduleResult) {
        guard let target = adjacentWeekValue(offset, result: result) else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
            store.commitWeekSelection(target)
        }
    }

    private func moveDay(_ offset: Int, result: NativeScheduleResult) {
        guard let target = adjacentDayPage(offset, result: result) else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
            selectDayPage(target, result: result)
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
        if let today = todayDate {
            selectedMonthDate = today
            monthAnchor = today
        }
        pendingMonthDay = nil
        selectedDay = store.calendar?.weeks.first(where: { $0.week == store.calendar?.currentWeek })
            .flatMap { week in todayDate.flatMap(week.days.firstIndex(of:)).map { $0 + 1 } }
            ?? chinaWeekday
        didInitializeDay = true
        guard !isViewingCurrentWeek(result) else { return }
        guard let calendar = store.calendar,
              calendar.currentWeek > 0,
              let semester = calendar.currentSemester.nilIfEmpty,
              let week = calendar.weeks.first(where: { $0.week == calendar.currentWeek }),
              let today = todayDate,
              week.days.contains(today) else {
            store.selectedSemester = ""
            store.selectedWeek = ""
            selectedDay = chinaWeekday
            didInitializeDay = true
            Task {
                await store.load(semester: nil, week: nil, force: true)
            }
            return
        }
        if store.selectedSemester == semester {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
                store.commitWeekSelection(String(calendar.currentWeek))
            }
        } else {
            Task {
                await store.load(semester: semester, week: String(calendar.currentWeek), force: false)
            }
        }
    }

    /// Daily mode has two independent selections: the teaching week and the
    /// weekday page. Returning to the current week alone left the selected
    /// weekday untouched, so the button became a no-op whenever another day
    /// in the same week was open.
    private func jumpToCurrentDay(_ result: NativeScheduleResult) {
        pendingMonthDay = nil
        if let today = todayDate {
            selectedMonthDate = today
            monthAnchor = today
        }
        guard let calendar = store.calendar,
              calendar.currentWeek > 0,
              let semester = calendar.currentSemester.nilIfEmpty,
              let week = calendar.weeks.first(where: { $0.week == calendar.currentWeek }),
              let today = todayDate else {
            selectedDay = chinaWeekday
            didInitializeDay = true
            store.selectedSemester = ""
            store.selectedWeek = ""
            Task { await store.load(semester: nil, week: nil, force: true) }
            return
        }

        let targetDay = week.days.firstIndex(of: today).map { $0 + 1 } ?? chinaWeekday
        let targetWeek = String(calendar.currentWeek)
        guard store.selectedSemester == semester else {
            selectedDay = targetDay
            didInitializeDay = true
            Task { await store.load(semester: semester, week: targetWeek, force: false) }
            return
        }

        didInitializeDay = true
        // 周次与日期在同一动画事务中提交，分页器直接过渡到今日，
        // 避免跨周时先展示目标周的旧星期页。
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
            store.commitWeekSelection(targetWeek)
            selectedDay = targetDay
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
              let today = todayDate,
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
        guard let value = rawDayDate(day, week: week, result: result), let today = todayDate else {
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

    /// 这一天的作息（季节作息表已经换算过）；不知道日期时用当前显示的作息。
    private func periodSlots(on date: String?) -> [ScheduleSlot] {
        date.map { date in
            store.periods(on: date).map { ScheduleSlot(number: $0.number, start: $0.startTime, end: $0.endTime) }
        } ?? ScheduleSlot.all
    }

    private func weekNumber(_ value: String) -> Int? {
        Int(value.trimmingCharacters(in: .whitespaces))
    }

    private func shortDate(_ value: String) -> String {
        let pieces = value.split(separator: "-")
        guard pieces.count >= 3 else { return value }
        return "\(pieces[pieces.count - 2]).\(pieces[pieces.count - 1])"
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

    /// 纯派生数据缓存，不发布视图变化；课程、调休或节次数改变后自动失效。
    private final class CourseBlockCache {
        var storeID: ObjectIdentifier?
        var revision: Date?
        var slotCount = 0
        var values: [String: [NativeScheduleCourseBlock]] = [:]
    }

    private func blocks(for day: Int, week: Int?, result: NativeScheduleResult) -> [NativeScheduleCourseBlock] {
        let cache = courseBlockCache
        if cache.storeID != ObjectIdentifier(store) || cache.revision != store.lastUpdatedAt
            || cache.slotCount != ScheduleSlot.all.count {
            cache.values.removeAll(keepingCapacity: true)
            cache.storeID = ObjectIdentifier(store)
            cache.revision = store.lastUpdatedAt
            cache.slotCount = ScheduleSlot.all.count
        }
        let key = "\(week.map(String.init) ?? "-")/\(day)"
        if let cached = cache.values[key] { return cached }
        let computed = makeBlocks(for: day, week: week, result: result)
        cache.values[key] = computed
        return computed
    }

    private func makeBlocks(for day: Int, week: Int?, result: NativeScheduleResult) -> [NativeScheduleCourseBlock] {
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
        return NativeScheduleCourseBlock.resolvingDisplayPriorities(merged)
    }

    /// Horizontal page margin of the scrolling content.
    private static let contentInset: CGFloat = 16
    private static let slotAxisWidth: CGFloat = 42
    private var styleColumnGap: CGFloat { style == .minimal || style == .grid ? 5 : 0 }
    /// 周视图面板内边距：面板和第一行、最后一列之间留的那一点白。分享图也用它。
    static let panelPadding: CGFloat = 6
    /// 表格的格线贴着面板边画，表格外框就是面板的边；留了内边距会和面板细边套成两层框。
    private var stylePanelPadding: CGFloat { style == .table ? 0 : Self.panelPadding }
    /// 周次 / 月份那一行的高度，三种视图共用，切换时顶栏不跳。
    private static let navigatorHeight: CGFloat = 36
    /// 周次 / 月份标题比页边再往里缩一点：下面的面板是圆角，贴着页边的字会显得比面板靠外。
    private static let navigatorTitleInset: CGFloat = 8
    /// 周次 / 月份标题的字体跟课表风格走；简约保持系统默认字体。
    private var navigatorTitleDesign: Font.Design? { style == .minimal ? nil : style.textDesign }
    /// 素笺和站牌有自己的底色，日期范围用墨色减淡，不用系统的灰。
    private var navigatorSecondary: AnyShapeStyle {
        style == .paper || style == .board
            ? AnyShapeStyle(style.inkColor(dark: colorScheme == .dark).opacity(0.62)) : AnyShapeStyle(.secondary)
    }

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

    /// Every day column asks for today's date, three pager pages at a time, so
    /// the formatter is built once instead of on each body evaluation.
    private static let todayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = NativeScheduleStore.fallbackTimeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Today in the displayed timetable's zone, not the phone's.
    private var todayDate: String? {
        if Self.todayFormatter.timeZone != store.timeZone { Self.todayFormatter.timeZone = store.timeZone }
        return Self.todayFormatter.string(from: .now)
    }

    private var chinaWeekday: Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = store.timeZone
        let weekday = calendar.component(.weekday, from: .now)
        return weekday == 1 ? 7 : weekday - 1
    }
}

private enum SurfaceViewMode: String, Hashable {
    case week
    case day
    case month
}


struct SelectedCourse: Identifiable {
    let id = UUID()
    let course: NativeScheduleCourse
    let day: Int
    let bigSlot: Int
    let startSlot: Int
    let endSlot: Int
    /// 「周一 · 第 1–2 节 · 08:00–09:40」，课程速览的第二行。自由时间课程为 nil。
    var schedule: String? = nil
    /// 轻点卡片打开：先给速览，不直接进编辑。
    var quickLook = false
}

private struct AddCourseContext: Identifiable {
    let id = UUID()
    let day: Int
    let week: Int
    let startSlot: Int
}

private struct NativeScheduleDayPage: Hashable {
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
                    .foregroundStyle(.themeText)
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
        .background { ScheduleSurface(cornerRadius: 16, isCard: true) }
    }
}

/// 周视图里节次之间的细分隔线，横穿节次轴以外的整行；表头下面也有一条。
private struct ScheduleRowRules: View {
    @Environment(\.colorScheme) private var colorScheme
    let headerHeight: CGFloat
    let rowHeight: CGFloat
    let slotCount: Int
    let leading: CGFloat

    var body: some View {
        let step = rowHeight + NativeScheduleDayColumn.slotGap
        let color = Color.scheduleCellBorder(dark: colorScheme == .dark)
        Canvas { context, size in
            var path = Path()
            var lines: [CGFloat] = headerHeight > 0 ? [headerHeight - 0.5] : []
            for index in 1..<max(1, slotCount) {
                lines.append(headerHeight + CGFloat(index) * step - NativeScheduleDayColumn.slotGap / 2)
            }
            for y in lines {
                path.move(to: CGPoint(x: leading, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            // 分隔线更轻，让网格透气但保持清晰
            context.stroke(path, with: .color(color), lineWidth: 0.33)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 节次轴上的「现在」：主题色胶囊里写当前时刻，盖住下面的节次文字。
private struct ScheduleNowBadge: View {
    static let height: CGFloat = 16
    let minutes: Int

    var body: some View {
        Text(String(format: "%d:%02d", minutes / 60, minutes % 60))
            .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(.themeOnFill)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 4)
            .frame(height: Self.height)
            .background(.themeFill, in: Capsule())
    }
}

/// 今天那一列上的「现在」：主题色细线，左端一个小圆点。
private struct ScheduleNowLine: View {
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(.themeText)
                .frame(width: width, height: 1.5)
            Circle()
                .fill(.themeFill)
                .frame(width: 7, height: 7)
                .offset(x: -3.5)
        }
        .frame(width: width, height: 7, alignment: .leading)
        .offset(y: -3.5)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

#Preview {
    Text("NativeScheduleView requires a NativeScheduleStore")
}

/// 按需创建可见页，页标识直接对应周次/日期；不替换正在滚动的三页轨道。
private struct SchedulePagingScrollView<PageID: Hashable, Content: View>: View {
    let pages: [PageID]
    let singlePageJumps: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: PageID
    let width: CGFloat
    @ViewBuilder let content: (PageID) -> Content

    @State private var visiblePage: PageID?
    @State private var jump: Jump?
    @State private var jumpProgress: CGFloat = 0

    private struct Jump {
        let id = UUID()
        let from: PageID
        let to: PageID
        let direction: CGFloat
    }

    init(pages: [PageID], singlePageJumps: Bool = false, selection: Binding<PageID>, width: CGFloat,
         @ViewBuilder content: @escaping (PageID) -> Content) {
        self.pages = pages
        self.singlePageJumps = singlePageJumps
        self._selection = selection
        self.width = width
        self.content = content
        self._visiblePage = State(initialValue: selection.wrappedValue)
    }

    var body: some View {
        pager
        // 页标识变化时立即同步周次/日期；连续拖动或反向滑动无需等待 idle。
        // 自由时间入口尺寸固定，更新周次不会再触发整个课表的横幅过渡。
        .onChange(of: visiblePage) { _, _ in commitVisiblePage() }
        .opacity(jump == nil ? 1 : 0)
        .overlay(alignment: .topLeading) {
            if let jump {
                ZStack(alignment: .topLeading) {
                    content(jump.from)
                        .frame(width: width, alignment: .topLeading)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .offset(x: -jump.direction * width * jumpProgress)
                    content(jump.to)
                        .frame(width: width, alignment: .topLeading)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .offset(x: jump.direction * width * (1 - jumpProgress))
                }
                .frame(width: width, alignment: .topLeading)
                // 与真实分页器共用顶部基线；短课表不能在全节次视口里居中。
                .frame(maxHeight: .infinity, alignment: .top)
                .clipped()
                .accessibilityHidden(true)
            }
        }
        .allowsHitTesting(jump == nil)
        .onChange(of: selection) { _, target in
            guard visiblePage != target else { return }
            if singlePageJumps, !reduceMotion,
               let source = visiblePage,
               let from = pages.firstIndex(of: source),
               let to = pages.firstIndex(of: target), abs(to - from) > 1 {
                animateSinglePage(from: source, to: target, forward: to > from)
            } else {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
                    visiblePage = target
                }
            }
        }
    }

    private func animateSinglePage(from source: PageID, to target: PageID, forward: Bool) {
        let transition = Jump(from: source, to: target, direction: forward ? 1 : -1)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            jump = transition
            jumpProgress = 0
            // 真正的分页器在遮盖下定位，画面仅展示出发页和本周这一对相邻页。
            visiblePage = target
        }
        Task { @MainActor in
            await Task.yield()
            guard jump?.id == transition.id else { return }
            withAnimation(.easeInOut(duration: 0.35), completionCriteria: .removed) {
                jumpProgress = 1
            } completion: {
                guard jump?.id == transition.id else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { jump = nil }
            }
        }
    }

    private func commitVisiblePage() {
        guard jump == nil, let visiblePage, pages.contains(visiblePage), visiblePage != selection else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { selection = visiblePage }
    }

    private var pager: some View {
        GeometryReader { viewport in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 0) {
                    ForEach(pages, id: \.self) { id in
                        content(id)
                            .frame(width: width, height: viewport.size.height, alignment: .topLeading)
                            .id(id)
                            .accessibilityHidden(id != (visiblePage ?? selection))
                    }
                }
                // 固定跨轴高度，避免 LazyHStack 保留较高页面的高度，
                // 在切到短课表后让横向分页器也能上下滚动、抢走外层回弹。
                .frame(height: viewport.size.height, alignment: .top)
                .scrollTargetLayout()
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $visiblePage)
        }
        .frame(width: width, alignment: .leading)
        .clipped()
    }

}

/// 仅在用户切换课表时截取当前可见区域，过渡结束后释放图片。
@MainActor
private final class ScheduleTransitionCapture {
    #if canImport(UIKit)
    weak var anchor: UIView?

    func snapshot() -> PlatformImage? {
        guard let anchor, let window = anchor.window,
              anchor.bounds.width > 0, anchor.bounds.height > 0 else { return nil }
        // 只截取课表所在的控制器，避免把正在收起的菜单一起截入旧画面。
        var root = anchor
        while !(root.next is UIViewController), let parent = root.superview {
            root = parent
        }
        let rect = anchor.convert(anchor.bounds, to: root)
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { _ in
            root.drawHierarchy(in: root.bounds.offsetBy(dx: -rect.minX, dy: -rect.minY),
                               afterScreenUpdates: false)
        }
    }
    #elseif canImport(AppKit)
    weak var anchor: NSView?

    func snapshot() -> PlatformImage? {
        guard let anchor, let content = anchor.window?.contentView,
              anchor.bounds.width > 0, anchor.bounds.height > 0 else { return nil }
        let rect = anchor.convert(anchor.bounds, to: content)
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        content.cacheDisplay(in: rect, to: bitmap)
        let image = NSImage(size: rect.size)
        image.addRepresentation(bitmap)
        return image
    }
    #endif
}

#if canImport(UIKit)
private struct ScheduleTransitionAnchor: UIViewRepresentable {
    let capture: ScheduleTransitionCapture

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        capture.anchor = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { capture.anchor = view }
}
#elseif canImport(AppKit)
private struct ScheduleTransitionAnchor: NSViewRepresentable {
    let capture: ScheduleTransitionCapture

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        capture.anchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { capture.anchor = view }
}
#endif

/// 自定义顶栏位于滚动容器外，显式按滚动距离渐隐，不依赖系统边缘效果是否显示。
/// 使用透明度遮罩，背景图片仍可透过渐隐区域显示。
@Observable
private final class ScheduleScrollFadeState {
    var height: CGFloat = 0
}

struct ScheduleScrollTopFade: ViewModifier {
    /// 月视图按分页边界计算滚动距离，翻月停稳后恢复清晰的面板上沿。
    var pageHeight: CGFloat? = nil
    private static let maxFade: CGFloat = 20
    @State private var fade = ScheduleScrollFadeState()

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content
                .appSoftTopScrollEdge()
                .mask { ScheduleScrollFadeMask(fade: fade) }
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    let offset = geometry.contentOffset.y + geometry.contentInsets.top
                    if let pageHeight, pageHeight > 0 {
                        let distance = abs(offset - (offset / pageHeight).rounded() * pageHeight)
                        return min(distance, Self.maxFade)
                    }
                    return min(max(offset, 0), Self.maxFade)
                } action: { _, value in
                    fade.height = value
                }
        } else {
            // 拿不到滚动位置时只渐隐内容上方那 8pt 留白，静止时同样不碰面板。
            content.mask { ScheduleScrollFadeMask(fixedHeight: 8) }
        }
    }
}

/// 滚动位置只更新这个遮罩，不让整个滚动容器跟着逐帧刷新。
private struct ScheduleScrollFadeMask: View {
    var fade: ScheduleScrollFadeState? = nil
    var fixedHeight: CGFloat = 0

    var body: some View {
        // 渐隐只改变绘制，不改变遮罩的布局。随滚动修改子视图高度会触发
        // ScrollView 重新布局，把尚在拖动的底部回弹位置反复归零。
        Canvas { context, size in
            let height = min(fade?.height ?? fixedHeight, size.height)
            context.fill(
                Path(CGRect(x: 0, y: height, width: size.width, height: size.height - height)),
                with: .color(.black)
            )
            if height > 0 {
                context.fill(
                    Path(CGRect(x: 0, y: 0, width: size.width, height: height)),
                    with: .linearGradient(
                        Gradient(colors: [.clear, .black]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: 0, y: height)
                    )
                )
            }
        }
        // 课表会滚到 tab 栏和横屏两侧的安全区里，遮罩只按滚动视图的布局尺寸画
        // 就会把那一截裁掉。上沿紧贴顶栏，不需要外扩。
        .ignoresSafeArea(edges: [.horizontal, .bottom])
    }
}

/// 月视图固定外框，由内部分页器处理滚动和底部安全区；日/周保留纵向滚动。
private struct ScheduleOuterContainer<Content: View>: View {
    let scrolls: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        if scrolls {
            ScrollView(.vertical, showsIndicators: false, content: content)
                .scrollBounceBehavior(.always, axes: .vertical)
                .modifier(ScheduleScrollTopFade())
        } else {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}
