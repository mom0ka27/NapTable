import CloudKit
import Foundation

@MainActor
final class MemoryCloud: CloudSyncTransport {
    var document = CloudSyncDocument()
    var account = "test-account"
    var unavailable = false
    var failures = 0
    var fetches = 0
    var saves = 0
    var duringSave: (() -> Void)?

    func accountID() async throws -> String {
        if unavailable { throw CloudSyncFailure.unavailable }
        return account
    }
    func fetch() async throws -> (CloudSyncDocument, CKRecord) {
        fetches += 1
        return (document, CKRecord(recordType: "ScheduleLibrary"))
    }
    func save(_ document: CloudSyncDocument, record: CKRecord) async throws {
        saves += 1
        if failures > 0 {
            failures -= 1
            throw CKError(.serverRecordChanged)
        }
        duringSave?()
        duringSave = nil
        self.document = document
    }
}

@main
struct ICloudSyncChecks {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let keys = ["naptable.importedShares", "naptable.shares", "naptable.shareCode", "naptable.shareToken",
                    "naptable.followedShareCode", "naptable.followedShareLabel", "naptable.sharedNotifications"]
        let defaults = UserDefaults.standard
        let savedDefaults = keys.map { defaults.object(forKey: $0) }
        let group = UserDefaults(suiteName: NextWidgetConfiguration.appGroup)!
        let followedBackup = group.object(forKey: "naptable.followedShare")
        for key in keys { defaults.removeObject(forKey: key) }
        group.removeObject(forKey: "naptable.followedShare")
        let suite = "naptable.sync.tests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer {
            for (key, value) in zip(keys, savedDefaults) { defaults.set(value, forKey: key) }
            group.set(followedBackup, forKey: "naptable.followedShare")
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        let first = AppStore(fileURL: directory.appendingPathComponent("first.json"))
        let second = AppStore(fileURL: directory.appendingPathComponent("second.json"))
        let table = first.addTable(name: "秋季课表", semesterStartMonday: "2026-09-07",
                                   classTimeList: [ClassTime(start: "08:30", end: "09:20")])
        let course = first.addCourse(Course(tableId: table.id, name: "数学", weeks: [1, 3, 5],
                                           weekTime: 2, startTime: 1, timeCount: 0, importType: ImportKind.imported))
        var hidden = course
        hidden.name = "收起的课程"
        hidden.hidden = true
        first.addCourse(hidden)
        first.updateWeekCount(20)
        precondition(first.saveNow())
        let originalID = first.tables[0].syncID!
        precondition(AppStore(fileURL: directory.appendingPathComponent("first.json")).tables[0].syncID == originalID)
        let other = second.addTable(name: "秋季课表")
        second.updateSettings { $0.appearance = .dark }
        precondition(second.saveNow())
        try second.applyCloudDocument(first.cloudSync.document)
        precondition(second.tables.count == 2 && second.selectedTableId == other.id)
        precondition(second.settings.appearance == .dark, "Device appearance must not sync")
        let imported = second.tables.first { $0.syncID == originalID }!
        let importedCourses = second.courses.filter { $0.tableId == imported.id }
        precondition(importedCourses.count == 2 && importedCourses[1].isHidden)
        precondition(importedCourses[0].courseKey == importedCourses[1].courseKey)
        precondition(imported.termWeekCount == 20 && imported.classTimeList == table.classTimeList)
        try first.applyCloudDocument(second.cloudSync.document)
        try second.applyCloudDocument(first.cloudSync.document)
        precondition(first.cloudSnapshot() == second.cloudSnapshot(), "Same-named independent tables must converge")
        let stable = second.cloudSync.document
        try second.applyCloudDocument(first.cloudSync.document)
        precondition(second.cloudSync.document == stable, "Applying unchanged data must not cause a sync loop")
        precondition(Set(second.tables.map(\.id)).count == 2)
        precondition(Set(second.courses.map(\.id)).count == second.courses.count)

        // Independent offline edits merge, including deletion vs an untouched copy.
        first.renameTable(first.tables.first { $0.syncID == originalID }!.id, to: "新版课表")
        second.deleteTable(other.id)
        precondition(first.saveNow() && second.saveNow())
        let merged = first.cloudSync.document.merged(with: second.cloudSync.document)
        try first.applyCloudDocument(merged)
        try second.applyCloudDocument(merged)
        precondition(first.tables.count == 1 && second.tables.count == 1)
        precondition(second.tables[0].name == "新版课表")
        precondition(!second.cloudRecoveryCopies.isEmpty)
        let backup = second.cloudRecoveryCopies[0]
        let beforeRecovery = second.tables.count
        try second.restoreCloudRecovery(backup)
        precondition(second.tables.count > beforeRecovery)
        precondition(Set(second.tables.compactMap(\.syncID)).count == second.tables.count)

