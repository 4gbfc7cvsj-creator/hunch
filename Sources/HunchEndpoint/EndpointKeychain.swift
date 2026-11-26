// API key storage. The key is read only when a request is built and is never logged.
import Foundation
import Security

public protocol EndpointKeyProviding: Sendable {
    func apiKey(forAccount account: String) -> String?
}

/// Generic-password items, service "Hunch Endpoint".
public struct KeychainKeyStore: EndpointKeyProviding {
    public static let service = "Hunch Endpoint"
    /// Where keys were saved before the app was renamed. Read only when the new service has no
    /// key for the account; a key found there is copied to the new service.
    public static let legacyServices = ["GhostWriter Endpoint", "GhostType Endpoint"] // LEGACY_GHOSTTYPE
    public init() {}

    private func query(_ account: String, service: String = KeychainKeyStore.service) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func read(_ account: String, service: String) -> String? {
        var q = query(account, service: service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    public func apiKey(forAccount account: String) -> String? {
        if let key = read(account, service: Self.service) { return key }
        for legacy in Self.legacyServices {
            guard let old = read(account, service: legacy) else { continue }
            if setAPIKey(old, forAccount: account) {
                SecItemDelete(query(account, service: legacy) as CFDictionary)
            }
            return old
        }
        return nil
    }

    /// Whether a key exists, from item attributes only; the secret is never read.
    public func hasKey(forAccount account: String) -> Bool {
        ([Self.service] + Self.legacyServices).contains { service in
            var q = query(account, service: service)
            q[kSecReturnAttributes as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
        }
    }

    /// Adds or replaces the key. Returns false on a Keychain error.
    @discardableResult
    public func setAPIKey(_ key: String, forAccount account: String) -> Bool {
        let data = Data(key.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = query(account)
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public func deleteAPIKey(forAccount account: String) -> Bool {
        for legacy in Self.legacyServices { SecItemDelete(query(account, service: legacy) as CFDictionary) }
        let status = SecItemDelete(query(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
