import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Mounted after onboarding. Checks again while foregrounded so a reminder
/// deferred by a class or an editor can appear at the next quiet opportunity.
struct AutomaticReminderHost: ViewModifier {
    private enum Presentation: Identifiable {
        case trial(TrialReminder)
        case announcement(AppAnnouncement, source: String)
        var id: String {
            switch self {
            case .trial(let item): return "trial:" + item.id
            case .announcement(let item, let source): return source + item.historyID
            }
        }
    }
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var purchases = PurchaseManager.shared
    @ObservedObject private var announcements = AnnouncementStore.shared
    @ObservedObject private var cloudSync = ICloudSyncService.shared
    @ObservedObject var scheduleStore: NativeScheduleStore
    let isBlocked: Bool
    @State private var reminder: Presentation?
    @State private var anchor = TrialReminderPresentationAnchor()

    func body(content: Content) -> some View {
        content
            .background { TrialReminderPresentationProbe(anchor: anchor).allowsHitTesting(false) }
            .sheet(item: $reminder) { item in
                NavigationStack {
                    switch item {
                    case .trial(let trial):
                        SubscriptionView(reminder: trial)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("关闭", systemImage: "xmark") { reminder = nil }
                                }
                            }
                    case .announcement(let announcement, _):
                        AnnouncementView(item: announcement)
                    }
                }
                #if os(macOS)
                .frame(minWidth: 520, minHeight: 680)
                #else
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                #endif
                .onAppear {
                    AnnouncementPolicy.markAutomatic()
                    switch item {
                    case .trial(let trial): TrialReminderPolicy.markPresented(trial)
                    case .announcement(let announcement, let source): AnnouncementPolicy.markSeen(announcement, source: source)
                    }
                }
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                do {
                    while !Task.isCancelled {
                        await announcements.refresh()
                        try await Task.sleep(for: .seconds(300))
                    }
                } catch { }
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
                if state == .lifetime, case .trial = reminder { reminder = nil }
            }
            .onChange(of: purchases.accessMode) { _, mode in
                if mode == .beta, case .trial = reminder { reminder = nil }
            }
    }

    private func evaluate() {
        let now = Date()
        purchases.expireTrialIfNeeded(now: now)
        guard scenePhase == .active, reminder == nil, !isBlocked,
              AnnouncementPolicy.canPresent(now: now),
              !cloudSync.isReviewPresented, !purchases.busy, purchases.errorMessage == nil,
              anchor.canPresent,
              let own = scheduleStore.snapshot(useSharedNotifications: false),
              TrialReminderPolicy.isSafeToPresent(in: own, now: now) else { return }
        // A followed timetable must not replace the reader's own class check.
        if let followed = scheduleStore.snapshot(), followed.sourceLabel != nil,
           !TrialReminderPolicy.isSafeToPresent(in: followed, now: now) { return }
        if let candidate = announcements.pending {
            reminder = .announcement(candidate, source: announcements.source)
        } else if !announcements.isLoading, let candidate = TrialReminderPolicy.pending(
            accessMode: purchases.accessMode, state: purchases.state,
            expiresAt: purchases.trialExpiresAt, now: now
        ) {
            reminder = .trial(candidate)
        }
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
