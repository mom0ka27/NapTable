#if os(iOS)
import BackgroundTasks
import Foundation

/// Bridges the Live Activity controller to `BGTaskScheduler`.
///
/// iOS suspends the app between classes, so the controller's in-process timer
/// cannot dismiss a class that ends while the app is in the background. A
/// background refresh registered for the next course boundary lets the system
/// wake the app just long enough to end — or, when the activity is persistent,
/// advance — the activity without the user opening it.
///
/// The system decides when the task actually runs, so this shortens how long a
/// finished class lingers instead of guaranteeing a dismissal to the second.
@available(iOS 17.0, *)
@MainActor
final class LiveActivityBackgroundRefresh {
    static let shared = LiveActivityBackgroundRefresh()
    static let identifier = "me.mom0ka27.naptable.liveactivity.refresh"

    /// `BGTaskScheduler` rejects a request that is due immediately, and the
    /// in-process timer already covers the next few seconds.
    private static let minimumLeadTime: TimeInterval = 60

    private var pendingDate: Date?
    private var isRegistered = false

    /// Must run before the app finishes launching.
    func register() {
        guard !isRegistered else { return }
        isRegistered = true
        NativeLiveActivityController.shared.scheduleBackgroundWakeup = { [weak self] date in
            self?.schedule(at: date)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: nil) { task in
            let completion = TaskCompletion(task: task)
            let work = Task { @MainActor in
                LiveActivityBackgroundRefresh.shared.pendingDate = nil
                await NativeLiveActivityController.shared.reconcileInBackground()
                completion.finish(success: true)
            }
            task.expirationHandler = {
                work.cancel()
                completion.finish(success: false)
            }
        }
    }

    /// Ask the system to wake the app around `date`. Submitting while the app
    /// is still in the foreground is fine: the request only becomes eligible
    /// once the app is suspended.
    func schedule(at date: Date) {
        let earliest = max(date, Date().addingTimeInterval(Self.minimumLeadTime))
        if let pendingDate, abs(pendingDate.timeIntervalSince(earliest)) < 30 { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
        let request = BGAppRefreshTaskRequest(identifier: Self.identifier)
        request.earliestBeginDate = earliest
        do {
            try BGTaskScheduler.shared.submit(request)
            pendingDate = earliest
        } catch {
            // Background App Refresh can be switched off system-wide or for
            // this app. The activity then reconciles on the next foreground,
            // exactly as it did before.
            pendingDate = nil
        }
    }

    /// `setTaskCompleted(success:)` must be called exactly once, and the
    /// expiration handler can fire on any queue while the work is still
    /// running.
    private final class TaskCompletion: @unchecked Sendable {
        private let task: BGTask
        private let lock = NSLock()
        private var isFinished = false

        init(task: BGTask) { self.task = task }

        func finish(success: Bool) {
            lock.lock()
            let alreadyFinished = isFinished
            isFinished = true
            lock.unlock()
            guard !alreadyFinished else { return }
            task.setTaskCompleted(success: success)
        }
    }
}
#endif
