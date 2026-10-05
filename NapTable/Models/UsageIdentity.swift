import Foundation
import Security

/// A random, app-scoped identity. Keep the ID and its write secret together,
/// on this device only, so reinstalling can reuse the same statistics row.
struct UsageIdentity: Codable, Equatable {
    let installationID: String
    let secret: String

    struct Storage {
        /// nil means absent; a locked/unavailable keychain must throw.
        var read: () throws -> UsageIdentity?
        var insert: (UsageIdentity) throws -> Void
    }

    private static let installationKey = "naptable.usage.installation"
    private static let secretKey = "naptable.usage.secret"

    static func resolve(defaults: UserDefaults, storage: Storage) throws -> UsageIdentity {
        if let saved = try storage.read() {
            clearLegacy(defaults)
            return saved
        }
        let identity: UsageIdentity
        if let id = defaults.string(forKey: installationKey), UUID(uuidString: id) != nil,
           let secret = defaults.string(forKey: secretKey),
           secret.range(of: "^[a-zA-Z0-9_-]{32,128}$", options: .regularExpression) != nil {
            // Preserve the existing server row when upgrading from defaults.
            identity = UsageIdentity(installationID: id, secret: secret)
        } else {
            identity = UsageIdentity(installationID: UUID().uuidString.lowercased(),
                                     secret: UUID().uuidString.replacingOccurrences(of: "-", with: "")
                                           + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
        }
        // Never report an identity until both values have been persisted.
        try storage.insert(identity)
        clearLegacy(defaults)
        return identity
    }

    private static func clearLegacy(_ defaults: UserDefaults) {
        // Do not leave a copy in defaults that a backup could move to another phone.
        defaults.removeObject(forKey: installationKey)
        defaults.removeObject(forKey: secretKey)
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "naptable.usage.identity",
         kSecAttrAccount as String: "identity",
         kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: true]
    }

    private struct KeychainError: Error { let status: OSStatus }

    static var keychain: Storage {
        Storage(read: {
            var query = Self.query
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result as? Data else {
                throw KeychainError(status: status)
            }
            return try JSONDecoder().decode(UsageIdentity.self, from: data)
        }, insert: { identity in
            var query = Self.query
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            query[kSecValueData as String] = try JSONEncoder().encode(identity)
            let status = SecItemAdd(query as CFDictionary, nil)
            // A competing insert must not overwrite an identity already in use.
            // The next foreground report will read the saved pair.
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        })
    }
}
