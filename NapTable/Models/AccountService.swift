import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import Security

/// What the server says an account may do with Live Activity reminders.
nonisolated struct AccountEntitlement: Codable, Equatable {
    /// `free` before charging starts, `subscription`, `credit`, or nil: none.
    var active: Bool
    var source: String?
    var creditDays: Int
    var chargedToday: Bool
    var subscriptionExpiresAt: Double?
    var enforced: Bool
    var enforceAfter: String

    /// One line for the settings rows.
    var summary: String {
        switch source {
        case "subscription":
            let until = subscriptionExpiresAt.map { Date(timeIntervalSince1970: $0).formatted(.dateTime.month().day()) }
            return until.map { "已订阅，\($0) 续费" } ?? "已订阅"
        case "credit", "free": return "剩余 \(creditDays) 个使用日"
        default: return "使用日已用完"
        }
    }
}

nonisolated struct AccountSummary: Codable, Equatable {
    /// Eight characters the user reads out to the admin when asking for help.
    var code: String
    var name: String
    var createdAt: Double
    var devices: Int
    /// Path of the avatar on the service, nil when none was chosen.
    var avatar: String?
    var entitlement: AccountEntitlement

    var displayName: String { name.trimmedNonEmpty ?? "未设置昵称" }
}

/// The signed-in account: Sign in with Apple, the session the server hands
/// back, and the profile readers of the user's shares see.
///
/// Only Apple's stable user ID is used; no name or email is requested. The
/// session lives in the keychain, so it never leaves this device in a backup.
@MainActor final class AccountService: ObservableObject {
    static let shared = AccountService()
    private static let keychainService = "naptable.account"
    private static let sessionAccount = "session"
    private static let summaryKey = "naptable.account.summary"
    /// `device:code` of the Live Activity device last bound to the account.
    private static let boundKey = "naptable.account.boundDevice"

    @Published private(set) var account: AccountSummary?
    /// A nonce fetched ahead of the button tap: the Apple request is built synchronously.
    private var nonce: String?
    private let defaults = UserDefaults.standard

    private init() {
        if session != nil, let data = defaults.data(forKey: Self.summaryKey) {
            account = try? JSONDecoder().decode(AccountSummary.self, from: data)
        }
    }

    var isSignedIn: Bool { session != nil }
    var authorizationHeader: [String: String] { session.map { ["Authorization": "Bearer " + $0] } ?? [:] }
    var avatarURL: URL? { account?.avatar.flatMap(Self.url) }
    static func url(_ path: String) -> URL? {
        ScheduleSharingService.shared.validatedBaseURL.flatMap { URL(string: path, relativeTo: $0) }
    }

    // MARK: Sign in

    /// Fetch a single-use nonce before the Sign in with Apple button can be tapped.
    func prepareSignIn() async throws {
        let value = try await send("/v1/account/nonce", method: "POST", body: [String: Any]())
        guard let raw = value["nonce"] as? String else { throw ScheduleServiceError.invalidResponse }
        nonce = raw
    }

    /// Fills in the Apple request: no scopes, and the hash of our nonce, which
    /// Apple signs into the identity token so it cannot be replayed.
    func configure(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = []
        if let nonce { request.nonce = Self.sha256(nonce) }
    }

