import Darwin
import Foundation

/// Byte plumbing shared by both ends of the tunnel.
///
/// The server bridges an accepted tailnet connection to its loopback HTTP
/// server; the client bridges an accepted loopback connection to a tailnet
/// dial. Both are the same operation — join two connected descriptors and
/// copy until either side hangs up — so it lives in one place.
///
/// Deliberately blocking reads on utility threads rather than async I/O:
/// these descriptors come from the Go backend via `detachFD()`, and handing
/// them to a dispatch source or NIO buys nothing when the whole job is a
/// straight copy.
public enum SocketPump {

    /// Pumps both directions until either side closes, then closes both
    /// descriptors. Returns immediately; the work happens on utility threads.
    public static func join(_ a: Int32, _ b: Int32) {
        suppressSIGPIPE(a)
        suppressSIGPIPE(b)

        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .utility)
        for (from, to) in [(a, b), (b, a)] {
            group.enter()
            queue.async {
                pump(from: from, to: to)
                // Wake the opposite pump so it observes EOF instead of
                // blocking forever on a half-closed pair.
                shutdown(a, SHUT_RDWR)
                shutdown(b, SHUT_RDWR)
                group.leave()
            }
        }
        // Close only once both directions have drained — closing earlier
        // would pull the descriptor out from under the other pump.
        group.notify(queue: queue) {
            Darwin.close(a)
            Darwin.close(b)
        }
    }

    /// Connects to 127.0.0.1 on `port`. Returns nil if the local server isn't
    /// listening.
    public static func connectLoopback(port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        suppressSIGPIPE(fd)
        var address = loopbackAddress(port: port)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    /// Binds a listening socket on 127.0.0.1 and an ephemeral port, returning
    /// the descriptor and the port the kernel chose.
    public static func listenLoopback(backlog: Int32 = 16) -> (fd: Int32, port: UInt16)? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(
            fd, SOL_SOCKET, SO_REUSEADDR, &yes,
            socklen_t(MemoryLayout<Int32>.size))
        suppressSIGPIPE(fd)

        var address = loopbackAddress(port: 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, backlog) == 0 else {
            Darwin.close(fd)
            return nil
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(fd, $0, &length)
            }
        }
        return (fd, UInt16(bigEndian: boundAddress.sin_port))
    }

    /// A dead peer must surface as a failed write, not a process-killing
    /// signal.
    public static func suppressSIGPIPE(_ fd: Int32) {
        var yes: Int32 = 1
        setsockopt(
            fd, SOL_SOCKET, SO_NOSIGPIPE, &yes,
            socklen_t(MemoryLayout<Int32>.size))
    }

    private static func loopbackAddress(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }

    private static func pump(from: Int32, to: Int32) {
        let capacity = 1 << 16
        var buffer = [UInt8](repeating: 0, count: capacity)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(from, $0.baseAddress, capacity)
            }
            guard count > 0 else { return }
            var offset = 0
            let ok = buffer.withUnsafeBytes { raw -> Bool in
                // write() is free to accept less than asked for.
                while offset < count {
                    let written = Darwin.write(
                        to, raw.baseAddress!.advanced(by: offset), count - offset)
                    guard written > 0 else { return false }
                    offset += written
                }
                return true
            }
            guard ok else { return }
        }
    }
}