        // Tombstones survive restart, and clock skew cannot defeat a later edit.
        var journal = CloudSyncJournal()
        let payload = first.cloudSnapshot().values.first!
        journal.capture([payload.key: payload], now: Date(timeIntervalSince1970: 10_000))
        journal.capture([:], now: Date(timeIntervalSince1970: 1))
        precondition(journal.document.entries[payload.key]!.payload == nil)
        precondition(journal.document.entries[payload.key]!.modifiedAt > Date(timeIntervalSince1970: 10_000))
        let reloaded = try JSONDecoder().decode(CloudSyncJournal.self, from: JSONEncoder().encode(journal))
        precondition(reloaded.document == journal.document)
        precondition(merged.merged(with: stable) == stable.merged(with: merged), "Merge order must not matter")

        // Old files without sync metadata/UUIDs migrate without losing data.
        var oldState = AppStateFile()
        oldState.tables = [CourseTable(id: 42, name: "旧课表")]
        let oldURL = directory.appendingPathComponent("old.json")
        try JSONEncoder().encode(oldState).write(to: oldURL)
        let legacy = AppStore(fileURL: oldURL)
        precondition(legacy.loadErrorMessage == nil && legacy.tables[0].syncID != nil)

        let sharing = ScheduleSharingService.shared
        let meta = ShareMeta(code: "FRIEND", owner: "朋友", schoolID: "test", schoolName: "测试学校",
                             name: "朋友", termID: "fall", termVersion: 1, courseCount: 1,
                             semesterStartMonday: "2026-09-07", weekCount: 20, updatedAt: "1")
        let shared = FollowedSchedule(meta: meta, courses: [course], classTimes: table.classTimeList,
                                      adjustments: [], fetchedAt: Date())
        try sharing.saveShared(shared, remark: "小明")
        sharing.remember(ShareCredential(code: "MINE", token: "test-secret", label: "我", updatedAt: "1",
                                         tableID: first.tables[0].id))
        precondition(first.saveNow())
        let library = first.cloudSync.document
        let third = AppStore(fileURL: directory.appendingPathComponent("third.json"))
        sharing.applyCloudLibrary(shared: [], credentials: [])
        try third.applyCloudDocument(library)
        precondition(sharing.sharedSchedules[0].remark == "小明")
        precondition(sharing.followedCode == nil, "Sync must not enable caring notifications")
        precondition(sharing.myShares[0].token == "test-secret")
        precondition(sharing.myShares[0].tableID == third.tables.first { $0.syncID == originalID }!.id)
        precondition(third.cloudSnapshot()["credential:MINE"] == first.cloudSnapshot()["credential:MINE"])
        sharing.removeShared("FRIEND")
        sharing.forget(sharing.myShares[0])
        precondition(third.saveNow())
        precondition(third.cloudSync.document.entries["shared:FRIEND"]?.payload == nil)
        precondition(third.cloudSync.document.entries["credential:MINE"]?.payload == nil)

        // Service never calls CloudKit while disabled; retries conditional-save
        // conflicts, preserves edits made during upload, and refuses other accounts.
        let cloud = MemoryCloud()
        let service = ICloudSyncService(transport: cloud, defaults: preferences)
        service.connect(third)
        await service.syncNow()
        precondition(cloud.fetches == 0 && cloud.saves == 0)
        service.setEnabled(true)
        cloud.failures = 2
        cloud.duringSave = { third.renameTable(third.tables[0].id, to: "上传时修改") }
        await service.syncNow()
        precondition(service.statusText == "有修改等待同步" && cloud.saves == 3)
        precondition(third.tables[0].name == "上传时修改")
        await service.syncNow()
        precondition(cloud.document == third.cloudSync.document)
        let saves = cloud.saves
        await service.syncNow()
        precondition(cloud.saves == saves, "Unchanged sync must avoid cloud writes")
        cloud.account = "another-account"
        await service.syncNow()
        precondition(!service.isEnabled && cloud.saves == saves, "Never upload old data to a different account")
        cloud.account = "test-account"
        service.setEnabled(true)
        cloud.document.version = 2
        let beforeInvalid = third.cloudSnapshot()
        await service.syncNow()
        precondition(third.cloudSnapshot() == beforeInvalid && cloud.saves == saves)
        precondition(service.statusText.contains("更新"))
        cloud.document.version = 1
        cloud.duringSave = { service.setEnabled(false) }
        third.renameTable(third.tables[0].id, to: "关闭测试")
        precondition(third.saveNow())
        await service.syncNow()
        precondition(!service.isEnabled && service.statusText.contains("已关闭"))

        // A blocked local save must never upload even an otherwise valid state.
        let failingStore = AppStore(fileURL: directory.appendingPathComponent("missing/state.json"))
        let blockedCloud = MemoryCloud()
        let blockedService = ICloudSyncService(transport: blockedCloud, defaults: preferences)
        blockedService.connect(failingStore)
        blockedService.setEnabled(true)
        await blockedService.syncNow()
        precondition(blockedCloud.saves == 0 && blockedService.statusText.contains("保存"))

        print("PASS: migration, ID/group remapping, same-name convergence, offline edits/deletion, stable merge, recovery, sharing credentials, local notification preferences, conditional retry, in-flight edits, opt-out, account isolation, future schema and failed local saves")
    }
}
