import Foundation
import Combine

nonisolated struct AppAnnouncement: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case update, notice }
    let id: String
    let kind: Kind
    let platform: String
    let enabled: Bool
    let title: String
    let subtitle: String
    let body: String
    let version: String
    let minVersion: String
    let maxVersion: String
    let actionTitle: String
    let actionURL: String
    let startsAt: Double?
    let endsAt: Double?

    var historyID: String { "\(kind.rawValue):\(id):\(kind == .update ? version : "")" }
    var actionLink: URL? { Self.safeLink(actionURL) }
    var label: String { kind == .update ? "发现新版本" : "重要通知" }
    var icon: String { kind == .update ? "sparkles" : "megaphone.fill" }
    var buttonTitle: String { actionTitle.isEmpty ? (kind == .update ? "前往更新" : "查看详情") : actionTitle }

    static func safeLink(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func versionParts(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.count <= 6 && $0.allSatisfy({ $0 >= "0" && $0 <= "9" }) }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers + Array(repeating: 0, count: 4 - numbers.count)
    }

    func applies(to current: String, platform currentPlatform: String, now: Date) -> Bool {
        guard enabled, platform == "all" || platform == currentPlatform,
              let current = Self.versionParts(current),
              startsAt.map({ $0 <= now.timeIntervalSince1970 }) ?? true,
              endsAt.map({ now.timeIntervalSince1970 < $0 }) ?? true else { return false }
        if !minVersion.isEmpty {
            guard let minimum = Self.versionParts(minVersion), !current.lexicographicallyPrecedes(minimum) else { return false }
        }
        if !maxVersion.isEmpty {
            guard let maximum = Self.versionParts(maxVersion), !maximum.lexicographicallyPrecedes(current) else { return false }
        }
        if kind == .update {
            guard let target = Self.versionParts(version), current.lexicographicallyPrecedes(target), actionLink != nil else { return false }
        }
        return !title.isEmpty && !body.isEmpty
    }
}

@MainActor
enum AnnouncementPolicy {
    private static let historyKey = "naptable.announcements.seen"
    private static let spacingKey = "naptable.automaticReminder.lastPresented"
    static func canPresent(kind: AppAnnouncement.Kind? = nil, now: Date = .now, defaults: UserDefaults = .standard) -> Bool {
        guard let last = defaults.object(forKey: spacingKey) as? Double else { return true }
        // A new publication must not wait a day because another message or
        // trial reminder appeared earlier. Only trial reminders retain 24h.
        let spacing: TimeInterval = kind == nil ? 24 * 60 * 60 : 5 * 60
        return now.timeIntervalSince1970 - last >= spacing
    }
    static func pending(_ messages: [AppAnnouncement], currentVersion: String, platform: String, source: String,
                        now: Date = .now, defaults: UserDefaults = .standard) -> AppAnnouncement? {
        let applicable = messages.filter { $0.applies(to: currentVersion, platform: platform, now: now) }
        if let notice = applicable.first(where: { $0.kind == .notice && !hasSeen($0, source: source, defaults: defaults) }) { return notice }
        let latest = applicable.filter { $0.kind == .update }.max {
            (AppAnnouncement.versionParts($0.version) ?? []).lexicographicallyPrecedes(AppAnnouncement.versionParts($1.version) ?? [])
        }
        return latest.flatMap { hasSeen($0, source: source, defaults: defaults) ? nil : $0 }
    }
    static func markAutomatic(now: Date = .now, defaults: UserDefaults = .standard) {
        defaults.set(now.timeIntervalSince1970, forKey: spacingKey)
    }
    static func hasSeen(_ item: AppAnnouncement, source: String, defaults: UserDefaults = .standard) -> Bool {
        let history = defaults.dictionary(forKey: historyKey) as? [String: Double] ?? [:]
        return history[source + "|" + item.historyID] != nil
    }
    static func markSeen(_ item: AppAnnouncement, source: String, now: Date = .now, defaults: UserDefaults = .standard) {
        var history = defaults.dictionary(forKey: historyKey) as? [String: Double] ?? [:]
        history[source + "|" + item.historyID] = now.timeIntervalSince1970
        defaults.set(history, forKey: historyKey)
    }
}

@MainActor
final class AnnouncementStore: ObservableObject {
    static let shared = AnnouncementStore()
    @Published private(set) var messages: [AppAnnouncement] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    private(set) var source = ""
    private var lastAttempt: Date?
    private var lastSuccess: Date?
    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    static var platform: String {
        #if os(macOS)
        "macos"
        #elseif os(visionOS)
        "visionos"
        #else
        "ios"
        #endif
    }
    var applicable: [AppAnnouncement] {
        messages.filter { $0.applies(to: Self.currentVersion, platform: Self.platform, now: .now) }
    }
    var pending: AppAnnouncement? {
        // Do not automatically present stale content after a failed refresh.
        guard errorMessage == nil, let lastSuccess, Date().timeIntervalSince(lastSuccess) < 15 * 60 else { return nil }
        return AnnouncementPolicy.pending(messages, currentVersion: Self.currentVersion, platform: Self.platform, source: source)
    }
    func refresh(force: Bool = false) async {
        guard !isLoading else { return }
        guard let base = ScheduleSharingService.shared.validatedBaseURL,
              let url = URL(string: "/v1/announcements", relativeTo: base)?.absoluteURL else {
            messages = []; errorMessage = "服务地址不可用"; return
        }
        let nextSource = base.absoluteString
        if source != nextSource { messages = []; lastAttempt = nil; lastSuccess = nil; source = nextSource }
        guard force || lastAttempt.map({ Date().timeIntervalSince($0) >= 5 * 60 }) ?? true else { return }
        isLoading = true
        lastAttempt = .now
        defer { isLoading = false }
        do {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 2_000_000 else { throw URLError(.badServerResponse) }
            struct Feed: Decodable { let messages: [AppAnnouncement] }
            let feed = try JSONDecoder().decode(Feed.self, from: data)
            guard feed.messages.count <= 30, Set(feed.messages.map(\.id)).count == feed.messages.count else { throw URLError(.cannotParseResponse) }
            messages = feed.messages
            errorMessage = nil
            lastSuccess = .now
        } catch {
            messages = []
            errorMessage = "暂时无法获取更新与通知，请稍后重试。"
        }
    }
}
