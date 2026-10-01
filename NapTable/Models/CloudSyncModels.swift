import Foundation

/// Local integer IDs never cross devices. Canonical IDs retain course grouping
/// while making equal timetables compare equal after installation elsewhere.
nonisolated struct CloudTable: Codable, Equatable {
    var table: CourseTable
    var courses: [Course]

    init(table: CourseTable, courses: [Course], weekCount: Int) {
        self.table = table
        self.table.id = 0
        self.table.termWeekCount = weekCount
        var keys: [Int: Int] = [:]
        self.courses = courses.enumerated().map { index, original in
            var course = original
            course.id = index + 1
            course.tableId = 0
            if let key = course.courseKey {
                if keys[key] == nil { keys[key] = keys.count + 1 }
                course.courseKey = keys[key]
            }
            return course
        }
    }
}

nonisolated struct CloudCredential: Codable, Equatable {
    var credential: ShareCredential
    var tableSyncID: String?
}

nonisolated enum CloudSyncPayload: Codable, Equatable {
    case table(CloudTable)
    case shared(FollowedSchedule)
    case credential(CloudCredential)

    var key: String {
        switch self {
        case .table(let value): return "table:" + (value.table.syncID ?? "")
        case .shared(let value): return "shared:" + value.meta.code
        case .credential(let value): return "credential:" + value.credential.code
        }
    }
}

nonisolated struct CloudSyncEntry: Codable, Equatable {
    var modifiedAt: Date
    var writer: String
    /// nil is a durable deletion marker, including deletions made offline.
    var payload: CloudSyncPayload?

    func isNewer(than other: Self) -> Bool {
        if modifiedAt != other.modifiedAt { return modifiedAt > other.modifiedAt }
        return writer > other.writer
    }
}

nonisolated struct CloudSyncDocument: Codable, Equatable {
    var version = 1
    var entries: [String: CloudSyncEntry] = [:]

    func validated() throws -> Self {
        guard version == 1 else { throw CloudSyncFailure.unsupportedVersion }
        for (key, entry) in entries {
            guard ["table:", "shared:", "credential:"].contains(where: { key.hasPrefix($0) }),
                  !entry.writer.isEmpty, entry.modifiedAt.timeIntervalSince1970.isFinite else {
                throw CloudSyncFailure.invalidData
            }
            if let payload = entry.payload {
                guard payload.key == key else { throw CloudSyncFailure.invalidData }
                if case .table(let value) = payload {
                    guard let id = value.table.syncID, UUID(uuidString: id) != nil else {
                        throw CloudSyncFailure.invalidData
                    }
                }
            }
        }
        return self
    }

    func merged(with other: Self) -> Self {
        var result = self
        for (key, entry) in other.entries {
            if let existing = result.entries[key], !entry.isNewer(than: existing) { continue }
            result.entries[key] = entry
        }
        return result
    }
}

/// Stored atomically with the local timetable. The baseline distinguishes a
/// local deletion from a cloud item this device has never downloaded.
nonisolated struct CloudSyncJournal: Codable {
    var writer = UUID().uuidString
    var document = CloudSyncDocument()
    var baseline: [String: CloudSyncPayload] = [:]
    var accountID: String?

    mutating func capture(_ values: [String: CloudSyncPayload], now: Date = Date()) {
        let changed = Set(baseline.keys).union(values.keys).filter { baseline[$0] != values[$0] }
        guard !changed.isEmpty else { return }
        let latest = document.entries.values.map(\.modifiedAt).max() ?? .distantPast
        // Observing a remote future timestamp must not make later local edits lose.
        let stamp = max(now, latest.addingTimeInterval(0.001))
        for key in changed {
            document.entries[key] = CloudSyncEntry(modifiedAt: stamp, writer: writer, payload: values[key])
        }
        baseline = values
    }
}

nonisolated enum CloudSyncFailure: LocalizedError {
    case unsupportedVersion, invalidData, localStorage, accountChanged, unavailable, tooLarge

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return "云端数据来自更新版本，请先更新 App。"
        case .invalidData: return "云端课表数据无法读取，本机数据已保留。"
        case .localStorage: return "本机数据尚未成功保存，请检查设备存储空间后重试。"
        case .accountChanged: return "iCloud 账号已变化，同步已暂停。请切回原来的 Apple 账号。"
        case .unavailable: return "请在系统设置中登录 iCloud，并允许本 App 使用 iCloud。"
        case .tooLarge: return "课表同步数据过大，请减少课表数量后重试。"
        }
    }
}

extension Notification.Name {
    static let naptableCloudContentChanged = Notification.Name("naptable.cloudContentChanged")
}
