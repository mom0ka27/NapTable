import SwiftUI
#if os(iOS)
import ActivityKit
#endif

@main
struct MyApp: App {
    @StateObject private var store = AppStore()

    init() {
        PurchaseManager.shared.start()
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
        #if DEBUG
        Self.startDebugLiveActivity()
        #endif
        #endif
    }

    #if DEBUG && os(iOS)
    /// 预览画廊拿系统真实渲染当参照：`SIMCTL_CHILD_NAPTABLE_DEBUG_LIVE_ACTIVITY=<ContentState JSON>`
    /// 启动时直接开一个这样的实时活动（见 `scripts/widget-gallery.sh --reference`）。
    private static func startDebugLiveActivity() {
        guard let raw = ProcessInfo.processInfo.environment["NAPTABLE_DEBUG_LIVE_ACTIVITY"],
              let state = try? JSONDecoder().decode(ScheduleLiveActivityAttributes.ContentState.self, from: Data(raw.utf8)) else { return }
        Task {
            for activity in Activity<ScheduleLiveActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            let attributes = ScheduleLiveActivityAttributes(semester: "__preview__", dateKey: "preview")
            do {
                _ = try Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: nil), pushType: nil)
                print("[debug] live activity started: \(state.courseName)")
            } catch {
                print("[debug] live activity failed: \(error)")
            }
        }
    }
    #endif

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
