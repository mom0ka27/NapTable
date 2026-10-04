import Foundation
import Combine
import StoreKit

/// StoreKit 2 state for the two real-time activity products.
///
/// The free trial is a zero-price non-consumable. StoreKit therefore remembers
/// that it was redeemed, while NapTable applies its 30-day expiry to the
/// transaction's purchase date. The lifetime product never expires.
@MainActor
final class PurchaseManager: ObservableObject {
    static let shared = PurchaseManager()

    static let trialProductID = "com.niyiwei.naptable.live_activity.trial_30d"
    static let lifetimeProductID = "com.niyiwei.naptable.live_activity.lifetime"
    static let trialDuration: TimeInterval = 30 * 24 * 60 * 60

    enum State: Equatable {
        case loading
        case unavailable
        case locked
        case trial(expiresAt: Date)
        case lifetime

        var isEntitled: Bool {
            switch self { case .trial, .lifetime: return true; default: return false }
        }
    }

    enum AccessMode: Equatable {
        case loading, beta, paid, unavailable

        static func decode(_ data: Data) throws -> Self {
            struct Settings: Decodable { let requireEntitlement: Bool }
            return try JSONDecoder().decode(Settings.self, from: data).requireEntitlement ? .paid : .beta
        }
    }

    @Published private(set) var accessMode: AccessMode = .loading
    @Published private(set) var state: State = .loading
    @Published private(set) var products: [Product] = []
    @Published private(set) var trialConsumed = false
    /// Retained after expiry so reminders can distinguish an ended trial from
    /// someone who has never started one. Only verified, unrevoked receipts count.
    @Published private(set) var trialExpiresAt: Date?
    @Published private(set) var busy = false
    @Published var errorMessage: String?

    private static let pendingKey = "naptable.entitlement.pendingTransactions"
    private let defaults: UserDefaults
    private let policyTransport: ((URLRequest) async throws -> (Data, HTTPURLResponse))?
    private var updatesTask: Task<Void, Never>?
    private var loadingTask: Task<Void, Never>?
    private var started = false

    init(defaults: UserDefaults = .standard,
         policyTransport: ((URLRequest) async throws -> (Data, HTTPURLResponse))? = nil) {
        self.defaults = defaults
        self.policyTransport = policyTransport
    }

    deinit { updatesTask?.cancel() }

    var isBeta: Bool { accessMode == .beta }
    private var hasActiveEntitlement: Bool {
        switch state {
        case .lifetime: return true
        case .trial(let expiresAt): return expiresAt > Date()
        default: return false
        }
    }
    var allowsLiveActivities: Bool { isBeta || (accessMode == .paid && hasActiveEntitlement) }

    /// Pro-only display customizations. Beta builds intentionally receive the
    /// same entitlement so they can exercise the complete product surface.
    var allowsProFeatures: Bool { isBeta || (accessMode == .paid && hasActiveEntitlement) }
    var allowsPerTableBackgrounds: Bool { allowsProFeatures }

    func start() {
        guard !started else { return }
        started = true
        Task { [weak self] in await self?.load() }
    }

