import Foundation
import Security

/// Generic-password storage scoped to one service identifier.
///
/// The client side keeps its two secrets — the server's API token and the
/// tailnet auth key — here rather than in UserDefaults.
public struct KeychainStore: Sendable {

    public let service: String

    /// - Parameter service: usually the app's bundle identifier. Changing it
    ///   orphans previously stored items, which reads to the user as being
    ///   silently logged out.
    public init(service: String) {
        self.service = service
    }

    /// Stores `value`, or removes the item when `value` is empty.
    public func set(_ value: String, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if value.isEmpty {
            SecItemDelete(query as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(
            query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            // Readable after the first unlock so a relaunch in the background
            // can reconnect, and never synced off this device.
            add[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// The stored value, or "" when absent — callers treat empty as
    /// unconfigured throughout.
    public func get(_ account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard
            SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
