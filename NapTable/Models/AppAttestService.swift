import CryptoKit
import Foundation
#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// App Attest for the writes the server guards: publishing a share, adding a
/// Live Activity device or timetable, and usage reports. `signed` adds headers
/// proving the request comes from this app on a genuine Apple device.
///
/// Where App Attest is unavailable (the simulator, an unsupported device, an
/// attestation that failed) the request goes out unsigned, as before; the
/// server counts that and, in its default mode, still accepts it. The key id
/// is a random identifier of this installation, nothing personal.
actor AppAttestService {
    static let shared = AppAttestService()
    private static let keyIDKey = "naptable.appAttest.keyID"
    /// Apple rate-limits attestation: after a failure, wait this long.
    private static let retryAfter: TimeInterval = 3600

    private var attesting: Task<String?, Never>?
    private var failedAt: Date?

    /// `request` with App Attest headers when its path is one the server
    /// checks and a key is (or can be) attested; otherwise unchanged.
    func signed(_ request: URLRequest) async -> URLRequest {
        #if canImport(DeviceCheck)
        guard let url = request.url, let method = request.httpMethod,
              let path = URLComponents(url: url, resolvingAgainstBaseURL: true)?.percentEncodedPath,
              Self.guarded(method: method, path: path),
              DCAppAttestService.shared.isSupported,
              let keyID = await attestedKey(base: url) else { return request }
        let stamp = String(Int(Date().timeIntervalSince1970))
        let bodyHash = SHA256.hash(data: request.httpBody ?? Data()).map { String(format: "%02x", $0) }.joined()
        let clientData = Data("\(method)\n\(path)\n\(stamp)\n\(bodyHash)".utf8)
        do {
            let assertion = try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: Data(SHA256.hash(data: clientData)))
            var signed = request
            signed.setValue(keyID, forHTTPHeaderField: "X-App-Attest-Key")
            signed.setValue(stamp, forHTTPHeaderField: "X-App-Attest-Time")
            signed.setValue(assertion.base64EncodedString(), forHTTPHeaderField: "X-App-Attest-Assertion")
            return signed
        } catch {
            // The key is gone (restored backup, reset device): attest a new one next time.
            if (error as? DCError)?.code == .invalidKey { UserDefaults.standard.removeObject(forKey: Self.keyIDKey) }
            return request
        }
        #else
        return request
        #endif
    }

    /// The server did not know the key (its data was reset): attest again.
    nonisolated func observe(_ response: URLResponse) {
        guard (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-App-Attest-Status") == "unknownKey" else { return }
        UserDefaults.standard.removeObject(forKey: Self.keyIDKey)
    }

    /// The writes `server/app_attest.py` checks. Anything else is not signed,
    /// so it does not spend the key's counter.
    nonisolated static func guarded(method: String, path: String) -> Bool {
        switch method {
        case "POST":
            return path == "/v1/shares" || (path.hasPrefix("/v1/shares/") && path.hasSuffix("/replace"))
                || path == "/v2/live-activity/devices" || path.hasPrefix("/v1/usage/devices/")
        case "PUT":
            return (path.hasPrefix("/v1/shares/") && path.dropFirst("/v1/shares/".count).allSatisfy { $0 != "/" })
                || (path.hasPrefix("/v2/live-activity/devices/") && path.hasSuffix("/timetable"))
        default:
            return false
        }
    }

    #if canImport(DeviceCheck)
    private func attestedKey(base: URL) async -> String? {
        if let keyID = UserDefaults.standard.string(forKey: Self.keyIDKey) { return keyID }
        if let failedAt, Date().timeIntervalSince(failedAt) < Self.retryAfter { return nil }
        // One attestation at a time, however many writes are waiting for it.
        if let attesting { return await attesting.value }
        let task = Task { await Self.attest(base: base) }
        attesting = task
        let keyID = await task.value
        attesting = nil
        if let keyID { UserDefaults.standard.set(keyID, forKey: Self.keyIDKey) } else { failedAt = Date() }
        return keyID
    }

    /// Make a key, have Apple attest it against a server challenge, and hand
    /// the attestation to the server.
    private static func attest(base: URL) async -> String? {
        do {
            let service = DCAppAttestService.shared
            let keyID = try await service.generateKey()
            let challenge = try await post("/v1/app-attest/challenge", base: base, body: [:])["challenge"] as? String ?? ""
            guard !challenge.isEmpty else { return nil }
            let attestation = try await service.attestKey(keyID, clientDataHash: Data(SHA256.hash(data: Data(challenge.utf8))))
            let result = try await post("/v1/app-attest/keys", base: base,
                                        body: ["keyId": keyID, "attestation": attestation.base64EncodedString(), "challenge": challenge])
            return result["registered"] as? Bool == true ? keyID : nil
        } catch {
            return nil
        }
    }

    private static func post(_ path: String, base: URL, body: [String: String]) async throws -> [String: Any] {
        guard let url = URL(string: path, relativeTo: base) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
    #endif
}
