import Combine
import Foundation

/// The write credential for one share this device published.
///
/// The server has no accounts: a share is only manageable by whoever holds the
/// `writeToken` it returned once. Keeping a *list* rather than a single slot is
/// what makes a second share stop orphaning the first, which could then never
/// be updated or revoked.
nonisolated struct ShareCredential: Codable, Equatable, Identifiable {
    var code: String
    var token: String
    var label: String
    var updatedAt: String
    var tableID: Int? = nil
    var fingerprint: String? = nil

    var id: String { code }
}

/// What the server says about a share without sending the timetable.
///
/// A follower polls this to decide whether the full download is worth doing,
/// so it carries the term facts that change what a reader renders.
nonisolated struct ShareMeta: Codable, Equatable {
    var code: String
    var scheduleScope: String? = nil
    var timeZone: String? = nil
    var owner: String
    var schoolID: String
    var schoolName: String
    var name: String
    var termID: String
    var termVersion: Int
    var courseCount: Int
    var semesterStartMonday: String
    var weekCount: Int
    /// 只在 `/meta` 里有，用来发现调休表变了而课程没变。
    var adjustmentCount: Int?
    var updatedAt: String

    private enum CodingKeys: String, CodingKey {
        case scheduleScope, timeZone
        case code = "id", owner, schoolID, schoolName, name, termID, termVersion, courseCount
        case semesterStartMonday = "semester_start_monday"
        case weekCount = "term_week_count"
        case adjustmentCount, updatedAt
    }
}

/// Somebody else's timetable, cached whole.
///
/// The companion surfaces render this instead of the local table when a source
/// is being followed, so it has to carry the sharer's *school* schedule too:
/// their first Monday, their week count and their bell times. Reusing the
/// reader's own periods would put every class in the wrong row.
nonisolated struct FollowedSchedule: Codable, Equatable {
    var meta: ShareMeta
    var courses: [Course]
    var classTimes: [ClassTime]
    /// 对方学校这个学期的调休。没有就是空表，不会借用本机的。
    var adjustments: [CalendarAdjustment]
    var fetchedAt: Date
    var remark: String? = nil

    // Older servers include the publisher in meta.name; never use it as a display label.
    var name: String { remark?.trimmedNonEmpty ?? meta.schoolName.trimmedNonEmpty ?? "共享课表" }

    /// A complete import payload retaining the sharer's school calendar.
    var importedSchedule: ImportedSchedule {
        ImportedSchedule(
            name: name,
            courses: courses,
            classTimeList: classTimes,
            semesterStartMonday: meta.semesterStartMonday,
            schoolID: meta.schoolID,
            termID: meta.termID,
            termVersion: meta.termVersion,
            termWeekCount: meta.weekCount,
            termTimezone: meta.timeZone,
            calendarAdjustments: adjustments.isEmpty ? nil : adjustments
        )
    }
}

extension ScheduleSharingService {
    private static let credentialsKey = "naptable.shares"
    private static let followedKey = "naptable.followedShare"
    /// Written since the first version of the share screen; kept so an app
    /// updating over that build keeps following the same source.
    static let followedCodeKey = "naptable.followedShareCode"
    static let followedLabelKey = "naptable.followedShareLabel"

    private static let importedKey = "naptable.importedShares"

    var sharedSchedules: [FollowedSchedule] {
        if let data = UserDefaults.standard.data(forKey: Self.importedKey),
           let saved = try? JSONDecoder().decode([FollowedSchedule].self, from: data) {
            return saved
        }
        return followedSchedule.map { [$0] } ?? []
    }

    /// Caring selects the Live Activity source, including previously saved follows.
    var sharedNotificationsEnabled: Bool { followedCode != nil }

    func saveShared(_ schedule: FollowedSchedule, remark: String) throws {
        try validateImportCode(schedule.meta.code)
        guard let remark = remark.trimmedNonEmpty else {
            throw ScheduleServiceError.server("请填写备注，方便识别共享课表")
        }
        var saved = schedule
        saved.remark = remark
        var list = sharedSchedules.filter { $0.meta.code != saved.meta.code }
        list.append(saved)
        UserDefaults.standard.set(try JSONEncoder().encode(list), forKey: Self.importedKey)
        if followedCode == saved.meta.code { persist(saved, notify: false) }
        sourceChanged()
    }

