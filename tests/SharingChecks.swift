import Foundation
import Combine

@main
struct SharingChecks {
    @MainActor static func main() async throws {
        var libraryChanges = 0
        var caringChanges = 0
        let libraryObserver = NotificationCenter.default.publisher(for: .naptableFollowedSourceChanged)
            .sink { _ in libraryChanges += 1 }
        let caringObserver = NotificationCenter.default.publisher(for: .naptableCaringSelectionChanged)
            .sink { _ in caringChanges += 1 }
        defer { libraryObserver.cancel(); caringObserver.cancel() }
        let service = ScheduleSharingService.shared
        let keys = ["naptable.importedShares", "naptable.sharedNotifications", "naptable.followedShareCode", "naptable.followedShareLabel", "naptable.shares", "naptable.shareCode", "naptable.shareToken"]
        let defaults = UserDefaults.standard
        let backup = keys.map { defaults.object(forKey: $0) }
        let group = UserDefaults(suiteName: NextWidgetConfiguration.appGroup)!
        let followedBackup = group.object(forKey: "naptable.followedShare")
        defer {
            for (key, value) in zip(keys, backup) { defaults.set(value, forKey: key) }
            group.set(followedBackup, forKey: "naptable.followedShare")
        }
        for key in keys { defaults.removeObject(forKey: key) }
        group.removeObject(forKey: "naptable.followedShare")
        let app = AppStore(fileURL: nil)
        let store = NativeScheduleStore()
        store.connect(app)
        let ownCourses = app.currentCourses
        let ownWeek = app.displayWeek
        let ownPeriods = store.periods
        let meta = ShareMeta(code: "TEST123", owner: "我", schoolID: "test", schoolName: "测试学校", name: "我 · 测试学校", termID: "test", termVersion: 1, courseCount: 1, semesterStartMonday: "2026-09-14", weekCount: 4, updatedAt: "1")
        let shared = FollowedSchedule(meta: meta,
            courses: [Course(tableId: 0, name: "对方课程", weeks: [1, 2], weekTime: 1, startTime: 1, timeCount: 0, importType: ImportKind.imported)],
            classTimes: [ClassTime(start: "10:10", end: "11:00")], adjustments: [], fetchedAt: Date())
        precondition(shared.name == "测试学校", "Legacy publisher names must not appear in the display name")
        precondition(shared.importedSchedule.name == "测试学校")
        service.remember(ShareCredential(code: "OWN123", token: "test-token", label: "自己的课表", updatedAt: "1"))
        do {
            _ = try await service.previewShare(" \nown123 ")
            preconditionFailure("Own shares must be rejected before downloading")
        } catch {
            precondition(error.localizedDescription.contains("不能导入自己分享的课表"))
        }
        var ownShare = shared
        ownShare.meta.code = " own123 "
        do {
            try service.saveShared(ownShare, remark: "自己")
            preconditionFailure("Saving an own share must also fail")
        } catch {
            precondition(error.localizedDescription.contains("不能导入自己分享的课表"))
        }
        precondition(service.sharedSchedules.isEmpty && service.followedCode == nil)
        do {
            try service.saveShared(shared, remark: " \n ")
            preconditionFailure("Blank remarks must fail")
        } catch { }
        try service.saveShared(shared, remark: " 小明 ")
        precondition(service.sharedSchedules.first?.name == "小明")
        try service.saveShared(shared, remark: "小明同学")
        precondition(service.sharedSchedules.count == 1)
        let beforeFollow = libraryChanges
        service.follow(service.sharedSchedules[0])
        precondition(libraryChanges == beforeFollow && caringChanges == 1,
                     "Caring must update Live Activities without rebuilding the timetable or widgets")
        service.follow(service.sharedSchedules[0])
        precondition(caringChanges == 1, "Selecting the same source again must not replan")
        try service.saveShared(shared, remark: "小明同学")
        precondition(libraryChanges == beforeFollow + 1 && caringChanges == 1,
                     "Updating a followed share must publish only one library refresh")
        precondition(service.sharedNotificationsEnabled)
        defaults.set(false, forKey: "naptable.sharedNotifications")
        precondition(service.sharedNotificationsEnabled, "Legacy notification opt-out must not override caring")
        precondition(store.snapshot()?.sourceLabel == "小明同学")
        precondition(store.snapshot()?.periods.first?.startTime == "10:10")
        await store.selectSemester("share:TEST123")
        precondition(store.isReadOnly && store.sourceLabel == "小明同学")
        precondition(store.periods.first?.startTime == "10:10")
        precondition(store.result?.cells.first?.courses.first?.name == "对方课程")
        store.commitWeekSelection("4")
        precondition(app.displayWeek == ownWeek && store.selectedWeek == "4")
        precondition(store.snapshot(useSharedNotifications: false)?.periods == ownPeriods)
        do {
            try await store.saveScheduleEdits(NativeScheduleEditState())
            preconditionFailure("Shared schedules must be read only")
        } catch { }
        precondition(app.currentCourses == ownCourses)
        service.unfollow()
        precondition(!service.sharedNotificationsEnabled)
        precondition(store.snapshot()?.sourceLabel == nil)
        precondition(store.sourceLabel == "小明同学")
        var another = shared
        another.meta.code = "OTHER123"
        try service.saveShared(another, remark: "小红")
        service.follow(service.sharedSchedules.first { $0.meta.code == "OTHER123" }!)
        precondition(store.snapshot()?.sourceLabel == "小红")
        service.follow(service.sharedSchedules.first { $0.meta.code == "TEST123" }!)
        precondition(store.snapshot()?.sourceLabel == "小明同学")
        let beforeRemoval = libraryChanges
        let caringBeforeRemoval = caringChanges
        service.removeShared("TEST123")
        precondition(libraryChanges == beforeRemoval + 1 && caringChanges == caringBeforeRemoval,
                     "Removal must refresh once, including falling back to the local notification source")
        await store.refresh()
        precondition(!store.isReadOnly && service.followedCode == nil)
        precondition(store.periods == ownPeriods)
        print("PASS: own-share rejection, required remarks, duplicate import, caring selects notifications, legacy settings, switching and cancellation, independent viewing and weeks, read-only protection, removal fallback")
    }
}
