import Foundation

/// Anything the lockdown framing can read and write over: a bare socket before
/// the session upgrade, a TLS session after it.
protocol ByteStream: AnyObject {
    func write(_ data: Data) throws
    func readExactly(_ count: Int) throws -> Data
    func close()
}

/// A blocking POSIX socket we own the file descriptor for.
///
/// `NWConnection` is the modern choice but cannot adopt an already-connected
/// descriptor, and the lockdown handshake specifically requires that: we speak
/// plaintext plist on a socket, then upgrade *that same socket* to TLS. So we
/// keep the fd ourselves and hand it to Secure Transport later.
final class RawSocket: ByteStream {
    private(set) var fd: Int32 = -1
    private let readTimeout: TimeInterval

    init(fd: Int32, readTimeout: TimeInterval = 20) {
        self.fd = fd
        self.readTimeout = readTimeout
        applyTimeouts()
    }

    deinit { close() }

    /// Connect to a unix domain socket.
    static func connectUnix(path: String, timeout: TimeInterval = 10) throws -> RawSocket {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.create(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLen else {
            Darwin.close(fd)
            throw SocketError.message("socket path too long: \(path)")
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { src in
                strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), src, maxLen - 1)
            }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let result = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let e = errno
            Darwin.close(fd)
            throw SocketError.connect(path, e)
        }
        return RawSocket(fd: fd, readTimeout: timeout)
    }

    private func applyTimeouts() {
        var tv = timeval(
            tv_sec: Int(readTimeout),
            tv_usec: Int32((readTimeout - Double(Int(readTimeout))) * 1_000_000)
        )
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    func write(_ data: Data) throws {
        guard fd >= 0 else { throw SocketError.closed }
        try data.withUnsafeBytes { buf in
            var sent = 0
            while sent < buf.count {
                let n = Darwin.write(fd, buf.baseAddress!.advanced(by: sent), buf.count - sent)
                if n > 0 { sent += n; continue }
                if n < 0 && errno == EINTR { continue }
                throw SocketError.write(errno)
            }
        }
    }

    /// Read exactly `count` bytes, or throw. Short reads are the norm on a
    /// stream socket, so loop until satisfied.
    func readExactly(_ count: Int) throws -> Data {
        guard fd >= 0 else { throw SocketError.closed }
        guard count > 0 else { return Data() }
        var out = Data(count: count)
        var got = 0
        try out.withUnsafeMutableBytes { buf in
            while got < count {
                let n = Darwin.read(fd, buf.baseAddress!.advanced(by: got), count - got)
                if n > 0 { got += n; continue }
                if n == 0 { throw SocketError.eof(after: got, expected: count) }
                if errno == EINTR { continue }
                throw SocketError.read(errno)
            }
        }
        return out
    }

    /// Change the read timeout after construction. Guided agent tests can sit
    /// for a minute waiting on a person, which is not a stalled connection.
    func setReadTimeout(_ seconds: TimeInterval) {
        guard fd >= 0 else { return }
        var tv = timeval(
            tv_sec: Int(seconds),
            tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000)
        )
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Hand the descriptor to a caller that will take over lifetime.
    func detach() -> Int32 {
        let taken = fd
        fd = -1
        return taken
    }

    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }
}

enum SocketError: LocalizedError {
    case create(Int32)
    case connect(String, Int32)
    case read(Int32)
    case write(Int32)
    case eof(after: Int, expected: Int)
    case closed
    case message(String)

    var errorDescription: String? {
        switch self {
        case .create(let e): "socket() failed: \(String(cString: strerror(e)))"
        case .connect(let p, let e): "connect(\(p)) failed: \(String(cString: strerror(e)))"
        case .read(let e): "read failed: \(String(cString: strerror(e)))"
        case .write(let e): "write failed: \(String(cString: strerror(e)))"
        case .eof(let a, let x): "connection closed after \(a) of \(x) expected bytes"
        case .closed: "socket is closed"
        case .message(let m): m
        }
    }
}
