import CloudKit
import Combine
import Foundation

@MainActor
protocol CloudSyncTransport {
    func accountID() async throws -> String
    func fetch() async throws -> (CloudSyncDocument, CKRecord)
    func save(_ document: CloudSyncDocument, record: CKRecord) async throws
}

/// A single asset gives the library an atomic server revision. Individual
/// timetable/share tombstones are merged inside it before a conditional save.
@MainActor
final class CloudKitScheduleTransport: CloudSyncTransport {
    static let containerIdentifier = "iCloud.com.niyiwei.naptable"
    private lazy var container = CKContainer(identifier: Self.containerIdentifier)
    private var database: CKDatabase { container.privateCloudDatabase }
    private let recordID = CKRecord.ID(recordName: "schedule-library-v1")

    func accountID() async throws -> String {
        guard try await container.accountStatus() == .available else { throw CloudSyncFailure.unavailable }
        return try await container.userRecordID().recordName
    }

    func fetch() async throws -> (CloudSyncDocument, CKRecord) {
        let record: CKRecord
        do { record = try await database.record(for: recordID) }
        catch let error as CKError where error.code == .unknownItem {
            return (CloudSyncDocument(), CKRecord(recordType: "ScheduleLibrary", recordID: recordID))
        }
        guard let asset = record["payload"] as? CKAsset, let url = asset.fileURL else {
            throw CloudSyncFailure.invalidData
        }
        let data = try Data(contentsOf: url)
        struct Format: Decodable { let version: Int }
        guard (1...2).contains(try JSONDecoder().decode(Format.self, from: data).version) else {
            throw CloudSyncFailure.unsupportedVersion
        }
        return (try JSONDecoder().decode(CloudSyncDocument.self, from: data).validated(), record)
    }

    func save(_ document: CloudSyncDocument, record: CKRecord) async throws {
        let data = try JSONEncoder().encode(document)
        guard data.count <= 25 * 1_024 * 1_024 else { throw CloudSyncFailure.tooLarge }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("naptable-cloud-\(UUID().uuidString).json")
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        record["payload"] = CKAsset(fileURL: url)
        let results = try await database.modifyRecords(
            saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false
        )
        guard let result = results.saveResults[record.recordID] else { throw CloudSyncFailure.invalidData }
        _ = try result.get()
    }
}

@MainActor
final class ICloudSyncService: ObservableObject {
    static let shared = ICloudSyncService()
    private static let enabledKey = "naptable.icloud.enabled"
    private static let lastSyncKey = "naptable.icloud.lastSync"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var statusText = "未开启"
    @Published private(set) var pendingReview: CloudSyncReview?
    @Published var isReviewPresented = false
    @Published var usesSettingsReviewHost = false

    private weak var store: AppStore?
    private let transport: any CloudSyncTransport
    private let defaults: UserDefaults
    private var subscriptions = Set<AnyCancellable>()
    private var pendingTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var generation = 0
    private var foreground = false
    private var needsSync = false
    private var retryAfter = Date.distantPast

