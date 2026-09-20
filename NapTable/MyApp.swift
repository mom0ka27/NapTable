import SwiftUI

@main
struct MyApp: App {
    @StateObject private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if os(iOS)
        // Background task identifiers must be registered before launch ends.
        if #available(iOS 17.0, *) {
            LiveActivityBackgroundRefresh.shared.register()
        }
        // A push-to-start launches the app in the background, and the update
        // token for the activity the system just created only reaches a
        // running app, so the observers start here rather than on first view.
        if #available(iOS 17.2, *) {
            LiveActivityPushService.shared.activate()
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .task {
                    store.seedSampleIfNeeded()
                    await ScheduleSharingService.shared.refreshCurrentTerms(in: store)
                    store.refreshForToday()
                }
                .onChange(of: scenePhase) { phase in
                    // `WeekUtil.checkWeek()` ran on every foreground: a week can
                    // roll over while the app sits in the background.
                    if phase == .active {
                        store.refreshForToday()
                        Task { await ScheduleSharingService.shared.refreshCurrentTerms(in: store) }
                        #if os(iOS)
                        if #available(iOS 17.2, *) {
                            Task { await LiveActivityPushService.shared.refreshStatus() }
                        }
                        #endif
                    }
                }
        }
        #if os(macOS)
        .defaultSize(width: 900, height: 720)
        #endif
    }
}
