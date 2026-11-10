import Foundation
import Security

/// Generic-password items in the user's keychain, for secrets such as API keys.
/// Never in UserDefaults or files: those are readable by anything with disk access.
///
/// Items are filed under this build's bundle id, so the App Store and direct-download builds
/// never reach for each other's items. That matters: reading an item another app created makes
/// macOS show an access prompt, and the read blocks until the user answers it.
enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "app.clove.Clove"

    static func read(_ account: String) -> String? {
        read(account, service: service)
    }

    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data] as CFDictionary
        let status = SecItemUpdate(baseQuery(account, service: service) as CFDictionary, update)
        if status == errSecItemNotFound {
            var item = baseQuery(account, service: service)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func delete(_ account: String) {
        SecItemDelete(baseQuery(account, service: service) as CFDictionary)
    }

    #if DIRECT
    /// Moves an item saved by an earlier direct build under the shared "app.clove.Clove"
    /// service to this build's own service. Only the direct build ever wrote there.
    static func migrateLegacyItem(_ account: String) {
        let legacy = "app.clove.Clove"
        guard service != legacy, read(account) == nil,
              let value = read(account, service: legacy),
              write(value, account: account)
        else { return }
        SecItemDelete(baseQuery(account, service: legacy) as CFDictionary)
    }
    #endif

    private static func read(_ account: String, service: String) -> String? {
        var query = baseQuery(account, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func baseQuery(_ account: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
