import Foundation
import Security

/// The server's static bearer token: minted on first use, then stable.
///
/// The canonical copy is a 0600 file the app reads without keychain prompts —
/// see `SecretFile` for why that matters for ad-hoc-signed builds. It is
/// mirrored into the login keychain purely for the user's benefit: visible in
/// Keychain Access, and readable by scripts via
///
///     security find-generic-password -s <service> -a <account> -w
///
/// The mirror is a convenience, never the source of truth. It is consulted
/// only when the file has gone missing.
public struct BearerToken: Sendable {

    public let service: String
    public let account: String
    /// Human-readable name shown in Keychain Access.
    public let label: String
    public let fileURL: URL

    public init(service: String, account: String = "api-token", label: String, fileURL: URL) {
        self.service = service
        self.account = account
        self.label = label
        self.fileURL = fileURL
    }

    /// Returns the existing token, recovering it from the keychain mirror if
    /// the file was lost, and minting a new one only when neither exists.
    public func load() -> String {
        let file = SecretFile(url: fileURL)

        let existing = file.read()
        if !existing.isEmpty { return existing }

        // File lost but a mirror survives — restore rather than mint, so
        // already-paired clients keep working. May prompt once.
        if let mirrored = readKeychain(), !mirrored.isEmpty {
            file.write(mirrored)
            return mirrored
        }

        let token = Self.mint()
        file.write(token)
        storeKeychain(token)
        return token
    }

    /// 32 bytes of CSPRNG output, hex-encoded.
    public static func mint() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Keychain mirror

    private func readKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard
            SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data,
            let token = String(data: data, encoding: .utf8),
            !token.isEmpty
        else { return nil }
        return token
    }

    private func storeKeychain(_ token: String) {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: label,
            kSecValueData as String: Data(token.utf8),
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Replace wholesale: SecItemUpdate cannot change the label.
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(query as CFDictionary)
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }
}