    func removeShared(_ code: String) {
        let list = sharedSchedules.filter { $0.meta.code != code }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: Self.importedKey)
        }
        if followedCode == code { unfollow(notify: false) }
        sourceChanged()
    }

    private func sourceChanged() {
        objectWillChange.send()
        NotificationCenter.default.post(name: .naptableFollowedSourceChanged, object: nil)
    }

    // MARK: - My shares

    var myShares: [ShareCredential] {
        if let data = UserDefaults.standard.data(forKey: Self.credentialsKey),
           let list = try? JSONDecoder().decode([ShareCredential].self, from: data) {
            return list
        }
        // One-time migration from the single-share slot.
        let defaults = UserDefaults.standard
        guard let code = defaults.string(forKey: "naptable.shareCode"),
              let token = defaults.string(forKey: "naptable.shareToken") else { return [] }
        let migrated = [ShareCredential(code: code, token: token, label: code, updatedAt: "")]
        store(migrated)
        return migrated
    }

    func remember(_ credential: ShareCredential) {
        var list = myShares.filter { $0.code != credential.code }
        list.append(credential)
        store(list)
    }

    func replaceRemembered(_ previous: [ShareCredential], with credential: ShareCredential) {
        var list = myShares.filter { !previous.map(\.code).contains($0.code) && $0.code != credential.code }
        list.append(credential)
        store(list)
    }

    private func store(_ list: [ShareCredential]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: Self.credentialsKey)
        objectWillChange.send()
    }

    /// Republish the courses of an existing share. The share stays on its own
    /// school and term unless the caller moves it.
    @discardableResult
    func update(_ credential: ShareCredential, courses: [Course], schoolID: String? = nil, termID: String? = nil) async throws -> SharedScheduleEnvelope {
        var body: [String: Any] = ["courses": try courses.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }]
        if let schoolID { body["schoolID"] = schoolID }
        if let termID { body["termID"] = termID }
        let data = try await request(path: "/v1/shares/\(credential.code)", method: "PUT", body: body,
                                     headers: ["X-Write-Token": credential.token])
        let result = try JSONDecoder().decode(SharedScheduleEnvelope.self, from: data)
        remember(ShareCredential(code: credential.code, token: credential.token,
                                 label: result.schoolName, updatedAt: result.updatedAt))
        return result
    }

    /// Adopt the school's current term configuration. A published share keeps
    /// the times it was created with, so an admin correcting a bell schedule
    /// only reaches readers when the owner asks for it here.
    @discardableResult
    func resync(_ credential: ShareCredential) async throws -> SharedScheduleEnvelope {
        let data = try await request(path: "/v1/shares/\(credential.code)/resync", method: "POST",
                                     headers: ["X-Write-Token": credential.token])
        let result = try JSONDecoder().decode(SharedScheduleEnvelope.self, from: data)
        remember(ShareCredential(code: credential.code, token: credential.token,
                                 label: result.schoolName, updatedAt: result.updatedAt))
        return result
    }

    func revoke(_ credential: ShareCredential) async throws {
        _ = try await request(path: "/v1/shares/\(credential.code)", method: "DELETE",
                              headers: ["X-Write-Token": credential.token])
        store(myShares.filter { $0.code != credential.code })
    }

    // MARK: - Following somebody else's timetable

    var followedSchedule: FollowedSchedule? {
        guard let data = groupDefaults?.data(forKey: Self.followedKey) else { return nil }
        return try? JSONDecoder().decode(FollowedSchedule.self, from: data)
    }

    var followedCode: String? {
        UserDefaults.standard.string(forKey: Self.followedCodeKey)?.trimmedNonEmpty
    }

    /// Download a share without committing to it, for the preview card.
    func previewShare(_ code: String) async throws -> FollowedSchedule {
        try validateImportCode(code)
        return try await fetchFollowed(code)
    }

    /// 分享归属以本机保存的管理凭证判断，不能用公开的发布者名称判断。
    private func validateImportCode(_ code: String) throws {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !myShares.contains(where: {
            $0.code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == normalized
        }) else {
            throw ScheduleServiceError.server("不能导入自己分享的课表，请直接查看自己的课表")
        }
    }

    /// Restore a followed source whose cached payload is missing.
    @discardableResult
    func follow(_ code: String) async throws -> FollowedSchedule {
        var followed = try await fetchFollowed(code)
        guard followedCode == code else { return followed }
        followed.remark = sharedSchedules.first { $0.meta.code == code }?.remark
        persist(followed)
        return followed
    }

    func follow(_ followed: FollowedSchedule) {
        guard followedSchedule != followed else { return }
        persist(followed, notify: false)
        caringSelectionChanged()
    }

    func unfollow(notify: Bool = true) {
        groupDefaults?.removeObject(forKey: Self.followedKey)
        UserDefaults.standard.removeObject(forKey: Self.followedCodeKey)
        UserDefaults.standard.removeObject(forKey: Self.followedLabelKey)
        UserDefaults.standard.removeObject(forKey: "naptable.sharedNotifications")
        if notify { caringSelectionChanged() }
    }

    private func caringSelectionChanged() {
        objectWillChange.send()
        NotificationCenter.default.post(name: .naptableCaringSelectionChanged, object: nil)
    }

    /// Re-download only when the share actually moved. The meta document is a
    /// few hundred bytes against a whole timetable.
    func refreshFollowed() async {
        guard let code = followedCode else { return }
        guard let cached = followedSchedule else {
            _ = try? await follow(code)
            return
        }
        guard let data = try? await request(path: "/v1/shares/\(code)/meta", method: "GET"),
              let meta = try? JSONDecoder().decode(ShareMeta.self, from: data) else { return }
        // `updatedAt` is bumped by every server-side write, and the full share
        // document carries no `adjustmentCount`, so comparing whole metas
        // would re-download on every poll.
        guard meta.updatedAt != cached.meta.updatedAt || meta.scheduleScope != cached.meta.scheduleScope || meta.timeZone != cached.meta.timeZone else { return }
        if var refreshed = try? await fetchFollowed(code), followedCode == code {
            refreshed.remark = cached.remark
            try? saveShared(refreshed, remark: cached.name)
        }
    }

    private func fetchFollowed(_ code: String) async throws -> FollowedSchedule {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let data = try await request(path: "/v1/shares/\(normalized)", method: "GET")
        let schedule = try CoursePayloadCodec.decode(data: data)
        let meta = try JSONDecoder().decode(ShareMeta.self, from: data)
        guard let classTimes = schedule.classTimeList, !classTimes.isEmpty else {
            throw ScheduleServiceError.server("该分享没有节次时间，无法作为提示来源")
        }
        // Preserve publisher row IDs independently of the import editor, which
        // intentionally reassigns IDs when installing into a local table.
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let rows = object?["courses"] as? [[String: Any]] ?? []
        var courses = schedule.courses
        if rows.count == courses.count {
            let ids = rows.map { ($0["id"] as? NSNumber)?.intValue ?? 0 }
            let unique = Set(ids).count == ids.count
            for index in courses.indices { courses[index].id = unique && ids[index] > 0 ? ids[index] : 0 }
        }
        return FollowedSchedule(
            meta: meta,
            courses: courses,
            classTimes: classTimes,
            adjustments: schedule.calendarAdjustments ?? [],
            fetchedAt: Date()
        )
    }

    private func persist(_ followed: FollowedSchedule, notify: Bool = true) {
        if let data = try? JSONEncoder().encode(followed) {
            groupDefaults?.set(data, forKey: Self.followedKey)
        }
        UserDefaults.standard.set(followed.meta.code, forKey: Self.followedCodeKey)
        UserDefaults.standard.set(followed.name, forKey: Self.followedLabelKey)
        if notify { sourceChanged() }
    }

    private var groupDefaults: UserDefaults? { UserDefaults(suiteName: NextWidgetConfiguration.appGroup) }
}

extension Notification.Name {
    static let naptableCaringSelectionChanged = Notification.Name("naptable.caringSelectionChanged")
    static let naptableFollowedSourceChanged = Notification.Name("naptable.followedSourceChanged")
}
