import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Darwin)
import Darwin
#endif

/// Independent of ActivityKit: only this allowlisted payload enters usage statistics.
@MainActor final class UsageReportingService {
    static let shared = UsageReportingService()
    private let defaults: UserDefaults
    private let identityStorage: UsageIdentity.Storage
    private let transport: (URLRequest) async throws -> (Data, URLResponse)
    private var sending = false
    private var pending: (URL, String?)?
    private var lastPayload: Data?
    private var lastURL: URL?
    private var lastSent = Date.distantPast

    init(defaults: UserDefaults = .standard,
         identityStorage: UsageIdentity.Storage? = nil,
         transport: @escaping (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) {
        self.defaults = defaults
        self.identityStorage = identityStorage ?? UsageIdentity.keychain
        self.transport = transport
    }
    func report(schoolID: String?, baseURL: URL?) async {
        guard PrivacyPolicy.basicAllowed(defaults), let baseURL else { return }
        pending = (baseURL, schoolID)
        guard !sending else { return }
        sending = true
        defer { sending = false }
        while let (base, school) = pending {
            pending = nil
            guard PrivacyPolicy.basicAllowed(defaults), base.scheme == "https" else { return }
            // A temporarily inaccessible keychain is not a new device. Retry later.
            guard let identity = try? UsageIdentity.resolve(defaults: defaults, storage: identityStorage) else { continue }
            let url = base.appendingPathComponent("v1/usage/devices").appendingPathComponent(identity.installationID)
            let payload: [String: Any] = [
                "consentVersion": PrivacyPolicy.version, "schoolID": school ?? "",
                "systemName": Self.systemName, "systemVersion": Self.systemVersion,
                "deviceModel": Self.deviceModel,
                "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            ]
            guard let body = try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys) else { return }
            // A new UTC+8 day always reports, so the first open after midnight counts toward that day.
            if body == lastPayload, url == lastURL, Date().timeIntervalSince(lastSent) < 3600,
               Self.usageDay(Date()) == Self.usageDay(lastSent) { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(identity.secret, forHTTPHeaderField: "X-Device-Secret")
            do {
                let (_, response) = try await transport(await AppAttestService.shared.signed(request))
                AppAttestService.shared.observe(response)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    lastPayload = body; lastURL = url; lastSent = Date()
                }
            } catch { /* Retry on next foreground or school change; never block import. */ }
        }
    }
    nonisolated static func usageDay(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 + 8 * 3600) / 86_400)
    }
    private static var systemName: String {
        #if canImport(UIKit)
        UIDevice.current.systemName
        #else
        "macOS"
        #endif
    }
    private static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
    private static var deviceModel: String {
        #if targetEnvironment(simulator)
        return "Simulator (\(ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "unknown"))"
        #elseif os(macOS)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        if sysctlbyname("hw.model", &model, &size, nil, 0) == 0 { return String(cString: model) }
        return "Mac"
        #else
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        #endif
    }
}
