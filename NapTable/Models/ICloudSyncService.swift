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

    func syncNow() async {
        guard isEnabled, !isSyncing, Date() >= retryAfter, let store else { return }
        let session = generation
        isSyncing = true
        statusText = "正在同步…"
        defer {
            isSyncing = false
            if needsSync {
                needsSync = false
                scheduleSync()
            }
        }
        do {
            let account = try await transport.accountID()
            try checkSession(session)
            try store.bindCloudAccount(account)
            // A stale server revision is never overwritten. Re-fetch and merge
            // on a competing write, with a bounded retry count.
            for attempt in 0..<3 {
                let (remote, record) = try await transport.fetch()
                try checkSession(session)
                guard try await transport.accountID() == account else { throw CloudSyncFailure.accountChanged }
                try checkSession(session)
                guard store.saveNow() else { throw CloudSyncFailure.localStorage }
                let merged = store.cloudSync.document.merged(with: try remote.validated())
                if merged != remote {
                    do { try await transport.save(merged, record: record) }
                    catch let error as CKError where error.code == .serverRecordChanged && attempt < 2 { continue }
                }
                try checkSession(session)
                guard try await transport.accountID() == account else { throw CloudSyncFailure.accountChanged }
                try checkSession(session)
                // Fetching/uploading can suspend while the user edits locally.
                // AppStore captures those edits again before applying the merge.
                try store.applyCloudDocument(merged)
                lastSyncedAt = Date()
                defaults.set(lastSyncedAt, forKey: Self.lastSyncKey)
                if store.cloudSync.document != merged {
                    statusText = "有修改等待同步"
                    scheduleSync()
                } else { statusText = "已同步" }
                return
            }
        } catch is CancellationError {
            if session == generation { statusText = "等待同步" }
        } catch {
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
