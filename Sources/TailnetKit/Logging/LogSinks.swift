import Foundation
import TailscaleKit

/// TailscaleKit ships `DefaultLogger` and `BlackholeLogger`, but neither has
/// a public initialiser — so every embedding app ends up writing its own sink
/// before it can construct a node. These are those sinks, written once.

/// Swift-side lines to NSLog, the Go backend's stream to stdout.
public struct ConsoleLogger: LogSink {
    public let logFileHandle: Int32?
    private let subsystem: String

    public init(subsystem: String = "tsnet", toStdout: Bool = true) {
        self.subsystem = subsystem
        self.logFileHandle = toStdout ? STDOUT_FILENO : nil
    }

    public func log(_ message: String) {
        NSLog("[%@] %@", subsystem, message)
    }
}

/// Appends both the Swift-side lines and the Go backend's log stream to one
/// file. Worth wiring up on the server side: the browser sign-in flow spans
/// three subsystems (Swift wrapper, Go backend, control plane) and is close
/// to undiagnosable without a single merged log.
public final class FileLogger: LogSink, @unchecked Sendable {
    public let logFileHandle: Int32?
    private let prefix: String

    /// Opens `url` for append, creating it 0644. A sink that cannot open its
    /// file silently discards — logging must never be the thing that breaks
    /// networking.
    public init(url: URL, prefix: String = "tailnet") {
        let fd = open(url.path, O_CREAT | O_WRONLY | O_APPEND, 0o644)
        self.logFileHandle = fd >= 0 ? fd : nil
        self.prefix = prefix
    }

    public func log(_ message: String) {
        guard let fd = logFileHandle else { return }
        let line = "[\(prefix)] \(message)\n"
        _ = line.withCString { pointer in
            write(fd, pointer, strlen(pointer))
        }
    }
}

/// Discards everything. Useful when a caller wants a node with no logging at
/// all — `BlackholeLogger` cannot be constructed from outside TailscaleKit.
public struct SilentLogger: LogSink {
    public let logFileHandle: Int32? = nil
    public init() {}
    public func log(_ message: String) {}
}
