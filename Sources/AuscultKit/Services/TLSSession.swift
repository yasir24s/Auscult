import Foundation
import Security

/// TLS over an already-connected file descriptor, via Secure Transport.
///
/// Secure Transport is deprecated in favour of Network.framework, but it is the
/// only API on macOS that can secure a socket we connected ourselves — and that
/// is exactly what lockdown requires. The handshake happens *after* a plaintext
/// plist exchange on the same descriptor, so there is no point at which we could
/// have handed the connection to `NWConnection` instead.
///
/// Peer verification is deliberately disabled: the device presents a
/// certificate signed by the pairing root that lives in our own pair record, not
/// by any public CA, so the system trust evaluation can only ever fail. Mutual
/// authentication still happens — the device validates *our* host certificate,
/// which is what actually gates access.
final class TLSSession: ByteStream {
    private let context: SSLContext
    private let socket: RawSocket
    /// Retained box the C callbacks receive as their connection reference.
    private let box: TLSConnectionBox

    init(socket: RawSocket, identity: SecIdentity?) throws {
        guard let context = SSLCreateContext(nil, .clientSide, .streamType) else {
            throw TLSError.contextCreationFailed
        }
        self.context = context
        self.socket = socket
        self.box = TLSConnectionBox(fd: socket.fd)

        try check(SSLSetIOFuncs(context, tlsRead, tlsWrite), "SSLSetIOFuncs")
        try check(
            SSLSetConnection(context, UnsafeRawPointer(Unmanaged.passUnretained(box).toOpaque())),
            "SSLSetConnection"
        )

        // Span every iOS version we might meet: old devices negotiate TLS 1.0,
        // current ones 1.2 or better. Pinning a modern floor would lock out the
        // older hardware this tool is most useful on.
        SSLSetProtocolVersionMin(context, .tlsProtocol1)
        SSLSetProtocolVersionMax(context, .tlsProtocol12)

        if let identity {
            try check(
                SSLSetCertificate(context, [identity] as CFArray),
                "SSLSetCertificate"
            )
        }

        // Stop at server auth so we can accept the pairing-root chain instead
        // of letting the system reject it.
        try check(
            SSLSetSessionOption(context, .breakOnServerAuth, true),
            "SSLSetSessionOption(breakOnServerAuth)"
        )

        try handshake()
    }

    private func handshake() throws {
        var attempts = 0
        while true {
            attempts += 1
            guard attempts < 256 else { throw TLSError.handshakeStalled }
            let status = SSLHandshake(context)
            switch status {
            case errSecSuccess:
                return
            case errSSLPeerAuthCompleted:
                // Expected: we asked to be interrupted here. Resume.
                continue
            case errSSLWouldBlock:
                continue
            default:
                throw TLSError.handshakeFailed(status)
            }
        }
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try data.withUnsafeBytes { buf in
            var written = 0
            while written < buf.count {
                var processed = 0
                let status = SSLWrite(
                    context, buf.baseAddress!.advanced(by: written),
                    buf.count - written, &processed
                )
                written += processed
                if status == errSecSuccess { continue }
                if status == errSSLWouldBlock { continue }
                throw TLSError.writeFailed(status)
            }
        }
    }

    func readExactly(_ count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var out = Data(count: count)
        var got = 0
        try out.withUnsafeMutableBytes { buf in
            while got < count {
                var processed = 0
                let status = SSLRead(
                    context, buf.baseAddress!.advanced(by: got), count - got, &processed
                )
                got += processed
                if status == errSecSuccess || status == errSSLWouldBlock {
                    // A would-block with no progress on a blocking socket means
                    // the peer went away rather than "try later".
                    if processed == 0 && status == errSSLWouldBlock && got < count {
                        throw TLSError.readFailed(status)
                    }
                    continue
                }
                if status == errSSLClosedGraceful || status == errSSLClosedAbort {
                    throw TLSError.closedByPeer(after: got, expected: count)
                }
                throw TLSError.readFailed(status)
            }
        }
        return out
    }

