import SwiftUI

/// The app shell: the timetable and the settings screen.
///
/// The Flutter app reached settings through an app bar button next to the
/// timetable; on iPhone that is a tab so both surfaces are one tap away, and on
/// the Mac the same two views sit side by side.
///
/// The timetable itself is the CpuTime `NativeScheduleView` surface (see
/// `Schedule/ScheduleSurfaceView.swift`), fed by `NativeScheduleStore`.
struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var scheduleStore = NativeScheduleStore()
    @StateObject private var widgetSettings = NativeWidgetSettings()
    @StateObject private var themeSettings = NativeThemeSettings.shared
    @ObservedObject private var purchases = PurchaseManager.shared
    @State private var showImport = false
    @State private var showSettings = false
    @State private var selectedTab = 0
    @State private var showLiveActivityDismissal = false
    @State private var dismissalOccurrence = ""
    @State private var restorationFailure: String?

    var body: some View {
        Group {
            #if os(macOS)
            macLayout
            #else
            phoneLayout
            #endif
        }
        .preferredColorScheme(store.settings.appearance.colorScheme)
        .modifier(AutomaticReminderHost(
            scheduleStore: scheduleStore,
            isBlocked: selectedTab != 0 || showImport || showSettings
                || showLiveActivityDismissal || restorationFailure != nil
        ))
        .onChange(of: purchases.accessMode, initial: true) { _, _ in updateWidgetBackgroundAccess() }
        .onChange(of: purchases.state) { _, _ in updateWidgetBackgroundAccess() }
        .appImportPresentation(isPresented: $showImport) {
            ImportView()
                .environmentObject(store)
                .environmentObject(scheduleStore)
                .preferredColorScheme(store.settings.appearance.colorScheme)
        }
        // Schedule edits update both companion surfaces. Caring changes only
        // the Live Activity source; the displayed timetable and widgets stay put.
        .task(id: scheduleStore.lastUpdatedAt) {
            // Let the first render proceed and coalesce updates from the initial connection.
            await Task.yield()
            guard !Task.isCancelled else { return }
            syncCompanionFeatures()
        }
        .onReceive(NotificationCenter.default.publisher(for: .naptableFollowedSourceChanged)) { _ in
            Task { await scheduleStore.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .naptableCaringSelectionChanged)) { _ in
            Task { @MainActor in
                syncCompanionFeatures(updateWidgets: false)
            }
        }
        .onAppear {
            scheduleStore.connect(store)
            if store.tables.isEmpty && ScheduleSharingService.shared.sharedSchedules.isEmpty { showImport = true }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            #if os(iOS)
            if phase == .active {
                NativeLiveActivityController.shared.foreground()
            } else {
                NativeLiveActivityController.shared.leaveForeground()
            }
            #endif
            guard phase == .active else { return }
            // A followed share lives on the server, so the companion surfaces
            // can go stale while the app sits in the background. The refresh
            // is a small meta request unless the share actually moved.
            Task { await ScheduleSharingService.shared.refreshFollowed() }
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            NativeLiveActivityController.shared.resumeReminderRestoration()
        }
        #endif
        #if os(iOS)
        .onReceive(NativeLiveActivityController.shared.$dismissedOccurrence) { occurrence in
            guard let occurrence else {
                showLiveActivityDismissal = false
                dismissalOccurrence = ""
                return
            }
            dismissalOccurrence = occurrence
            showLiveActivityDismissal = true
        }
        .alert("实时活动似乎被关闭了", isPresented: $showLiveActivityDismissal) {
            Button("继续提醒") {
                NativeLiveActivityController.shared.continueDismissedReminder()
            }
            .keyboardShortcut(.defaultAction)
            // Supply the alert's cancel action so SwiftUI does not add an English Cancel button.
            Button("本节课不再提醒", role: .cancel) {
                NativeLiveActivityController.shared.suppressDismissal(for: dismissalOccurrence, permanently: false)
            }
            Button("永不提醒", role: .destructive) {
                NativeLiveActivityController.shared.suppressDismissal(for: dismissalOccurrence, permanently: true)
            }
        } message: {
            Text("实时活动可以在灵动岛和锁定屏幕上显示课程进度。是否继续显示？选择“永不提醒”会关闭实时活动的功能，可在设置中重新开启。")
        }
        .onReceive(NativeLiveActivityController.shared.$restorationFailure) { restorationFailure = $0 }
        .alert("未能恢复实时活动", isPresented: Binding(
            get: { restorationFailure != nil },
            set: { if !$0 { restorationFailure = nil; NativeLiveActivityController.shared.clearRestorationFailure() } }
        )) {
            Button("知道了", role: .cancel) { NativeLiveActivityController.shared.clearRestorationFailure() }
        } message: {
            Text(restorationFailure ?? "")
        }
        #endif
    }

    /// The surface brings its own header, so it only has to be told about the
    /// app store before its first render.
    private var timetable: some View {
        VStack(spacing: 0) {
            if store.tables.isEmpty {
                ContentUnavailableView {
                    Label("从你的学校开始", systemImage: "graduationcap")
                } description: {
                    Text("选择学校，导入你的第一张课表。")
                } actions: {
                    Button("添加课表") { showImport = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                NativeScheduleView(store: scheduleStore, onAddTable: { showImport = true })
                    .tint(themeSettings.brandColor)
            }
        }
        .onAppear { scheduleStore.connect(store) }
    }

    private func updateWidgetBackgroundAccess() {
        // Keep the last verified access while policy or StoreKit is loading.
        guard purchases.accessMode != .loading,
              purchases.accessMode != .paid || purchases.state != .loading else { return }
        let expiry: Date?
        if !purchases.isBeta, case .trial(let expiresAt) = purchases.state { expiry = expiresAt }
        else { expiry = nil }
        widgetSettings.updateBackgroundAccess(purchases.allowsProFeatures, expiresAt: expiry)
    }

    private func syncCompanionFeatures(updateWidgets: Bool = true) {
        guard let snapshot = scheduleStore.snapshot() else {
            #if os(iOS)
            NativeLiveActivityController.shared.reset()
            #endif
            return
        }
        let ownSnapshot = scheduleStore.snapshot(useSharedNotifications: false)
        if updateWidgets, let ownSnapshot {
            widgetSettings.writePayload(from: ownSnapshot, selectedWeek: store.displayWeek)
        }
        #if os(iOS)
        if snapshot.auth.authenticated,
           snapshot.data?.cells.contains(where: { !$0.courses.isEmpty }) == true {
            // While following a share, the reader's own table is passed along
            // so a class of theirs at the same time shows up next to the share.
            NativeLiveActivityController.shared.accept(snapshot, own: snapshot.sourceLabel == nil ? nil : ownSnapshot)
        } else {
            NativeLiveActivityController.shared.reset()
        }
        #endif
    }

    #if os(macOS)
    private var macLayout: some View {
        NavigationSplitView {
            List {
                Label("课表", systemImage: "calendar")
                Button {
                    showSettings = true
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
                Button {
                    showImport = true
                } label: {
                    Label("导入课表", systemImage: "square.and.arrow.down")
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            timetable
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                showImport: $showImport,
                scheduleStore: scheduleStore,
                widgetSettings: widgetSettings
            )
                .environmentObject(store)
                .frame(minWidth: 520, minHeight: 640)
                .preferredColorScheme(store.settings.appearance.colorScheme)
        }
        .tint(themeSettings.brandColor)
    }
    #else
    private var phoneLayout: some View {
        TabView(selection: $selectedTab) {
            timetable
                .tabItem { Label("课表", systemImage: "calendar") }
                .tag(0)

            NavigationStack {
                SettingsView(
                    showImport: $showImport,
                    scheduleStore: scheduleStore,
                    widgetSettings: widgetSettings
                )
            }
            .tabItem { Label("设置", systemImage: "gearshape") }
            .tag(1)
        }
        .tint(themeSettings.brandColor)
    }
    #endif
}