    func completeSignIn(_ result: Result<ASAuthorization, Error>) async throws {
        let authorization: ASAuthorization
        switch result {
        case .success(let value): authorization = value
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { throw CancellationError() }
            throw ScheduleServiceError.server("Apple 登录没有完成，请稍后重试。")
        }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let token = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }),
              let nonce else { throw ScheduleServiceError.server("Apple 登录没有完成，请稍后重试。") }
        self.nonce = nil
        var body: [String: Any] = ["identityToken": token, "nonce": nonce]
        if let code = credential.authorizationCode.flatMap({ String(data: $0, encoding: .utf8) }) { body["authorizationCode"] = code }
        let value = try await send("/v1/account/apple", method: "POST", body: body)
        guard let session = value["session"] as? String, let summary = value["account"] else { throw ScheduleServiceError.invalidResponse }
        try saveSession(session)
        try accept(summary)
        defaults.removeObject(forKey: Self.boundKey)
        #if os(iOS)
        // The Live Activity device joins the account on its next sync.
        if #available(iOS 17.2, *) { Task { await LiveActivityPushService.shared.refreshStatus() } }
        #endif
    }

    // MARK: Account

    /// Reload the account; a session the server no longer knows signs out here too.
    func refresh() async {
        guard isSignedIn else { return }
        do { try accept(try await send("/v1/account", method: "GET")) }
        catch AccountServiceError.signedOut { clearLocal() }
        catch {}
    }

    func setName(_ name: String) async throws {
        try accept(try await send("/v1/account/profile", method: "PUT", body: ["name": name]))
    }

    /// A square photo the caller already scaled down, as JPEG.
    func setAvatar(_ jpeg: Data) async throws {
        try accept(try await send("/v1/account/avatar", method: "PUT", body: ["image": jpeg.base64EncodedString()]))
    }

    func clearAvatar() async throws {
        try accept(try await send("/v1/account/avatar", method: "DELETE"))
    }

    func signOut() async {
        if let device = boundDevice {
            _ = try? await send("/v1/account/devices/\(device)", method: "DELETE")
        }
        _ = try? await send("/v1/account/session", method: "DELETE")
        clearLocal()
    }

    /// Deletes the account on the server; an App Store subscription is not
    /// cancelled by this and has to be cancelled in the system settings.
    func deleteAccount() async throws {
        _ = try await send("/v1/account", method: "DELETE")
        clearLocal()
    }

    /// The Live Activity push service calls this once the device is
    /// registered: reminders of this device then count against the account.
    func bindIfNeeded(device: String, secret: String) async {
        guard let code = account?.code, defaults.string(forKey: Self.boundKey) != device + ":" + code else { return }
        do {
            try accept(try await send("/v1/account/devices/\(device)", method: "PUT", headers: ["X-Device-Secret": secret]))
            defaults.set(device + ":" + code, forKey: Self.boundKey)
        } catch AccountServiceError.signedOut { clearLocal() }
        catch {}
    }

    private var boundDevice: String? {
        defaults.string(forKey: Self.boundKey)?.split(separator: ":").first.map(String.init)
    }

    private func accept(_ value: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: value)
        let summary = try JSONDecoder().decode(AccountSummary.self, from: data)
        account = summary
        defaults.set(data, forKey: Self.summaryKey)
        #if os(iOS)
        NativeLiveActivityController.shared.reminderAllowed = summary.entitlement.active
        #endif
    }

    private func clearLocal() {
        removeSession()
        account = nil
        for key in [Self.summaryKey, Self.boundKey] { defaults.removeObject(forKey: key) }
        #if os(iOS)
        // Signed out: the next sync says whether this device may still have reminders.
        if #available(iOS 17.2, *) { Task { await LiveActivityPushService.shared.refreshStatus() } }
        #endif
    }

    // MARK: Transport

    private func send(_ path: String, method: String, body: [String: Any]? = nil, headers: [String: String] = [:]) async throws -> [String: Any] {
        guard let url = Self.url(path) else { throw ScheduleServiceError.missingBaseURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in authorizationHeader.merging(headers, uniquingKeysWith: { _, new in new }) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ScheduleServiceError.invalidResponse }
        let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if http.statusCode == 401, isSignedIn, !path.hasPrefix("/v1/account/apple") { throw AccountServiceError.signedOut }
        guard (200..<300).contains(http.statusCode) else {
            throw ScheduleServiceError.server(Self.message(value["error"] as? String, status: http.statusCode))
        }
        return value
    }

    /// The server's errors are English protocol text; these are the ones a user can act on.
    private static func message(_ error: String?, status: Int) -> String {
        switch error {
        case let text? where text.hasPrefix("image must be at most"): return "图片太大，请换一张。"
        case "image must be JPEG or PNG": return "只支持 JPEG 或 PNG 图片。"
        case "name must be at most 20 characters": return "昵称最多 20 个字。"
        case "nonce expired or used", "Apple token expired": return "登录已超时，请重新登录。"
        default: return status >= 500 ? "服务暂时不可用，请稍后重试。" : "操作没有完成，请稍后重试。"
        }
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Keychain

    private var session: String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.keychainService,
                                    kSecAttrAccount as String: Self.sessionAccount, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func saveSession(_ value: String) throws {
        removeSession()
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.keychainService,
                                   kSecAttrAccount as String: Self.sessionAccount, kSecValueData as String: Data(value.utf8),
                                   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ScheduleServiceError.server("登录状态无法保存到钥匙串") }
    }

    private func removeSession() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.keychainService,
                                    kSecAttrAccount as String: Self.sessionAccount]
        SecItemDelete(query as CFDictionary)
    }
}

enum AccountServiceError: Error { case signedOut }
