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
        app.addTable(name: "翻页测试", semesterStartMonday: "2026-09-14")
        let store = NativeScheduleStore()
        store.connect(app)
        let ownCourses = app.currentCourses
        let ownWeek = app.displayWeek
        let ownPeriods = store.periods
        let initialResult = store.result
        let initialCalendar = store.calendar
        let initialContentStamp = store.lastUpdatedAt
        let browsingWeek = ownWeek == 1 ? 2 : 1
        store.commitWeekSelection(String(browsingWeek))
        precondition(store.selectedWeek == String(app.displayWeek), "Week selection must commit synchronously")
        await store.refresh()
        precondition(store.result == initialResult && store.calendar == initialCalendar,
                     "Browsing another week must preserve semester content")
        precondition(store.lastUpdatedAt == initialContentStamp, "Browsing must not invalidate layout caches")
        store.commitWeekSelection(String(ownWeek))
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
        precondition(store.viewedSharedSchedule?.name == "小明同学",
                     "Current schedule details must use the viewed share")
        precondition(store.periods.first?.startTime == "10:10")
        precondition(store.result?.cells.first?.courses.first?.name == "对方课程")
        let sharedContentStamp = store.lastUpdatedAt
        store.commitWeekSelection("4")
        precondition(store.lastUpdatedAt == sharedContentStamp, "Shared week browsing must preserve cached content")
        store.commitWeekSelection("999")
        precondition(store.selectedWeek == "4", "Shared browsing must clamp to the semester boundary")
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
        precondition(store.viewedSharedSchedule?.meta.code == "TEST123",
                     "Changing the caring person must not change the current schedule")
        await store.selectSemester(String(app.selectedTableId))
        precondition(store.viewedSharedSchedule == nil && !store.isReadOnly,
                     "Viewing a local table must restore its own settings entry")
        await store.selectSemester("share:TEST123")
        service.follow(service.sharedSchedules.first { $0.meta.code == "TEST123" }!)
        precondition(store.snapshot()?.sourceLabel == "小明同学")
        let beforeRemoval = libraryChanges
        let caringBeforeRemoval = caringChanges
        service.removeShared("TEST123")
        precondition(libraryChanges == beforeRemoval + 1 && caringChanges == caringBeforeRemoval,
                     "Removal must refresh once, including falling back to the local notification source")
        await store.refresh()
        precondition(!store.isReadOnly && service.followedCode == nil)
        precondition(store.viewedSharedSchedule == nil,
                     "Removing the viewed share must clear its settings entry")
        precondition(store.periods == ownPeriods)

        // MARK: Course editor round trip
        // Saving from the editor keeps what it does not manage and leaves untouched rows alone.
        let imported = app.addCourse(Course(tableId: app.selectedTableId, name: "有机化学", weeks: [1, 2, 3], weekTime: 2, startTime: 3, timeCount: 1,
                                            importType: ImportKind.imported, classroom: "1教105", classNumber: "01", teacher: nil, testTime: "第18周",
                                            testLocation: "体育馆", link: "https://example.invalid", info: nil, color: "#8AD297"))
        let untouched = app.addCourse(Course(tableId: app.selectedTableId, name: "物理", weeks: [1], weekTime: 3, startTime: 1, timeCount: 0,
                                             importType: ImportKind.imported, color: "#F9A883"))
        var edits = try await store.loadScheduleEdits()
        try await store.saveScheduleEdits(edits)
        precondition(app.courses.first { $0.id == imported.id } == imported && app.courses.first { $0.id == untouched.id } == untouched,
                     "An unchanged save rewrites nothing")
        let index = edits.custom.firstIndex { $0.id == "course:\(imported.id)" }!
        let old = edits.custom[index].course
        // What the editor sends back: a new room, "" for the empty teacher, the period range for the empty note.
        edits.custom[index] = NativeScheduleCustomItem(id: edits.custom[index].id, sourceKey: nil, day: 2, bigSlot: 2, course: NativeScheduleCourse(
            name: old.name, teacher: "", weeks: old.weeks, weekList: old.weekList, location: "2教201", slotNote: "第 3-4 节",
            startSlot: 3, endSlot: 4, customId: old.customId, custom: true))
        try await store.saveScheduleEdits(edits)
        let saved = app.courses.first { $0.id == imported.id }!
        var expected = imported
        expected.classroom = "2教201"
        precondition(saved == expected, "Only the edited field changes: colour, course key, import kind, exam and link stay")
        precondition(app.courses.first { $0.id == untouched.id } == untouched)

        // 撤销：关注端收到 404 后打上标记，本机副本还在。
        service.markRevoked("OTHER123")
        precondition(service.sharedSchedules.first { $0.meta.code == "OTHER123" }?.isRevoked == true)
        precondition(service.sharedSchedules.first { $0.meta.code == "OTHER123" }?.courses.count == 1)
        let legacyFollowed = try JSONDecoder().decode(FollowedSchedule.self, from: JSONEncoder().encode(shared))
        precondition(!legacyFollowed.isRevoked)
        // 403 时可以只从本机移除凭证。
        service.forget(ShareCredential(code: "OWN123", token: "test-token", label: "", updatedAt: ""))
        precondition(!service.myShares.contains { $0.code == "OWN123" })

        // MARK: 恶意分享
        func row(_ fields: [String: Any]) -> [String: Any] {
            ["name": "课", "weeks": [1, 2], "week_time": 1, "start_time": 1, "time_count": 1].merging(fields) { $1 }
        }
        precondition(CoursePayloadCodec.makeCourse(from: row(["time_count": Int.max])) == nil)
        precondition(CoursePayloadCodec.makeCourse(from: row(["start_time": 1000])) == nil)
        precondition(CoursePayloadCodec.makeCourse(from: row(["week_time": 9])) == nil)
        precondition(CoursePayloadCodec.makeCourse(from: row(["weeks": [99, 1000]])) == nil)
        precondition(CoursePayloadCodec.makeCourse(from: row(["weeks": [0, 3, 50, 3]]))?.weeks == [3])
        precondition(CoursePayloadCodec.makeCourse(from: row(["time_count": 32]))?.endTime == 33)
        let hostile = try CoursePayloadCodec.decode(object: ["name": "x", "courses": [
            row(["time_count": Int.max]), row(["name": "正常"])
        ]])
        precondition(hostile.courses.map(\.name) == ["正常"])
        // App Group / 存档里已经缓存的坏数据：解码时钳进范围，而不是让后面溢出崩溃。
        let cached = Data(#"""
        {"id":1,"tableId":1,"name":"坏","weeks":[1,99,0],"weekTime":12,"startTime":9000,
         "timeCount":9223372036854775807,"importType":1}
        """#.utf8)
        let clamped = try JSONDecoder().decode(Course.self, from: cached)
        precondition(clamped.timeCount == CourseLimits.maxTimeCount && clamped.startTime == 64)
        precondition(clamped.weeks == [1] && clamped.weekTime == 0)
        precondition(Course(tableId: 0, name: "x", weeks: [], weekTime: 1, startTime: Int.max,
                            timeCount: 5, importType: 1).endTime == Int.max)

        print("PASS: own-share rejection, required remarks, duplicate import, caring selects notifications, legacy settings, switching and cancellation, independent viewing and weeks, read-only protection, removal fallback, editor round trip, revoked shares, hostile payload clamping")
    }
}
