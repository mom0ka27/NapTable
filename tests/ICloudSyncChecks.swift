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
    var onConflict: (() -> Void)?

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
            onConflict?()
            onConflict = nil
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
        let notificationKeys = ["scheduleLiveActivityEnabled", "scheduleLiveActivityLeadMinutes",
                                "naptable.liveActivity.sharedLeadMinutes", "naptable.liveActivity.perPeriod"]
        let notificationBackup = notificationKeys.map { group.object(forKey: $0) }
        for key in notificationKeys { group.removeObject(forKey: key) }
        for key in keys { defaults.removeObject(forKey: key) }
        group.removeObject(forKey: "naptable.followedShare")
        let suite = "naptable.sync.tests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer {
            for (key, value) in zip(keys, savedDefaults) { defaults.set(value, forKey: key) }
            group.set(followedBackup, forKey: "naptable.followedShare")
            for (key, value) in zip(notificationKeys, notificationBackup) { group.set(value, forKey: key) }
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
        let customTimes = [ClassTime(start: "10:00", end: "10:50")]
        let customSeasons = [SeasonalClassTimes(from: "05-01", periods: customTimes)]
        precondition(first.updateCustomClassTimes(customTimes, seasons: customSeasons, tableId: table.id))
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
        precondition(importedCourses[0].courseKey != importedCourses[1].courseKey) // 不同名称各自成课
        precondition(imported.termWeekCount == 20 && imported.classTimeList == table.classTimeList)
        precondition(imported.usesCustomClassTimes == true && imported.customClassTimeList == customTimes)
        precondition(imported.customSeasonalPeriods == customSeasons)
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
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        precondition(!files.contains { $0.lastPathComponent.hasPrefix("before-icloud-") }, "Sync must not create recovery copies")

        // Tombstones survive restart, and clock skew cannot defeat a later edit.
        var journal = CloudSyncJournal()
        let payload = first.cloudSnapshot().values.first!
        journal.capture([payload.key: payload], now: Date(timeIntervalSince1970: 10_000))
        journal.capture([:], now: Date(timeIntervalSince1970: 1))
        precondition(journal.document.entries[payload.key]!.payload == nil)
        precondition(journal.document.entries[payload.key]!.modifiedAt > Date(timeIntervalSince1970: 10_000))
        let reloaded = try JSONDecoder().decode(CloudSyncJournal.self, from: JSONEncoder().encode(journal))
        precondition(reloaded.document == journal.document)
        var oldDocument = try JSONSerialization.jsonObject(with: JSONEncoder().encode(journal.document)) as! [String: Any]
        oldDocument["version"] = 1
        var oldEntries = oldDocument["entries"] as! [String: [String: Any]]
        for key in oldEntries.keys { oldEntries[key]?.removeValue(forKey: "writerName") }
        oldDocument["entries"] = oldEntries
        let oldCloud = try JSONDecoder().decode(CloudSyncDocument.self, from: JSONSerialization.data(withJSONObject: oldDocument)).validated()
        precondition(oldCloud.version == 1 && oldCloud.entries.values.allSatisfy { $0.writerName == nil },
                     "Version 1 documents without device names must remain readable")
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
        sharing.follow(sharing.sharedSchedules[0])
        let notifications = LegacyCloudNotificationPreferences(enabled: false, leadMinutes: 30, sharedLeadMinutes: 15, perPeriod: true)
        group.set(true, forKey: notificationKeys[0])
        group.set(60, forKey: notificationKeys[1])
        group.set(30, forKey: notificationKeys[2])
        group.set(false, forKey: notificationKeys[3])
        sharing.remember(ShareCredential(code: "MINE", token: "test-secret", label: "我", updatedAt: "1",
                                         tableID: first.tables[0].id))
        precondition(first.saveNow())
        precondition(first.cloudSync.document.entries["settings:notifications"] == nil,
                     "Local real-time activity preferences must never be captured for sync")
        var library = first.cloudSync.document
        library.entries["settings:notifications"] = CloudSyncEntry(modifiedAt: Date(), writer: "old-device", payload: .notifications(notifications))
        let third = AppStore(fileURL: directory.appendingPathComponent("third.json"))
        sharing.applyCloudLibrary(shared: [], credentials: [])
        let fresh = AppStore(fileURL: directory.appendingPathComponent("fresh.json"))
        precondition(fresh.saveNow())
        precondition(fresh.cloudSync.document.entries["settings:caring"] == nil)
        precondition(fresh.cloudSync.document.entries["settings:notifications"] == nil, "Fresh defaults must not override cloud preferences")
        try third.applyCloudDocument(library)
        precondition(sharing.sharedSchedules[0].remark == "小明")
        precondition(sharing.followedCode == "FRIEND", "Approved caring selection must sync")
        precondition(group.bool(forKey: notificationKeys[0]) && group.integer(forKey: notificationKeys[1]) == 60
                     && group.integer(forKey: notificationKeys[2]) == 30 && !group.bool(forKey: notificationKeys[3]),
                     "Legacy cloud notification settings must not change this device")
        precondition(third.cloudSync.document.entries["settings:notifications"] == nil)
        precondition(sharing.myShares[0].token == "test-secret")
        precondition(sharing.myShares[0].tableID == third.tables.first { $0.syncID == originalID }!.id)
        precondition(third.cloudSnapshot()["credential:MINE"] == first.cloudSnapshot()["credential:MINE"])
        sharing.removeShared("FRIEND")
        sharing.forget(sharing.myShares[0])
        precondition(third.saveNow())
        precondition(third.cloudSync.document.entries["shared:FRIEND"]?.payload == nil)
        precondition(third.cloudSync.document.entries["credential:MINE"]?.payload == nil)

        // Local edits upload without prompts, including retry and in-flight edits.
        let cloud = MemoryCloud()
        let service = ICloudSyncService(transport: cloud, defaults: preferences)
        service.connect(third)
        await service.syncNow()
        precondition(cloud.fetches == 0 && cloud.saves == 0)
        service.setEnabled(true)
        cloud.failures = 2
        cloud.duringSave = { third.renameTable(third.tables[0].id, to: "上传时修改") }
        await service.syncNow()
        precondition(service.pendingReview == nil && !service.isReviewPresented && cloud.saves == 3)
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
        cloud.document.version = 3
        let beforeInvalid = third.cloudSnapshot()
        await service.syncNow()
        precondition(third.cloudSnapshot() == beforeInvalid && cloud.saves == saves)
        precondition(service.statusText.contains("更新"))
        cloud.document.version = 2
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

        try await reviewChecks(directory: directory, defaults: preferences)
        try await automaticSettingsChecks(directory: directory, defaults: preferences, group: group)
        print("PASS: migration, automatic uploads/settings, local-only live activity preferences, remote-only timetable review, provenance, new/current table choices, deferred review, concurrent settings, conflict retry, in-flight edits, opt-out, account isolation and failed saves")
    }

    @MainActor static func reviewChecks(directory: URL, defaults: UserDefaults) async throws {
        defaults.removeObject(forKey: "naptable.icloud.enabled")
        let local = AppStore(fileURL: directory.appendingPathComponent("review-local.json"))
        let table = local.addTable(name: "本机课表")
        local.addCourse(Course(tableId: table.id, name: "数学", weeks: [1], weekTime: 1,
                               startTime: 1, timeCount: 0, importType: ImportKind.imported, teacher: "旧教师"))
        precondition(local.saveNow())
        let cloud = MemoryCloud()
        cloud.document = local.cloudSync.document
        let service = ICloudSyncService(transport: cloud, defaults: defaults)
        service.connect(local)
        service.setEnabled(true)
        await service.syncNow()
        precondition(service.pendingReview == nil && cloud.saves == 0)
        let key = "table:" + local.tables[0].syncID!
        var remoteTable: CloudTable
        if case .table(let value) = cloud.document.entries[key]!.payload { remoteTable = value }
        else { fatalError("Missing table") }
        remoteTable.table.name = "iPad 课表"
        remoteTable.courses[0].teacher = "新教师"
        cloud.document.entries[key] = CloudSyncEntry(modifiedAt: Date().addingTimeInterval(10), writer: "ipad",
            writerName: "测试 iPad", payload: .table(remoteTable))
        await service.syncNow()
        precondition(local.tables[0].name == "本机课表" && cloud.saves == 0, "Download waits for approval")
        let review = service.pendingReview!
        let change = review.changes.first { $0.key == key && $0.direction == .download }!
        precondition(change.device == "测试 iPad" && change.details.contains { $0.contains("新教师") })
        await service.confirmReview(review.id, destinations: [key: .new])
        precondition(local.tables.count == 2 && Set(local.tables.map(\.name)) == ["本机课表", "iPad 课表"])
        precondition(local.tables.first { $0.name == "本机课表" }!.syncID == table.syncID)
        precondition(Set(local.tables.compactMap(\.syncID)).count == 2)
        await service.syncNow()
        precondition(service.pendingReview == nil, "A new table choice must not reappear as a download")

        // New remote table can join the currently selected local table's ID.
        var incoming = remoteTable
        incoming.table.syncID = UUID().uuidString
        incoming.table.name = "替换后的课表"
        let newKey = "table:" + incoming.table.syncID!
        cloud.document.entries[newKey] = CloudSyncEntry(modifiedAt: Date().addingTimeInterval(20), writer: "ipad",
            writerName: "测试 iPad", payload: .table(incoming))
        let targetID = local.selectedTableId
        let targetKey = "table:" + local.selectedTable!.syncID!
        await service.syncNow()
        await service.confirmReview(service.pendingReview!.id, destinations: [newKey: .current(targetID)])
        precondition(local.selectedTableId == targetID && local.selectedTable!.name == "替换后的课表")
        precondition(local.tables.count == 2 && cloud.document.entries[targetKey]!.payload == nil)
        precondition(local.selectedTable!.syncID == incoming.table.syncID)
        await service.syncNow()
        precondition(service.pendingReview == nil)

        // Local settings edits are automatic and do not produce a review.
        local.renameTable(targetID, to: "自动上传名称")
        precondition(local.saveNow())
        await service.syncNow()
        precondition(service.pendingReview == nil && cloud.document == local.cloudSync.document)

        // Course changes while a review is open require fresh approval.
        var updated = incoming
        updated.courses[0].teacher = "云端教师 A"
        cloud.document.entries[newKey] = CloudSyncEntry(modifiedAt: Date().addingTimeInterval(100), writer: "ipad",
            writerName: "测试 iPad", payload: .table(updated))
        await service.syncNow()
        let staleReview = service.pendingReview!
        updated.courses[0].teacher = "云端教师 B"
        cloud.document.entries[newKey] = CloudSyncEntry(modifiedAt: Date().addingTimeInterval(200), writer: "ipad",
            writerName: "测试 iPad", payload: .table(updated))
        await service.confirmReview(staleReview.id, destinations: [:])
        precondition(service.pendingReview!.id != staleReview.id)
        precondition(local.courses.first { $0.tableId == targetID }!.teacher == "新教师")
        await service.confirmReview(service.pendingReview!.id, destinations: [:])
        precondition(local.courses.first { $0.tableId == targetID }!.teacher == "云端教师 B")

        // A competing write can still upload independent local settings,
        // but its new courses must remain behind a fresh review.
        updated.courses[0].teacher = "待确认教师"
        cloud.document.entries[newKey] = CloudSyncEntry(modifiedAt: Date().addingTimeInterval(300), writer: "ipad",
            writerName: "测试 iPad", payload: .table(updated))
        await service.syncNow()
        let conflictReview = service.pendingReview!
        let otherID = local.tables.first { $0.id != targetID }!.id
        local.renameTable(otherID, to: "独立设置修改")
        cloud.failures = 1
        cloud.onConflict = {
            var competing = updated
            competing.courses[0].teacher = "并发云端教师"
            cloud.document.entries[newKey] = CloudSyncEntry(modifiedAt: Date().addingTimeInterval(400), writer: "ipad",
                writerName: "测试 iPad", payload: .table(competing))
        }
        await service.confirmReview(conflictReview.id, destinations: [:])
        precondition(service.pendingReview!.id != conflictReview.id)
        precondition(local.courses.first { $0.tableId == targetID }!.teacher == "云端教师 B")
        precondition(local.tables.first { $0.id == otherID }!.name == "独立设置修改")
        service.setEnabled(false)
        precondition(service.pendingReview == nil && !service.isReviewPresented)

        let copyStore = AppStore(fileURL: directory.appendingPathComponent("same-name-copy.json"))
        let copyTable = copyStore.addTable(name: "同名课表")
        copyStore.addCourse(Course(tableId: copyTable.id, name: "数学", weeks: [1], weekTime: 1,
                                   startTime: 1, timeCount: 0, importType: ImportKind.imported))
        precondition(copyStore.saveNow())
        let copyKey = "table:" + copyStore.tables[0].syncID!
        var copyRemote = copyStore.cloudSync.document
        guard case .table(var copyPayload) = copyRemote.entries[copyKey]?.payload else { fatalError("Missing copy source") }
        copyPayload.courses[0].teacher = "新教师"
        copyRemote.entries[copyKey] = CloudSyncEntry(modifiedAt: Date().addingTimeInterval(500), writer: "ipad",
            writerName: "测试 iPad", payload: .table(copyPayload))
        let copyReview = CloudSyncReview(account: "test-account", local: copyStore.cloudSync.document, remote: copyRemote)
        let copyPlan = try copyStore.reviewedCloudDocument(copyReview, destinations: [copyKey: .new])
        try copyStore.applyCloudDocument(copyPlan.document)
        precondition(copyStore.tables.count == 2 && Set(copyStore.tables.map(\.name)).count == 2)
        precondition(copyStore.cloudSync.document == copyPlan.document, "Same-name copies must keep the approved cloud result")
    }

    @MainActor static func automaticSettingsChecks(directory: URL, defaults: UserDefaults, group: UserDefaults) async throws {
        let local = AppStore(fileURL: directory.appendingPathComponent("automatic-settings.json"))
        let table = local.addTable(name: "自动同步测试")
        local.addCourse(Course(tableId: table.id, name: "数学", weeks: [1], weekTime: 1,
                               startTime: 1, timeCount: 0, importType: ImportKind.imported, teacher: "本机教师"))
        precondition(local.saveNow())
        let cloud = MemoryCloud()
        cloud.document = local.cloudSync.document
        let service = ICloudSyncService(transport: cloud, defaults: defaults)
        service.connect(local)
        service.setEnabled(true)
        let key = "table:" + local.tables[0].syncID!
        guard case .table(var remote) = cloud.document.entries[key]?.payload else { fatalError("Missing table") }
        remote.table.name = "远程设置名称"
        remote.table.classTimeList = [ClassTime(start: "09:00", end: "09:50")]
        cloud.document.entries[key] = CloudSyncEntry(modifiedAt: Date().addingTimeInterval(100), writer: "ipad",
            writerName: "设置设备", payload: .table(remote))
        cloud.document.entries["settings:notifications"] = CloudSyncEntry(modifiedAt: Date().addingTimeInterval(200), writer: "legacy",
            payload: .notifications(LegacyCloudNotificationPreferences(enabled: false, leadMinutes: 15, sharedLeadMinutes: 15, perPeriod: true)))
        group.set(true, forKey: "scheduleLiveActivityEnabled")
        group.set(60, forKey: "scheduleLiveActivityLeadMinutes")
        await service.syncNow()
        precondition(service.pendingReview == nil && !service.isReviewPresented)
        precondition(local.selectedTable!.name == "远程设置名称" && local.selectedTable!.classTimeList == remote.table.classTimeList)
        precondition(group.bool(forKey: "scheduleLiveActivityEnabled") && group.integer(forKey: "scheduleLiveActivityLeadMinutes") == 60)
        precondition(cloud.document.entries["settings:notifications"] == nil)
        let beforeDeviceEdit = local.cloudSync.document
        let deviceEditSaves = cloud.saves
        group.set(false, forKey: "scheduleLiveActivityEnabled")
        group.set(15, forKey: "scheduleLiveActivityLeadMinutes")
        group.set(true, forKey: "naptable.liveActivity.perPeriod")
        precondition(local.saveNow() && local.cloudSync.document == beforeDeviceEdit)
        await service.syncNow()
        precondition(cloud.saves == deviceEditSaves && service.pendingReview == nil,
                     "Local Live Activity changes must not write to CloudKit or open a review")

        let sharing = ScheduleSharingService.shared
        let meta = ShareMeta(code: "SETTING", owner: "朋友", schoolID: "test", schoolName: "测试学校",
                             name: "朋友", termID: "fall", termVersion: 1, courseCount: 1,
                             semesterStartMonday: "2026-09-07", weekCount: 20, updatedAt: "1")
        let shared = FollowedSchedule(meta: meta, courses: local.courses, classTimes: remote.table.classTimeList,
                                      adjustments: [], fetchedAt: Date())
        try sharing.saveShared(shared, remark: "原备注")
        sharing.follow(sharing.sharedSchedules.first { $0.meta.code == "SETTING" }!)
        await service.syncNow()
        precondition(service.pendingReview == nil, "Local shared timetable uploads need no review")
        sharing.unfollow()
        cloud.document.entries["settings:caring"] = CloudSyncEntry(modifiedAt: Date().addingTimeInterval(1000), writer: "ipad",
            payload: .caring(CloudCaringSelection(code: "SETTING")))
        await service.syncNow()
        precondition(sharing.followedCode == "SETTING" && service.pendingReview == nil && !service.isReviewPresented,
                     "Caring selection must apply without a prompt")

        remote.courses[0].teacher = "待接收教师"
        cloud.document.entries[key] = CloudSyncEntry(modifiedAt: Date().addingTimeInterval(2000), writer: "ipad",
            writerName: "课表设备", payload: .table(remote))
        await service.syncNow()
        let pending = service.pendingReview!
        precondition(pending.changes.count == 1 && pending.changes[0].key == key)
        service.deferReview()
        let other = local.addTable(name: "独立上传课表")
        local.addCourse(Course(tableId: other.id, name: "英语", weeks: [1], weekTime: 2,
                               startTime: 1, timeCount: 0, importType: ImportKind.imported))
        var updatedShare = sharing.sharedSchedules.first { $0.meta.code == "SETTING" }!
        updatedShare.remark = "自动同步新备注"
        cloud.document.entries["shared:SETTING"] = CloudSyncEntry(modifiedAt: Date().addingTimeInterval(2500), writer: "ipad", payload: .shared(updatedShare))
        remote.table.name = "最新课表名称"
        cloud.document.entries[key] = CloudSyncEntry(modifiedAt: Date().addingTimeInterval(3000), writer: "ipad",
            writerName: "课表设备", payload: .table(remote))
        await service.syncNow()
        precondition(service.pendingReview!.id == pending.id && !service.isReviewPresented,
                     "Unrelated settings must not reopen a deferred review")
        precondition(sharing.sharedSchedules.first { $0.meta.code == "SETTING" }!.remark == "自动同步新备注")
        precondition(cloud.document.entries["table:" + other.syncID!] != nil, "Local uploads continue while a review waits")
        precondition(local.courses.first { $0.tableId == table.id }!.teacher == "本机教师")
        await service.confirmReview(pending.id, destinations: [:])
        precondition(local.courses.first { $0.tableId == table.id }!.teacher == "待接收教师" && service.pendingReview == nil)
        precondition(local.tables.first { $0.id == table.id }!.name == "最新课表名称",
                     "Metadata updates must not require a separate confirmation")

        var newShare = updatedShare
        newShare.meta.code = "NEWCARE"
        newShare.remark = "待接收共享课表"
        cloud.document.entries["shared:NEWCARE"] = CloudSyncEntry(modifiedAt: Date().addingTimeInterval(3500), writer: "ipad", payload: .shared(newShare))
        cloud.document.entries["settings:caring"] = CloudSyncEntry(modifiedAt: Date().addingTimeInterval(3501), writer: "ipad",
            payload: .caring(CloudCaringSelection(code: "NEWCARE")))
        await service.syncNow()
        precondition(service.pendingReview!.changes.map(\.key) == ["shared:NEWCARE"])
        precondition(sharing.followedCode == "SETTING" && !sharing.sharedSchedules.contains { $0.meta.code == "NEWCARE" },
                     "A caring setting must not bypass confirmation of its new shared timetable")
        await service.confirmReview(service.pendingReview!.id, destinations: [:])
        precondition(sharing.followedCode == "NEWCARE" && service.pendingReview == nil)

        // Incoming deletion is reviewed; local deletion uploads silently.
        cloud.document.entries[key] = CloudSyncEntry(modifiedAt: Date().addingTimeInterval(4000), writer: "ipad", payload: nil)
        await service.syncNow()
        precondition(service.pendingReview != nil && local.tables.contains { $0.id == table.id })
        await service.confirmReview(service.pendingReview!.id, destinations: [:])
        precondition(!local.tables.contains { $0.id == table.id })
        local.deleteTable(other.id)
        await service.syncNow()
        precondition(service.pendingReview == nil && cloud.document.entries["table:" + other.syncID!]!.payload == nil)
        service.setEnabled(false)
    }
}
