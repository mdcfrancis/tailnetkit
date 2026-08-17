import Foundation

/// A single secret in a 0600 file.
///
/// The server side prefers this to the keychain: development builds are
/// ad-hoc signed, so every rebuild is a new code identity and macOS's
/// keychain partition list re-prompts each time. A file the app owns has no
/// such behaviour, and stays readable by scripts and `cat` when something
/// needs debugging.
public struct SecretFile: Sendable {

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The stored secret, or "" when the file is absent or unreadable.
    public func read() -> String {
        (try? String(contentsOf: url, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Writes `value` 0600, or removes the file when `value` is empty.
    public func write(_ value: String) {
        if value.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? value.write(to: url, atomically: true, encoding: .utf8)
        // atomically: true replaces the file, so permissions are applied
        // after the write, not before.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
