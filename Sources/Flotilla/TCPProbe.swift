import Darwin
import Foundation

/// Whether a TCP port accepts a connection — the readiness check for a group member
/// (`Readiness`). A plain connect and close: nothing is sent, so no service sees a request.
///
/// POSIX rather than Network.framework because this is one blocking question with a short
/// deadline, asked from a detached task; `NWConnection` would need a queue, a state handler and a
/// continuation to say the same thing. A refused port answers at once (measured 6 October), so the
/// deadline only matters for an address that drops packets.
enum TCPProbe {
    static func accepts(host: String, port: Int, timeout: TimeInterval = 1) -> Bool {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(clamping: port)).bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return false }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pending = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pending, 1, Int32(timeout * 1000)) == 1 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return false }
        return error == 0
    }
}
