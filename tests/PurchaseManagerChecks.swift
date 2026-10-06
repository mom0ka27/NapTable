import Foundation
import StoreKit

@MainActor final class ScheduleSharingService {
    static let shared = ScheduleSharingService()
    var validatedBaseURL: URL? { URL(string: "https://example.invalid") }
}

@main struct PurchaseManagerChecks {
    @MainActor static func main() async throws {
        let suite = "naptable.purchase.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let beta = Data(#"{"requireEntitlement":false}"#.utf8)
        let paid = Data(#"{"requireEntitlement":true}"#.utf8)
        let betaMode = try PurchaseManager.AccessMode.decode(beta)
        let paidMode = try PurchaseManager.AccessMode.decode(paid)
        precondition(betaMode == .beta && paidMode == .paid)
        for malformed in [#"{}"#, #"{"requireEntitlement":"false"}"#] {
            do {
                _ = try PurchaseManager.AccessMode.decode(Data(malformed.utf8))
                preconditionFailure("Malformed policy must never enable free access")
            } catch { }
        }
        var mode = 0
        var requests: [URLRequest] = []
        let manager = PurchaseManager(defaults: defaults) { request in
            requests.append(request)
            if mode == 1 { throw URLError(.notConnectedToInternet) }
            let body = mode == 2 ? Data(#"{}"#.utf8) : beta
            return (body, HTTPURLResponse(url: request.url!, statusCode: mode == 3 ? 503 : 200,
                                         httpVersion: nil, headerFields: nil)!)
        }
        precondition(!manager.allowsLiveActivities)
        await manager.load()
        precondition(manager.isBeta && manager.allowsLiveActivities)
        precondition(manager.state == .loading && manager.products.isEmpty,
                     "Beta must return before loading StoreKit products or entitlements")
        await manager.beginTrial()
        await manager.buyLifetime()
        let betaRestore = await manager.restore()
        precondition(betaRestore == nil && !manager.restoring && manager.state == .loading,
                     "Beta has nothing to restore and must not ask StoreKit")
        precondition(!manager.busy && manager.errorMessage == nil)
        precondition(!manager.trialConsumed && manager.pendingTransactions().isEmpty)
        precondition(defaults.persistentDomain(forName: suite)?.isEmpty ?? true,
                     "Beta must not consume or persist a trial")
        for failedMode in [1, 2, 3] {
            mode = failedMode
            await manager.load()
            precondition(manager.accessMode == .unavailable && !manager.allowsLiveActivities,
                         "A failed policy refresh must not reuse a stale Beta grant")
        }
        let offlineRestore = await manager.restore()
        precondition(offlineRestore == .failed("连接失败，请联网后重试。") && !manager.restoring,
                     "Restoring without the server policy must ask to reconnect")
        // 恢复购买的失败原因：取消不提示，断网和其他原因各一句人话。
        precondition(PurchaseManager.restoreFailure(StoreKitError.userCancelled) == nil,
                     "Cancelling the Apple ID prompt is not a failure")
        let offline = PurchaseManager.restoreFailure(StoreKitError.networkError(URLError(.notConnectedToInternet)))
        precondition(offline != nil && offline == PurchaseManager.restoreFailure(URLError(.timedOut)))
        for error in [StoreKitError.unknown, .notEntitled, .systemError(CocoaError(.fileReadUnknown))] {
            let outcome = PurchaseManager.restoreFailure(error)
            guard case .failed(let reason)? = outcome, !reason.isEmpty, outcome != offline else {
                preconditionFailure("Other StoreKit failures need their own sentence")
            }
        }
        mode = 0
        await manager.load()
        precondition(manager.isBeta && manager.allowsLiveActivities)
        precondition(requests.allSatisfy {
            $0.url?.path == "/v1/entitlements/settings" && $0.httpMethod == "GET"
                && $0.httpBody == nil && $0.value(forHTTPHeaderField: "X-Device-Secret") == nil
                && $0.cachePolicy == .reloadIgnoringLocalCacheData
        })
        print("PASS: Beta policy, StoreKit bypass, no trial consumption, failed policy/retry, paid mode decoding, restore outcomes")
    }
}
