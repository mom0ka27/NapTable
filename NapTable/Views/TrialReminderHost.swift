import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Mounted after onboarding. Checks again while foregrounded so a reminder
/// deferred by a class or an editor can appear at the next quiet opportunity.
struct TrialReminderHost: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var purchases = PurchaseManager.shared
    @ObservedObject private var cloudSync = ICloudSyncService.shared
    @ObservedObject var scheduleStore: NativeScheduleStore
    let isBlocked: Bool
    @State private var reminder: TrialReminder?
    @State private var anchor = TrialReminderPresentationAnchor()

    func body(content: Content) -> some View {
        content
            .background { TrialReminderPresentationProbe(anchor: anchor).allowsHitTesting(false) }
            .sheet(item: $reminder) { item in
                NavigationStack {
                    SubscriptionView(reminder: item)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("关闭", systemImage: "xmark") { reminder = nil }
                            }
                        }
                }
                #if os(macOS)
                .frame(minWidth: 520, minHeight: 680)
                #else
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                #endif
                .onAppear { TrialReminderPolicy.markPresented(item) }
            }
            // Restart when the parent changes tabs or presentation state; a
            // running task otherwise retains the old value of `isBlocked`.
            .task(id: [scenePhase == .active, isBlocked]) {
                guard scenePhase == .active else { return }
                purchases.expireTrialIfNeeded()
                do {
                    // Give launch, import and cloud review presentations priority.
                    try await Task.sleep(for: .seconds(3))
                    while !Task.isCancelled {
                        evaluate()
                        try await Task.sleep(for: .seconds(15))
                    }
                } catch { /* Backgrounding cancels this foreground-only task. */ }
            }
            .onChange(of: purchases.state) { _, state in
                if state == .lifetime { reminder = nil }
            }
            .onChange(of: purchases.accessMode) { _, mode in
                if mode == .beta { reminder = nil }
            }
    }

    private func evaluate() {
        let now = Date()
        purchases.expireTrialIfNeeded(now: now)
        guard scenePhase == .active, reminder == nil, !isBlocked,
              !cloudSync.isReviewPresented, !purchases.busy, purchases.errorMessage == nil,
              let candidate = TrialReminderPolicy.pending(
                accessMode: purchases.accessMode, state: purchases.state,
                expiresAt: purchases.trialExpiresAt, now: now
              ), anchor.canPresent,
              let own = scheduleStore.snapshot(useSharedNotifications: false),
              TrialReminderPolicy.isSafeToPresent(in: own, now: now) else { return }
        // A followed timetable must not replace the reader's own class check.
        if let followed = scheduleStore.snapshot(), followed.sourceLabel != nil,
           !TrialReminderPolicy.isSafeToPresent(in: followed, now: now) { return }
        reminder = candidate
    }
}

/// Inspect this scene's actual presentation chain, including sheets owned by
/// course editors and pickers deeper in the timetable view hierarchy.
@MainActor
private final class TrialReminderPresentationAnchor {
    #if canImport(UIKit)
    weak var controller: UIViewController?
    var canPresent: Bool {
        guard let controller, controller.viewIfLoaded?.window?.isKeyWindow == true else { return false }
        var current: UIViewController? = controller
        while let value = current {
            if value.presentedViewController != nil || value.isBeingPresented || value.isBeingDismissed
                || value.transitionCoordinator != nil { return false }
            current = value.parent
        }
        return true
    }
    #else
    weak var view: NSView?
    var canPresent: Bool {
        guard let window = view?.window else { return false }
        return window.isKeyWindow && window.attachedSheet == nil && NSApp.modalWindow == nil
    }
    #endif
}

#if canImport(UIKit)
private struct TrialReminderPresentationProbe: UIViewControllerRepresentable {
    let anchor: TrialReminderPresentationAnchor
    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        anchor.controller = controller
        return controller
    }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
#else
private struct TrialReminderPresentationProbe: NSViewRepresentable {
    let anchor: TrialReminderPresentationAnchor
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
