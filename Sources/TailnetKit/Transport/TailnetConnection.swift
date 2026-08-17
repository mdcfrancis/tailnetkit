import Foundation
import Observation
import TailscaleKit

#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

/// The client half: settings, secrets, and the transport that turns them into
/// a reachable `baseURL`.
///
/// Owns *how* to reach the server, not *what* to ask it. An app layers its own
/// API client on top of `baseURL` and `apiToken`, and hands over a `verify`
/// closure so a successful connection means "the server actually answered",
/// not merely "a socket opened".
@Observable @MainActor
public final class TailnetConnection {

    /// How the app reaches the server.
    public enum Mode: String, CaseIterable, Identifiable, Sendable {
        /// Plain `URLSession` — same LAN, or a simulator talking to the host
        /// Mac's loopback. No tailnet involved.
        case direct
        /// An embedded userspace Tailscale node: the app becomes its own
        /// tailnet device, with no VPN profile and no packet-tunnel
        /// extension.
        ///
        /// The raw value stays `"tailscale"` because it is persisted — never
        /// rename it without migrating existing installs.
        case tailscale

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .direct: "Direct (LAN)"
            case .tailscale: "Tailscale (embedded)"
            }
        }
    }

    public enum Status: Equatable, Sendable {
        case idle
        case starting(String)
        case connected(String)
        case failed(String)

        public var label: String {
            switch self {
            case .idle: "Not connected"
            case .starting(let detail): detail
            case .connected(let detail): detail
            case .failed(let error): error
            }
        }

        public var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    public struct Configuration: Sendable {
        /// Name this device appears under in the tailnet.
        public var hostName: String
        /// Where the embedded node's identity persists.
        public var stateDirectory: URL
        /// Keychain service id for the API token and auth key — usually the
        /// bundle identifier.
        public var keychainService: String
        /// Namespace for the UserDefaults keys. Empty keeps the bare names
        /// (`transportMode`, `serverHost`, …); changing it on a shipped app
        /// looks to the user like being logged out.
        public var defaultsPrefix: String
        /// When set, `PREFIX_MODE` / `_HOST` / `_PORT` / `_TOKEN` environment
        /// variables override the stored settings. Session-only and never
        /// persisted — this is what makes simulator automation possible,
        /// since a simulator cannot scan a QR code.
        public var environmentPrefix: String?
        public var defaultHost: String
        public var defaultPort: Int
        public var controlURL: String

        public init(
            hostName: String,
            stateDirectory: URL,
            keychainService: String,
            defaultsPrefix: String = "",
            environmentPrefix: String? = nil,
            defaultHost: String = "127.0.0.1",
            defaultPort: Int = 8080,
            controlURL: String = kDefaultControlURL
        ) {
            self.hostName = hostName
            self.stateDirectory = stateDirectory
            self.keychainService = keychainService
            self.defaultsPrefix = defaultsPrefix
            self.environmentPrefix = environmentPrefix
            self.defaultHost = defaultHost
            self.defaultPort = defaultPort
            self.controlURL = controlURL
        }

        /// Default state directory: `Application Support/tsnet`.
        public static func defaultStateDirectory() -> URL {
            FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            )[0].appending(component: "tsnet")
        }
    }

    // MARK: - Settings (UserDefaults for shape, Keychain for secrets)

    public var mode: Mode {
        didSet { defaults.set(mode.rawValue, forKey: key("transportMode")) }
    }
    public var host: String {
        didSet { defaults.set(host, forKey: key("serverHost")) }
    }
    public var port: Int {
        didSet { defaults.set(port, forKey: key("serverPort")) }
    }
    public var useHTTPS: Bool {
        didSet { defaults.set(useHTTPS, forKey: key("serverHTTPS")) }
    }
    /// Bearer token for the server's API.
    public var apiToken: String {
        didSet { keychain.set(apiToken, for: "api-token") }
    }
    /// Tailnet auth key. Empty means browser sign-in on connect.
    public var tailscaleAuthKey: String {
        didSet { keychain.set(tailscaleAuthKey, for: "ts-auth-key") }
    }

    public private(set) var status: Status = .idle
    /// Control-plane sign-in URL during browser auth, for a "open sign-in"
    /// affordance when the automatic browser hand-off was missed.
    public private(set) var loginURL: URL?

    /// Called once the transport is up, to confirm the server answers.
    /// Returns the detail string for `.connected`. Without it, a connection
    /// reports success as soon as the socket layer is ready.
    public var verify: (@MainActor (URL) async throws -> String)?

    /// Called with the control plane's sign-in URL. Defaults to opening the
    /// system browser.
    public var openLoginURL: @MainActor (URL) -> Void = { url in
        TailnetConnection.openInBrowser(url)
    }

    /// The session to issue requests on. Rebuilt whenever the transport
    /// changes.
    public private(set) var urlSession = URLSession(configuration: .default)

    private let configuration: Configuration
    private let keychain: KeychainStore
    private let defaults: UserDefaults
    private let logger: LogSink?
    private var node: TailnetNode?
    private var relay: TailnetRelay?

    public init(
        configuration: Configuration,
        defaults: UserDefaults = .standard,
        logger: LogSink? = ConsoleLogger()
    ) {
        self.configuration = configuration
        self.defaults = defaults
        self.logger = logger
        self.keychain = KeychainStore(service: configuration.keychainService)

        let prefix = configuration.defaultsPrefix
        let storedKey = { (name: String) in prefix.isEmpty ? name : prefix + name }
        let environment = ProcessInfo.processInfo.environment
        let override = { (name: String) -> String? in
            guard let envPrefix = configuration.environmentPrefix else { return nil }
            return environment["\(envPrefix)_\(name)"]
        }

        mode = override("MODE").flatMap(Mode.init(rawValue:))
            ?? Mode(rawValue: defaults.string(forKey: storedKey("transportMode")) ?? "")
            ?? .direct
        host = override("HOST")
            ?? defaults.string(forKey: storedKey("serverHost"))
            ?? configuration.defaultHost
        port = override("PORT").flatMap(Int.init)
            ?? defaults.object(forKey: storedKey("serverPort")) as? Int
            ?? configuration.defaultPort
        useHTTPS = defaults.bool(forKey: storedKey("serverHTTPS"))
        apiToken = override("TOKEN") ?? keychain.get("api-token")
        tailscaleAuthKey = keychain.get("ts-auth-key")
    }

    private func key(_ name: String) -> String {
        configuration.defaultsPrefix.isEmpty
            ? name : configuration.defaultsPrefix + name
    }

    /// Where requests should go. In tailnet mode that is the local relay, not
    /// the server's own address.
    public var baseURL: URL? {
        if mode == .tailscale, let relay {
            return URL(string: "http://127.0.0.1:\(relay.port)")
        }
        return URL(string: "\(useHTTPS ? "https" : "http")://\(host):\(port)")
    }

    /// True once a server address and token are configured — the signal an
    /// app uses to decide between its first-run pairing screen and its
    /// regular UI.
    public var isConfigured: Bool { !apiToken.isEmpty }

    // MARK: - Lifecycle

    /// (Re)establishes the transport, then runs `verify` if one is set.
    public func connect() async {
        status = .starting(
            mode == .tailscale ? "Starting Tailscale node…" : "Connecting…")
        do {
            switch mode {
            case .direct:
                urlSession = URLSession(configuration: .default)
            case .tailscale:
                try await startTailnet()
            }
            guard let baseURL else { throw TailnetError.relayUnavailable }

            if let verify {
                status = .starting("Checking server…")
                status = .connected(try await verify(baseURL))
            } else {
                status = .connected(
                    mode == .tailscale ? "Connected via tailnet" : "Connected")
            }
        } catch {
            status = .failed(shortError(error))
        }
    }

    private func startTailnet() async throws {
        let node = self.node
            ?? TailnetNode(
                options: .init(
                    hostName: configuration.hostName,
                    stateDirectory: configuration.stateDirectory,
                    authKey: tailscaleAuthKey,
                    controlURL: configuration.controlURL),
                logger: logger)
        self.node = node

        // Only bring the node up once; a reconnect just rebuilds the relay.
        if await !node.isRunning {
            status = .starting(
                tailscaleAuthKey.isEmpty ? "Waiting for sign-in…" : "Joining tailnet…")
            _ = try await node.up(
                onProgress: { [weak self] detail in
                    Task { @MainActor in self?.status = .starting(detail) }
                },
                onLoginURL: { [weak self] url in
                    Task { @MainActor in
                        guard let self else { return }
                        self.loginURL = url
                        self.status = .starting("Approve the sign-in in your browser")
                        self.openLoginURL(url)
                    }
                })
        }
        loginURL = nil

        relay?.stop()
        guard let handle = await node.handle(),
            let relay = TailnetRelay(
                handle: handle, target: "\(host):\(port)", logger: logger)
        else { throw TailnetError.relayUnavailable }
        self.relay = relay
        urlSession = URLSession(configuration: .default)
    }

    /// Drops the transport so the next `connect()` rebuilds it. Use after
    /// changing the mode, host or auth key.
    public func resetTransport() async {
        loginURL = nil
        relay?.stop()
        relay = nil
        await node?.close()
        node = nil
        urlSession = URLSession(configuration: .default)
        status = .idle
    }

    /// Applies a scanned payload and connects. The single entry point for
    /// both a first-run pairing screen and a re-scan from settings.
    ///
    /// Transport fields only — read `payload.app` yourself for anything the
    /// app put there.
    public func applyPairing<Extra>(_ payload: PairingPayload<Extra>) async {
        mode = .tailscale
        host = payload.host
        port = payload.port
        useHTTPS = false
        apiToken = payload.token
        if let authKey = payload.tailnetAuthKey, !authKey.isEmpty {
            tailscaleAuthKey = authKey
        }
        await resetTransport()
        await connect()
    }

    /// Forgets everything — server settings, secrets, and the node identity —
    /// returning the app to its first-run state.
    public func resetPairing() async {
        await resetTailnetIdentity()
        apiToken = ""
        tailscaleAuthKey = ""
        host = configuration.defaultHost
        port = configuration.defaultPort
        useHTTPS = false
        mode = .direct
    }

    /// Forgets just the embedded node's identity, so the next connect joins
    /// fresh. Use when the node landed on the wrong tailnet or auth is
    /// wedged.
    public func resetTailnetIdentity() async {
        await resetTransport()
        try? FileManager.default.removeItem(at: configuration.stateDirectory)
    }

    // MARK: - Helpers

    public static func openInBrowser(_ url: URL) {
        #if os(iOS)
            UIApplication.shared.open(url)
        #elseif os(macOS)
            NSWorkspace.shared.open(url)
        #endif
    }

    private func shortError(_ error: Error) -> String {
        if let tailnet = error as? TailnetError {
            return tailnet.errorDescription ?? "\(tailnet)"
        }
        return (error as NSError).localizedDescription
    }
}
