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
    private let transport: (URLRequest) async throws -> (Data, URLResponse)
    private var sending = false
    private var pending: (URL, String?)?
    private var lastPayload: Data?
    private var lastURL: URL?
    private var lastSent = Date.distantPast

    init(defaults: UserDefaults = .standard,
         transport: @escaping (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) {
        self.defaults = defaults
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
            let id = storedValue("naptable.usage.installation", make: { UUID().uuidString.lowercased() })
            let secret = storedValue("naptable.usage.secret", make: { UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "") })
            let url = base.appendingPathComponent("v1/usage/devices").appendingPathComponent(id)
            let payload: [String: Any] = [
                "consentVersion": PrivacyPolicy.version, "schoolID": school ?? "",
                "systemName": Self.systemName, "systemVersion": Self.systemVersion,
                "deviceModel": Self.deviceModel,
                "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            ]
            guard let body = try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys) else { return }
            if body == lastPayload, url == lastURL, Date().timeIntervalSince(lastSent) < 3600 { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(secret, forHTTPHeaderField: "X-Device-Secret")
            do {
                let (_, response) = try await transport(request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    lastPayload = body; lastURL = url; lastSent = Date()
                }
            } catch { /* Retry on next foreground or school change; never block import. */ }
        }
    }
    private func storedValue(_ key: String, make: () -> String) -> String {
        if let value = defaults.string(forKey: key) { return value }
        let value = make(); defaults.set(value, forKey: key); return value
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
