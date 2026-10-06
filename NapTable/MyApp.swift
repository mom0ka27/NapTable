import SwiftUI
#if os(iOS)
import ActivityKit
#endif

@main
struct MyApp: App {
    @StateObject private var themeSettings = NativeThemeSettings.shared

    init() {
        #if DEBUG
        // 截图演示只使用内存里的示例课表，不启动购买、推送或实时活动服务。
        if ProcessInfo.processInfo.environment["NAPTABLE_STYLE_DEMO"] == "1" { return }
        #endif
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
                // Retire this device's reminders without overwriting a local
                // preference merely because local consent has not been granted.
                NativeLiveActivityController.shared.refreshLocalPreferences()
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
            rootView
                .environment(\.scheduleStyle, themeSettings.style)
                .environment(\.appThemeBrand, themeSettings.brandRGB)
                .environment(\.appThemeBackgroundEnabled, themeSettings.themeBackgroundEnabled)
                // 主题色挂在根部：各页面挂在外层的 sheet、全屏弹层都从这里继承，不再显示系统蓝。
                .appThemeTint(themeSettings.brandColor)
        }
        #if os(macOS)
        .defaultSize(width: 900, height: 720)
        #endif
    }

    @ViewBuilder
    private var rootView: some View {
        #if DEBUG
        if ProcessInfo.processInfo.environment["NAPTABLE_STYLE_DEMO"] == "1" {
            ScheduleStyleDemoRoot()
        } else {
            NormalAppRoot()
        }
        #else
        NormalAppRoot()
        #endif
    }
}

/// The in-memory Debug gallery never constructs the normal app's stores or starts sync.
private struct NormalAppRoot: View {
    @StateObject private var store = AppStore()

    var body: some View {
        AppEntryView().environmentObject(store)
    }
}
