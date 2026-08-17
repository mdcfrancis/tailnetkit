import Foundation
import TailscaleKit

public enum TailnetError: LocalizedError {
    case noHandle
    case notRunning
    case relayUnavailable

    public var errorDescription: String? {
        switch self {
        case .noHandle: "The embedded Tailscale node has no interface handle"
        case .notRunning: "The embedded Tailscale node is not running"
        case .relayUnavailable: "Could not start the tailnet relay"
        }
    }
}

/// An embedded userspace Tailscale node (tsnet), plus the browser sign-in
/// dance needed when no auth key is supplied.
///
/// Both ends of a paired setup need exactly this: bring a node up, authorise
/// it, and get a handle to dial or listen on. The server wraps it in
/// `TailnetServer`, the client in `TailnetConnection`.
public actor TailnetNode {

    public struct Options: Sendable {
        /// Name this device appears under in the tailnet.
        public var hostName: String
        /// Where the node identity persists. Once populated, subsequent
        /// starts join silently and the auth key is no longer consulted.
        public var stateDirectory: URL
        /// Empty means browser sign-in (SSO) instead of a key.
        public var authKey: String
        public var controlURL: String
        public var ephemeral: Bool

        public init(
            hostName: String,
            stateDirectory: URL,
            authKey: String = "",
            controlURL: String = kDefaultControlURL,
            ephemeral: Bool = false
        ) {
            self.hostName = hostName
            self.stateDirectory = stateDirectory
            self.authKey = authKey
            self.controlURL = controlURL
            self.ephemeral = ephemeral
        }
    }

    private let options: Options
    private let logger: LogSink?
    private var node: TailscaleNode?
    private var busProcessor: MessageProcessor?
    private var awaitingAuth = false

    public init(options: Options, logger: LogSink? = nil) {
        self.options = options
        self.logger = logger
    }

    public var isRunning: Bool { node != nil }

    /// The raw interface handle, for `Listener` and `OutgoingConnection`.
    public func handle() async -> TailscaleHandle? {
        guard let node else { return nil }
        return await node.tailscale
    }

    /// Brings the node up and returns its tailnet address.
    ///
    /// With an auth key this joins directly. With an empty key it runs the
    /// interactive flow: the IPN bus is watched for the control plane's
    /// sign-in URL, which is handed to `onLoginURL` for the browser. Either
    /// way the identity persists in `stateDirectory`, so this is a one-time
    /// cost per device.
    @discardableResult
    public func up(
        onProgress: @escaping @Sendable (String) -> Void = { _ in },
        onLoginURL: @escaping @Sendable (URL) -> Void = { _ in }
    ) async throws -> String {
        close()

        try? FileManager.default.createDirectory(
            at: options.stateDirectory, withIntermediateDirectories: true)

        // Force the system resolver (getaddrinfo) inside the Go runtime. The
        // pure-Go resolver gets AAAA-only answers from DNS-proxy setups like
        // Cloudflare WARP, which sends every control dial to IPv6 on networks
        // with no v6 route — the login URL can then never be fetched.
        //
        // Best-effort only: Go snapshots the environment at process load, so
        // an app that must have this should also set GODEBUG in its
        // Info.plist LSEnvironment. Harmless when it is already set.
        setenv("GODEBUG", "netdns=cgo", 1)

        let usingSSO = options.authKey.isEmpty
        let config = Configuration(
            hostName: options.hostName,
            path: options.stateDirectory.path,
            authKey: usingSSO ? nil : options.authKey,
            controlURL: options.controlURL,
            ephemeral: options.ephemeral)

        let node = try TailscaleNode(config: config, logger: logger)
        self.node = node
        logger?.log(
            "node created; authKey \(usingSSO ? "EMPTY (SSO)" : "present")")

        if usingSSO {
            await startInteractiveLogin(node: node, onLoginURL: onLoginURL)
        }

        onProgress(usingSSO ? "Waiting for sign-in…" : "Joining tailnet…")
        logger?.log("calling node.up()")
        try await node.up()
        logger?.log("node.up() returned")

        awaitingAuth = false
        busProcessor?.cancel()
        busProcessor = nil

        let addresses = try await node.addrs()
        guard let ip = addresses.ip4 ?? addresses.ip6 else {
            throw TailnetError.noHandle
        }
        return ip
    }

    public func close() {
        awaitingAuth = false
        busProcessor?.cancel()
        busProcessor = nil
        if let node {
            Task { try? await node.close() }
        }
        node = nil
    }

    /// Deletes the persisted identity so the next `up()` joins fresh. Use
    /// when the node landed on the wrong tailnet or auth is wedged.
    public func resetIdentity() {
        close()
        try? FileManager.default.removeItem(at: options.stateDirectory)
    }

    // MARK: - Browser sign-in

    private func startInteractiveLogin(
        node: TailscaleNode,
        onLoginURL: @escaping @Sendable (URL) -> Void
    ) async {
        awaitingAuth = true
        let logger = self.logger
        let api = LocalAPIClient(localNode: node, logger: logger)

        let watcher = LoginWatcher(
            logger: logger,
            onNeedsLogin: {
                logger?.log("NeedsLogin observed — starting interactive login")
                Task {
                    do { try await api.startLoginInteractive() } catch {
                        logger?.log("startLoginInteractive failed: \(error)")
                    }
                }
            },
            onURL: { url in
                logger?.log("BrowseToURL: \(url)")
                guard let parsed = URL(string: url) else { return }
                onLoginURL(parsed)
            })

        do {
            busProcessor = try await api.watchIPNBus(
                mask: [.initialState], consumer: watcher)
            logger?.log("watchIPNBus subscribed")
        } catch {
            logger?.log("watchIPNBus failed: \(error)")
        }

        // The NeedsLogin transition can race the watcher — the initial state
        // may still be NoState before up() engages. If nothing arrives, force
        // the interactive login rather than hanging on a sign-in that was
        // never offered.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, await self.awaitingAuth else { return }
            logger?.log("no NeedsLogin within 5s — forcing interactive login")
            do { try await api.startLoginInteractive() } catch {
                logger?.log("forced startLoginInteractive failed: \(error)")
            }
        }
    }
}

/// IPN-bus consumer for browser-based auth: `NeedsLogin` triggers the
/// interactive flow, `BrowseToURL` carries the control plane's sign-in URL.
actor LoginWatcher: MessageConsumer {
    private let logger: LogSink?
    private let onNeedsLogin: @Sendable () -> Void
    private let onURL: @Sendable (String) -> Void

    init(
        logger: LogSink? = nil,
        onNeedsLogin: @escaping @Sendable () -> Void,
        onURL: @escaping @Sendable (String) -> Void
    ) {
        self.logger = logger
        self.onNeedsLogin = onNeedsLogin
        self.onURL = onURL
    }

    func notify(_ notify: Ipn.Notify) {
        if let state = notify.State {
            logger?.log("ipn state: \(state)")
        }
        if notify.State == .NeedsLogin {
            onNeedsLogin()
        }
        if let url = notify.BrowseToURL {
            onURL(url)
        }
    }

    func error(_ error: Error) {
        logger?.log("ipn bus error: \(error)")
    }
}