    func close() {
        SSLClose(context)
        socket.close()
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == errSecSuccess else { throw TLSError.setupFailed(what, status) }
    }

    enum TLSError: LocalizedError {
        case contextCreationFailed
        case setupFailed(String, OSStatus)
        case handshakeFailed(OSStatus)
        case handshakeStalled
        case readFailed(OSStatus)
        case writeFailed(OSStatus)
        case closedByPeer(after: Int, expected: Int)

        var errorDescription: String? {
            func describe(_ s: OSStatus) -> String {
                SecCopyErrorMessageString(s, nil) as String? ?? "OSStatus \(s)"
            }
            switch self {
            case .contextCreationFailed: return "could not create a TLS context"
            case .setupFailed(let w, let s): return "\(w) failed: \(describe(s))"
            case .handshakeFailed(let s):
                // The overwhelmingly common cause is a stale pair record.
                let pairingFaults: Set<OSStatus> = [
                    errSSLPeerCertUnknown, errSSLPeerBadCert, errSSLBadCert,
                    errSSLPeerCertExpired, errSSLPeerCertRevoked, errSSLPeerUnknownCA,
                    errSSLXCertChainInvalid, errSSLUnknownRootCert,
                ]
                let extra = pairingFaults.contains(s)
                    ? " — the device may have revoked this pairing; re-trust this Mac on the device"
                    : ""
                return "TLS handshake failed: \(describe(s))\(extra)"
            case .handshakeStalled: return "TLS handshake made no progress"
            case .readFailed(let s): return "TLS read failed: \(describe(s))"
            case .writeFailed(let s): return "TLS write failed: \(describe(s))"
            case .closedByPeer(let a, let x):
                return "device closed the TLS session after \(a) of \(x) expected bytes"
            }
        }
    }
}

// MARK: - Secure Transport IO callbacks

/// The connection reference Secure Transport hands back to the callbacks.
final class TLSConnectionBox {
    let fd: Int32
    init(fd: Int32) { self.fd = fd }
}

/// Read from the raw descriptor on Secure Transport's behalf.
///
/// The contract is fiddly: `dataLength` is in/out. On any non-success return we
/// must still write back how much actually transferred, or Secure Transport
/// silently drops those bytes and the stream desynchronises.
private func tlsRead(
    _ connection: SSLConnectionRef,
    _ data: UnsafeMutableRawPointer,
    _ dataLength: UnsafeMutablePointer<Int>
) -> OSStatus {
    let box = Unmanaged<TLSConnectionBox>.fromOpaque(connection).takeUnretainedValue()
    let requested = dataLength.pointee
    var got = 0

    while got < requested {
        let n = Darwin.read(box.fd, data.advanced(by: got), requested - got)
        if n > 0 { got += n; continue }
        if n == 0 {
            dataLength.pointee = got
            return errSSLClosedGraceful
        }
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK {
            dataLength.pointee = got
            return errSSLWouldBlock
        }
        dataLength.pointee = got
        return errSSLClosedAbort
    }
    dataLength.pointee = got
    return errSecSuccess
}

private func tlsWrite(
    _ connection: SSLConnectionRef,
    _ data: UnsafeRawPointer,
    _ dataLength: UnsafeMutablePointer<Int>
) -> OSStatus {
    let box = Unmanaged<TLSConnectionBox>.fromOpaque(connection).takeUnretainedValue()
    let requested = dataLength.pointee
    var sent = 0

    while sent < requested {
        let n = Darwin.write(box.fd, data.advanced(by: sent), requested - sent)
        if n > 0 { sent += n; continue }
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK {
            dataLength.pointee = sent
            return errSSLWouldBlock
        }
        dataLength.pointee = sent
        return errSSLClosedAbort
    }
    dataLength.pointee = sent
    return errSecSuccess
}
