import Darwin
import Foundation
import TailscaleKit

/// A localhost doorway onto the tailnet.
///
/// The app's `URLSession` talks plain HTTP to `127.0.0.1:<port>` with no proxy
/// configuration at all, and each accepted connection is pumped over a native
/// tsnet dial to `target`.
///
/// This exists because `URLSession`'s SOCKS `proxyConfigurations` silently
/// drops cleartext HTTP on iOS — requests simply never arrive. Deterministic
/// descriptor plumbing, the mirror image of `TailnetServer`, sidesteps it.
public final class TailnetRelay: @unchecked Sendable {

    /// The loopback port to point `URLSession` at.
    public let port: UInt16

    private let listenFD: Int32
    private let handle: TailscaleHandle
    private let target: String
    private let logger: LogSink?

    /// Binds 127.0.0.1 on an ephemeral port and starts accepting.
    ///
    /// - Parameter target: the tailnet `"host:port"` every connection is
    ///   relayed to.
    public init?(handle: TailscaleHandle, target: String, logger: LogSink? = nil) {
        guard let bound = SocketPump.listenLoopback() else { return nil }
        self.handle = handle
        self.target = target
        self.logger = logger
        self.listenFD = bound.fd
        self.port = bound.port

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptLoop()
        }
        logger?.log("relay listening on 127.0.0.1:\(bound.port) -> \(target)")
    }

    public func stop() {
        Darwin.close(listenFD)
    }

    private func acceptLoop() {
        while true {
            let local = accept(listenFD, nil, nil)
            guard local >= 0 else {
                logger?.log("relay accept ended")
                return
            }
            SocketPump.suppressSIGPIPE(local)
            let handle = handle
            let target = target
            let logger = logger
            Task.detached(priority: .userInitiated) {
                do {
                    let outgoing = try await OutgoingConnection(
                        tailscale: handle, to: target, proto: .tcp,
                        logger: logger ?? SilentLogger())
                    try await outgoing.connect()
                    let remote = await outgoing.detachFD()
                    guard remote > 0 else {
                        Darwin.close(local)
                        return
                    }
                    SocketPump.join(local, remote)
                } catch {
                    logger?.log("relay dial failed: \(error)")
                    Darwin.close(local)
                }
            }
        }
    }
}
