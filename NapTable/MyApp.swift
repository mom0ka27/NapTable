import SwiftUI

@main
struct MyApp: App {
    @StateObject private var store = AppStore()

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
            if PrivacyPolicy.liveAllowed() {
                LiveActivityPushService.shared.activate()
            } else {
                // An upgraded app may still have older local reservations or
                // server registration; clear them before showing the privacy gate.
                NativeLiveActivityController.shared.setEnabled(false)
            }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            AppEntryView()
                .environmentObject(store)
        }
        #if os(macOS)
        .defaultSize(width: 900, height: 720)
        #endif
    }
}
