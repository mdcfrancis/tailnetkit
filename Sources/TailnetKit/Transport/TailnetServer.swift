import Darwin
import Foundation
import TailscaleKit

/// Publishes a loopback-only HTTP server to the tailnet.
///
/// The app itself becomes a tailnet device — no system Tailscale app, no
/// `tailscale serve` — while the real server keeps its 127.0.0.1 bind.
/// Connections accepted on the embedded node are pumped byte-for-byte to
/// loopback, so every existing route, auth check and rate limit applies
/// unchanged; nothing about the HTTP server needs to know this exists.
public actor TailnetServer {

    public enum Status: Equatable, Sendable {
        case stopped
        case starting(String)
        case running(address: String, port: UInt16)
        case failed(String)

        /// Ready-made description for a status line.
        public var label: String {
            switch self {
            case .stopped: "Off"
            case .starting(let detail): detail
            case .running(let address, let port): "On tailnet as \(address):\(port)"
            case .failed(let error): error
            }
        }
    }

    private let hostName: String
    private let stateDirectory: URL
    private let controlURL: String
    private let logger: LogSink?

    private var node: TailnetNode?
    private var acceptTask: Task<Void, Never>?
    private var onStatus: (@Sendable (Status) -> Void)?

    /// - Parameters:
    ///   - stateDirectory: where the node identity persists across launches.
    ///   - logFile: when set, both the Swift wrapper and the Go backend
    ///     append here. Worth enabling — the sign-in flow is hard to debug
    ///     without one merged log.
    public init(
        hostName: String,
        stateDirectory: URL,
        logFile: URL? = nil,
        controlURL: String = kDefaultControlURL
    ) {
        self.hostName = hostName
        self.stateDirectory = stateDirectory
        self.controlURL = controlURL
        self.logger = logFile.map { FileLogger(url: $0, prefix: "server") }
    }

    private func publish(_ status: Status) {
        onStatus?(status)
    }

    /// Brings the node up and starts bridging tailnet connections on `port`
    /// to 127.0.0.1 on the same port.
    ///
    /// `authKey` is needed only until the state directory holds a valid
    /// identity; empty runs browser sign-in instead, surfacing the URL
    /// through `onLoginURL`.
    public func start(
        authKey: String,
        port: UInt16,
        onStatus: @escaping @Sendable (Status) -> Void,
        onLoginURL: @escaping @Sendable (URL) -> Void = { _ in },
        onAddress: @escaping @Sendable (String) -> Void = { _ in }
    ) async {
        stopNow()
        self.onStatus = onStatus
        publish(.starting("Starting embedded node…"))

        try? FileManager.default.createDirectory(
            at: stateDirectory, withIntermediateDirectories: true)

        let node = TailnetNode(
            options: .init(
                hostName: hostName,
                stateDirectory: stateDirectory,
                authKey: authKey,
                controlURL: controlURL),
            logger: logger)
        self.node = node

        do {
            let address = try await node.up(
                onProgress: { [weak self] detail in
                    Task { await self?.publish(.starting(detail)) }
                },
                onLoginURL: { [weak self] url in
                    Task {
                        await self?.publish(
                            .starting("Approve the sign-in in your browser"))
                    }
                    onLoginURL(url)
                })
            onAddress(address)

            guard let handle = await node.handle() else {
                throw TailnetError.noHandle
            }
            publish(.running(address: address, port: port))
            acceptTask = Task { [weak self] in
                await self?.acceptLoop(handle: handle, port: port)
            }
        } catch {
            publish(.failed((error as NSError).localizedDescription))
            self.node = nil
        }
    }

    public func stop() {
        stopNow()
        publish(.stopped)
    }

    /// Forgets the node's tailnet identity; the next `start` joins fresh.
    public func resetIdentity() async {
        stopNow()
        try? FileManager.default.removeItem(at: stateDirectory)
    }

    private func stopNow() {
        acceptTask?.cancel()
        acceptTask = nil
        Task { [node] in await node?.close() }
        node = nil
    }

    /// `Listener.accept` closes its own listener when its poll times out, so
    /// the loop recreates it and keeps serving. The timeout is set a day out
    /// to make that recreate a rarity rather than a rhythm.
    private func acceptLoop(handle: TailscaleHandle, port: UInt16) async {
        while !Task.isCancelled {
            do {
                let listener = try await Listener(
                    tailscale: handle, proto: .tcp, address: ":\(port)",
                    logger: nil)
                logger?.log("listener up on :\(port)")
                while !Task.isCancelled {
                    let connection = try await listener.accept(timeout: 86400)
                    let remote = await connection.remoteAddress ?? "?"
                    let fd = await connection.detachFD()
                    logger?.log("accepted \(remote) fd=\(fd)")
                    guard fd > 0 else { continue }
                    guard let local = SocketPump.connectLoopback(port: port) else {
                        logger?.log("local server not listening on \(port)")
                        Darwin.close(fd)
                        continue
                    }
                    SocketPump.join(fd, local)
                }
            } catch {
                if Task.isCancelled { return }
                logger?.log("accept loop recycling: \(error)")
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}
