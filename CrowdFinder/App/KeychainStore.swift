import Foundation
import Security

/// Tiny wrapper around the iOS Keychain for storing API keys securely on the device.
enum KeychainStore {
    private static let service = Bundle.main.bundleIdentifier ?? "CrowdFinder"

    static func string(for account: String) -> String? {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves `value`, or deletes the item when `value` is `nil`.
    static func set(_ value: String?, for account: String) {
        let query = baseQuery(for: account)
        SecItemDelete(query as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func baseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
