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
    @State private var showImport = false
    @State private var showSettings = false
    @State private var showDeviceSettings = false

    var body: some View {
        Group {
            #if os(macOS)
            macLayout
            #else
            phoneLayout
            #endif
        }
        .preferredColorScheme(store.settings.appearance.colorScheme)
        .sheet(isPresented: $showImport) {
            ImportView()
                .environmentObject(store)
                .environmentObject(scheduleStore)
                .preferredColorScheme(store.settings.appearance.colorScheme)
        }
        .sheet(isPresented: $showDeviceSettings) {
            NativeDeviceSettingsView(scheduleStore: scheduleStore, widgetSettings: widgetSettings)
                .preferredColorScheme(store.settings.appearance.colorScheme)
        }
        // The widgets and the Live Activity read the same native snapshot the
        // timetable renders, so every rebuild is pushed to them. NapTable has
        // no session to check: the write is local and cheap.
        .onChange(of: scheduleStore.lastUpdatedAt) { _, _ in
            syncCompanionFeatures()
        }
        .onReceive(NotificationCenter.default.publisher(for: .naptableFollowedSourceChanged)) { _ in
            Task { await scheduleStore.refresh(); syncCompanionFeatures() }
        }
        .onAppear { syncCompanionFeatures() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            // A followed share lives on the server, so the companion surfaces
            // can go stale while the app sits in the background. The refresh
            // is a small meta request unless the share actually moved.
            Task { await ScheduleSharingService.shared.refreshFollowed() }
            #if os(iOS)
            NativeLiveActivityController.shared.foreground()
            #endif
        }
        #if DEBUG
        // A headless simulator cannot tap the header menu, so the debug hook
        // opens the device settings directly. Same idea as the surface's
        // `NAPTABLE_DEBUG_SHEET`.
        .task {
            guard ProcessInfo.processInfo.environment["NAPTABLE_DEBUG_DEVICE"] != nil else { return }
            try? await Task.sleep(for: .milliseconds(700))
            showDeviceSettings = true
        }
        #endif
    }

    /// The surface brings its own header, so it only has to be told about the
    /// app store before its first render.
    private var timetable: some View {
        VStack(spacing: 0) {
            if let source = scheduleStore.sourceLabel, !source.isEmpty {
                HStack {
                    Image(systemName: "eye")
                    Text("提示来源：\(source)")
                    Spacer()
                    Text("只读")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.thinMaterial)
            }
            NativeScheduleView(store: scheduleStore, onWidgets: { showDeviceSettings = true })
                .tint(themeSettings.brandColor)
        }
        .onAppear { scheduleStore.connect(store) }
    }

    private func syncCompanionFeatures() {
        guard let snapshot = scheduleStore.snapshot() else {
            #if os(iOS)
            NativeLiveActivityController.shared.reset()
            #endif
            return
        }
        widgetSettings.writePayload(from: snapshot, selectedWeek: Int(scheduleStore.selectedWeek))
        #if os(iOS)
        if snapshot.auth.authenticated,
           snapshot.data?.cells.contains(where: { !$0.courses.isEmpty }) == true {
            NativeLiveActivityController.shared.accept(snapshot)
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
        TabView {
            timetable
                .tabItem { Label("课表", systemImage: "calendar") }

            NavigationStack {
                SettingsView(
                    showImport: $showImport,
                    scheduleStore: scheduleStore,
                    widgetSettings: widgetSettings
                )
            }
            .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .tint(themeSettings.brandColor)
    }
    #endif
}