    private func observeTransactions() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            guard let self else { return }
            for await result in Transaction.updates {
                await self.accept(result, finish: true)
            }
        }
    }

    func load() async {
        if let loadingTask { await loadingTask.value; return }
        let task = Task { await performLoad() }
        loadingTask = task
        await task.value
        loadingTask = nil
    }

    private func performLoad() async {
        accessMode = .loading
        do {
            guard let base = ScheduleSharingService.shared.validatedBaseURL,
                  let url = URL(string: "/v1/entitlements/settings", relativeTo: base) else {
                throw URLError(.badURL)
            }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.timeoutInterval = 15
            let data: Data
            let response: URLResponse
            if let policyTransport { (data, response) = try await policyTransport(request) }
            else { (data, response) = try await URLSession.shared.data(for: request) }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            accessMode = try AccessMode.decode(data)
        } catch {
            accessMode = .unavailable
            return
        }
        // Beta access comes from the server; it creates no StoreKit trial.
        guard accessMode == .paid else {
            updatesTask?.cancel()
            updatesTask = nil
            errorMessage = nil
            return
        }
        observeTransactions()
        do {
            products = try await Product.products(for: [Self.trialProductID, Self.lifetimeProductID])
                .sorted { $0.id < $1.id }
        } catch {
            products = []
        }
        await refreshEntitlements()
        if products.isEmpty && state == .locked { state = .unavailable }
    }

    func refreshEntitlements() async {
        var lifetime = false
        var trialPurchase: Date?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard transaction.revocationDate == nil else { continue }
            if transaction.productID == Self.lifetimeProductID {
                lifetime = true
                queue(transaction, jws: result.jwsRepresentation)
            } else if transaction.productID == Self.trialProductID {
                let purchase = transaction.purchaseDate
                if trialPurchase == nil || purchase < trialPurchase! { trialPurchase = purchase }
                queue(transaction, jws: result.jwsRepresentation)
            }
        }
        // An expired non-consumable trial remains a historical transaction;
        // inspect the history so it cannot be purchased repeatedly.
        var hasHistoricalTrial = trialPurchase != nil
        var reminderPurchase = trialPurchase
        for await result in Transaction.all {
            guard case .verified(let transaction) = result else { continue }
            if transaction.productID == Self.trialProductID {
                hasHistoricalTrial = true
                if transaction.revocationDate == nil,
                   reminderPurchase == nil || transaction.purchaseDate < reminderPurchase! {
                    reminderPurchase = transaction.purchaseDate
                }
                queue(transaction, jws: result.jwsRepresentation)
            }
        }
        trialConsumed = hasHistoricalTrial
        trialExpiresAt = reminderPurchase?.addingTimeInterval(Self.trialDuration)
        if lifetime {
            state = .lifetime
        } else if let purchase = trialPurchase {
            let expires = purchase.addingTimeInterval(Self.trialDuration)
            state = expires > Date() ? .trial(expiresAt: expires) : .locked
        } else {
            state = .locked
        }
    }

    /// A foreground session can span the expiry without another StoreKit event.
    func expireTrialIfNeeded(now: Date = Date()) {
        if case .trial(let expiresAt) = state, expiresAt <= now { state = .locked }
    }

    func beginTrial() async {
        await purchase(Self.trialProductID)
    }

    func buyLifetime() async {
        await purchase(Self.lifetimeProductID)
    }

    private func purchase(_ productID: String) async {
        guard accessMode == .paid else {
            if !isBeta { errorMessage = "连接失败，请联网后重试。" }
            return
        }
        guard let product = products.first(where: { $0.id == productID }) else {
            errorMessage = "购买项目暂时不可用，请稍后重试。"
            return
        }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                await accept(verification, finish: true)
            case .userCancelled:
                break
            case .pending:
                errorMessage = "购买正在等待确认。"
            @unknown default:
                errorMessage = "购买结果无法确认，请稍后检查权益。"
            }
        } catch {
            errorMessage = "购买失败，请稍后重试。"
        }
    }

    private func accept(_ result: VerificationResult<Transaction>, finish: Bool) async {
        guard accessMode == .paid else { return }
        guard case .verified(let transaction) = result else {
            errorMessage = "Apple 无法验证这笔购买。"
            return
        }
        guard transaction.revocationDate == nil else {
            // Keep the signed revoked transaction so the server can withdraw
            // remote scheduling too; currentEntitlements omits it.
            queue(transaction, jws: result.jwsRepresentation)
            await refreshEntitlements()
            if finish { await transaction.finish() }
            return
        }
        queue(transaction, jws: result.jwsRepresentation)
        await refreshEntitlements()
        if finish { await transaction.finish() }
    }

    private func queue(_ transaction: Transaction, jws: String) {
        guard transaction.productID == Self.trialProductID || transaction.productID == Self.lifetimeProductID else { return }
        var pending = defaults.dictionary(forKey: Self.pendingKey) as? [String: String] ?? [:]
        pending[String(transaction.id)] = jws
        defaults.set(pending, forKey: Self.pendingKey)
    }

    /// The Live Activity service calls this after the device has registered.
    func pendingTransactions() -> [String: String] {
        defaults.dictionary(forKey: Self.pendingKey) as? [String: String] ?? [:]
    }

    func markTransactionSynced(_ id: String) {
        var pending = defaults.dictionary(forKey: Self.pendingKey) as? [String: String] ?? [:]
        pending[id] = nil
        defaults.set(pending, forKey: Self.pendingKey)
    }
}
