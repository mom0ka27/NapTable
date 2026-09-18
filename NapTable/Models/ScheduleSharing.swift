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

    var id: String { code }
}

/// What the server says about a share without sending the timetable.
///
/// A follower polls this to decide whether the full download is worth doing,
/// so it carries the term facts that change what a reader renders.
nonisolated struct ShareMeta: Codable, Equatable {
    var code: String
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

    var name: String { meta.name.isEmpty ? meta.schoolName : meta.name }

    /// The same payload an import would install, so "加入我的课表" and "设为提示
    /// 来源" cannot disagree about the sharer's schedule.
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
            termTimezone: nil,
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
                                 label: result.name ?? credential.label, updatedAt: result.updatedAt))
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
                                 label: result.name ?? credential.label, updatedAt: result.updatedAt))
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
        try await fetchFollowed(code)
    }

    /// Make a share the source the widgets and the Live Activity render.
    @discardableResult
    func follow(_ code: String) async throws -> FollowedSchedule {
        let followed = try await fetchFollowed(code)
        persist(followed)
        return followed
    }

    func follow(_ followed: FollowedSchedule) {
        persist(followed)
    }

    func unfollow() {
        groupDefaults?.removeObject(forKey: Self.followedKey)
        UserDefaults.standard.removeObject(forKey: Self.followedCodeKey)
        UserDefaults.standard.removeObject(forKey: Self.followedLabelKey)
        NotificationCenter.default.post(name: .naptableFollowedSourceChanged, object: nil)
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
        guard meta.updatedAt != cached.meta.updatedAt else { return }
        if let refreshed = try? await fetchFollowed(code) { persist(refreshed) }
    }

    private func fetchFollowed(_ code: String) async throws -> FollowedSchedule {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let data = try await request(path: "/v1/shares/\(normalized)", method: "GET")
        let schedule = try CoursePayloadCodec.decode(data: data)
        let meta = try JSONDecoder().decode(ShareMeta.self, from: data)
        guard let classTimes = schedule.classTimeList, !classTimes.isEmpty else {
            throw ScheduleServiceError.server("该分享没有节次时间，无法作为提示来源")
        }
        return FollowedSchedule(
            meta: meta,
            courses: schedule.courses,
            classTimes: classTimes,
            adjustments: schedule.calendarAdjustments ?? [],
            fetchedAt: Date()
        )
    }

    private func persist(_ followed: FollowedSchedule) {
        if let data = try? JSONEncoder().encode(followed) {
            groupDefaults?.set(data, forKey: Self.followedKey)
        }
        UserDefaults.standard.set(followed.meta.code, forKey: Self.followedCodeKey)
        UserDefaults.standard.set(followed.name, forKey: Self.followedLabelKey)
        objectWillChange.send()
        NotificationCenter.default.post(name: .naptableFollowedSourceChanged, object: nil)
    }

    private var groupDefaults: UserDefaults? { UserDefaults(suiteName: NextWidgetConfiguration.appGroup) }
}