    init(transport: (any CloudSyncTransport)? = nil, defaults: UserDefaults = .standard) {
        self.transport = transport ?? CloudKitScheduleTransport()
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        lastSyncedAt = defaults.object(forKey: Self.lastSyncKey) as? Date
        statusText = isEnabled ? "等待同步" : "未开启"
        NotificationCenter.default.publisher(for: .naptableCloudContentChanged)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleSync() }
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .CKAccountChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isEnabled else { return }
                    self.setEnabled(false)
                    self.statusText = "iCloud 账号状态已变化，请确认原账号后重新开启同步。"
                }
            }.store(in: &subscriptions)
    }

    func connect(_ store: AppStore) {
        self.store = store
        // Persist migrated UUIDs before making the first network request.
        store.saveNow()
    }

    func setEnabled(_ enabled: Bool) {
        generation += 1
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        pendingTask?.cancel()
        pendingReview = nil
        isReviewPresented = false
        retryAfter = .distantPast
        statusText = enabled ? "等待同步" : "已关闭，课表保留在本机和 iCloud"
        if enabled { scheduleSync() }
    }

    func setForeground(_ active: Bool) {
        foreground = active
        pollingTask?.cancel()
        if !active {
            store?.saveNow()
            pendingTask?.cancel()
            return
        }
        scheduleSync()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self else { return }
                await self.syncNow()
            }
        }
    }

    private func scheduleSync() {
        guard isEnabled, foreground else { return }
        if isSyncing { needsSync = true; return }
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            await self?.syncNow()
        }
    }

    /// Local edits and settings sync automatically. Only incoming timetable
    /// content is staged for confirmation.
    func syncNow(refreshReview: Bool = false) async {
        guard isEnabled, !isSyncing, Date() >= retryAfter, let store else { return }
        let session = generation
        isSyncing = true
        statusText = "正在同步…"
        defer { completeTask() }
        do {
            try await performSync(store: store, session: session, approvedReview: nil, destinations: [:])
            if refreshReview && pendingReview != nil { isReviewPresented = true }
        } catch { handle(error, session: session) }
    }

    func deferReview() {
        isReviewPresented = false
        if pendingReview != nil { statusText = "有云端课表更新等待确认" }
    }

    func confirmReview(_ reviewID: UUID, destinations: [String: CloudTableDestination]) async {
        guard isEnabled, !isSyncing, Date() >= retryAfter, let store,
              let review = pendingReview, review.id == reviewID else { return }
        let session = generation
        isSyncing = true
        statusText = "正在接收课表…"
        defer { completeTask() }
        do {
            try await performSync(store: store, session: session, approvedReview: review, destinations: destinations)
        } catch { handle(error, session: session) }
    }

    private func performSync(store: AppStore, session: Int, approvedReview: CloudSyncReview?,
                             destinations: [String: CloudTableDestination]) async throws {
        let account = try await transport.accountID()
        try checkSession(session)
        if let approvedReview, approvedReview.account != account { throw CloudSyncFailure.accountChanged }
        try store.bindCloudAccount(account)
        var approval = approvedReview
        for attempt in 0..<3 {
            let (fetched, record) = try await transport.fetch()
            try checkSession(session)
            guard try await transport.accountID() == account else { throw CloudSyncFailure.accountChanged }
            try checkSession(session)
            guard store.saveNow() else { throw CloudSyncFailure.localStorage }
            let remote = try fetched.validated()
            let review = CloudSyncReview(account: account, local: store.cloudSync.document, remote: remote)
            if let accepted = approval {
                let targetsUnchanged = destinations.values.allSatisfy { destination in
                    guard case .current(let id) = destination else { return true }
                    guard let target = store.tables.first(where: { $0.id == id }), let syncID = target.syncID else { return false }
                    let key = "table:" + syncID
                    return CloudSyncReview.sameCourseContent(accepted.local.entries[key]?.payload,
                                                            review.local.entries[key]?.payload)
                }
                if !accepted.hasSameCourseChanges(as: review) || !targetsUnchanged { approval = nil }
            }
            let plan: (document: CloudSyncDocument, tableIDs: [String: Int])
            if approval != nil {
                plan = try store.reviewedCloudDocument(review, destinations: destinations)
            } else {
                // Preserve unapproved remote entries on the server while
                // independently uploading local edits and settings.
                plan = (review.merged, [:])
            }
            if plan.document != remote {
                do { try await transport.save(plan.document, record: record) }
                catch let error as CKError where error.code == .serverRecordChanged && attempt < 2 { continue }
            }
            try checkSession(session)
            guard try await transport.accountID() == account else { throw CloudSyncFailure.accountChanged }
            try checkSession(session)
            guard store.saveNow() else { throw CloudSyncFailure.localStorage }
            if store.cloudSync.document != review.local {
                // An edit during upload must survive, including edits to a
                // replacement target. Retry uploads without extending approval.
                approval = nil
                if attempt < 2 { continue }
                needsSync = true
                statusText = "有本机修改等待上传"
                return
            }
            if approval != nil {
                try store.applyCloudDocument(plan.document, tableIDs: plan.tableIDs)
            } else {
                let automatic = review.automaticDocument()
                if automatic != store.cloudSync.document { try store.applyCloudDocument(automatic) }
            }
            stageReview(account: account, remote: plan.document, store: store)
            if approvedReview != nil && approval == nil && pendingReview != nil {
                statusText = "课表内容已变化，请重新确认接收"
            }
            // Name normalization or a dependent setting can produce another
            // local edit. It is uploaded automatically on the next pass.
            if store.cloudSync.document.merged(with: plan.document) != plan.document {
                needsSync = true
                if pendingReview == nil { statusText = "有本机修改等待上传" }
            }
            return
        }
    }

    private func stageReview(account: String, remote: CloudSyncDocument, store: AppStore) {
        let review = CloudSyncReview(account: account, local: store.cloudSync.document, remote: remote)
        if review.changes.isEmpty {
            pendingReview = nil
            isReviewPresented = false
            markSynced()
        } else if let previous = pendingReview, previous.hasSameCourseChanges(as: review) {
            // Refresh automatically synced settings without resetting choices
            // or repeatedly opening a review the user has deferred.
            pendingReview = CloudSyncReview(account: account, local: review.local, remote: remote, id: previous.id)
            statusText = "有 \(review.changes.count) 项云端课表更新等待确认"
        } else {
            pendingReview = review
            isReviewPresented = true
            statusText = "有 \(review.changes.count) 项云端课表更新等待确认"
        }
    }

    private func markSynced() {
        lastSyncedAt = Date()
        defaults.set(lastSyncedAt, forKey: Self.lastSyncKey)
        statusText = "已同步"
    }

    private func completeTask() {
        isSyncing = false
        if needsSync {
            needsSync = false
            scheduleSync()
        }
    }

    private func handle(_ error: Error, session: Int) {
        if error is CancellationError {
            if session == generation { statusText = "等待同步" }
        } else {
            guard session == generation else { return }
            if case CloudSyncFailure.accountChanged = error { setEnabled(false) }
            if let cloudError = error as? CKError {
                // Respect server throttling even if the user repeatedly retries.
                retryAfter = Date().addingTimeInterval(max(5, cloudError.retryAfterSeconds ?? 30))
                switch cloudError.code {
                case .notAuthenticated: statusText = CloudSyncFailure.unavailable.localizedDescription
                case .networkUnavailable, .networkFailure:
                    statusText = "网络不可用，修改已保存在本机，联网后将重试。"
                case .quotaExceeded: statusText = "iCloud 空间不足，请释放空间后重试。"
                case .permissionFailure, .missingEntitlement, .badContainer:
                    statusText = "当前版本的 iCloud 配置不可用，请联系开发者。"
                default: statusText = "iCloud 暂时无法同步，将自动重试。"
                }
            } else { statusText = error.localizedDescription }
        }
    }

    private func checkSession(_ expected: Int) throws {
        guard isEnabled, generation == expected, !Task.isCancelled else { throw CancellationError() }
    }
}
