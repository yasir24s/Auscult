import Foundation
import Security

/// Client for `lockdownd`, the service broker on every iOS device.
///
/// The flow is fixed and has not changed in many years:
///   1. usbmux opens a tunnel to port 62078.
///   2. Plaintext `QueryType` confirms we're talking to lockdown.
///   3. `StartSession` with our HostID returns `EnableSessionSSL`.
///   4. The *same* socket upgrades to mutual TLS using the pair record.
///   5. `StartService` returns a port for the service we asked for.
///   6. A fresh usbmux tunnel to that port carries the service protocol.
///
/// Because none of this is version-gated, it works identically on a shipping
/// release and on a seed — the risk with new OS versions is a service being
/// renamed or withdrawn, which surfaces as a clean `StartService` error rather
/// than a broken client.
final class LockdownClient {
    static let lockdownPort: UInt16 = 62078

    private let deviceID: Int
    private let udid: String
    private let record: PairRecord
    private let identity: HostIdentity.Handle
    private var stream: ByteStream
    private var sessionID: String?

    private init(
        deviceID: Int, udid: String, record: PairRecord,
        identity: HostIdentity.Handle, stream: ByteStream
    ) {
        self.deviceID = deviceID
        self.udid = udid
        self.record = record
        self.identity = identity
        self.stream = stream
    }

    /// Connect and bring up an authenticated session.
    static func connect(deviceID: Int, udid: String, mux: UsbmuxClient) throws -> LockdownClient {
        let record = try mux.readPairRecord(udid: udid)
        let identity = try HostIdentity.make(from: record)
        let socket = try mux.connect(deviceID: deviceID, port: lockdownPort)

        let client = LockdownClient(
            deviceID: deviceID, udid: udid, record: record,
            identity: identity, stream: socket
        )
        try client.verifyLockdown()
        try client.startSession(rawSocket: socket)
        return client
    }

    // MARK: Handshake

    private func verifyLockdown() throws {
        let reply = try request(["Request": "QueryType"])
        let type = DynamicValue(reply).Type.string
        guard type == "com.apple.mobile.lockdown" else {
            throw LockdownError.notLockdown(type ?? "no Type in reply")
        }
    }

    private func startSession(rawSocket: RawSocket) throws {
        let reply = try request([
            "Request": "StartSession",
            "HostID": record.hostID,
            "SystemBUID": record.systemBUID,
        ])
        let d = DynamicValue(reply)

        if let error = d.Error.string {
            throw LockdownError.sessionRefused(error)
        }
        sessionID = d.SessionID.string

        // Devices have consistently required SSL here, but the flag is
        // authoritative — honour it rather than assuming.
        if d.EnableSessionSSL.bool == true {
            stream = try TLSSession(socket: rawSocket, identity: identity.identity)
        }
    }

    // MARK: Services

    /// Ask lockdown for a service and return a stream speaking to it.
    func startService(_ name: String) throws -> ByteStream {
        let reply = try request(["Request": "StartService", "Service": name])
        let d = DynamicValue(reply)

        if let error = d.Error.string {
            throw LockdownError.serviceUnavailable(name, reason: error)
        }
        guard let port = d.Port.int, port > 0, port <= 65535 else {
            throw LockdownError.serviceUnavailable(name, reason: "lockdown returned no port")
        }

        let mux = UsbmuxClient()
        let socket = try mux.connect(deviceID: deviceID, port: UInt16(port))
        // Some services want their own TLS layer on top; most do not.
        if d.EnableServiceSSL.bool == true {
            return try TLSSession(socket: socket, identity: identity.identity)
        }
        return socket
    }

    /// Read a lockdown domain value, e.g. `GetValue` on `com.apple.disk_usage`.
    func getValue(domain: String? = nil, key: String? = nil) throws -> DynamicValue {
        var body: [String: Any] = ["Request": "GetValue"]
        if let domain { body["Domain"] = domain }
        if let key { body["Key"] = key }
        let reply = try request(body)
        let d = DynamicValue(reply)
        if let error = d.Error.string {
            throw LockdownError.valueUnavailable(domain: domain, key: key, reason: error)
        }
        return d.Value
    }

    func close() {
        stream.close()
    }

    // MARK: Framing

    /// Lockdown framing: 4-byte big-endian length, then an XML plist.
    @discardableResult
    private func request(_ body: [String: Any]) throws -> [String: Any] {
        var message = body
        message["Label"] = "Auscult"
        message["ProtocolVersion"] = "2"

        let payload = try PropertyListSerialization.data(
            fromPropertyList: message, format: .xml, options: 0
        )
        var frame = Data()
        frame.appendBE(UInt32(payload.count))
        frame.append(payload)
        try stream.write(frame)

        let header = try stream.readExactly(4)
        let length = header.readBE(at: 0)
        guard length > 0, length < 32 * 1024 * 1024 else {
            throw LockdownError.badFraming(length: Int(length))
        }
        let responseData = try stream.readExactly(Int(length))
        guard let plist = try PropertyListSerialization.propertyList(
            from: responseData, format: nil
        ) as? [String: Any] else {
            throw LockdownError.badReply
        }
        return plist
    }
}

enum LockdownError: LocalizedError {
    case notLockdown(String)
    case sessionRefused(String)
    case serviceUnavailable(String, reason: String)
    case valueUnavailable(domain: String?, key: String?, reason: String)
    case badFraming(length: Int)
    case badReply

    var errorDescription: String? {
        switch self {
        case .notLockdown(let t):
            "port 62078 did not answer as lockdown (got '\(t)')"
        case .sessionRefused(let r):
            r == "InvalidHostID"
                ? "the device rejected this Mac's pairing — re-trust this computer on the device"
                : "lockdown refused a session: \(r)"
        case .serviceUnavailable(let s, let r):
            r.contains("Password") || r.contains("Passcode")
                ? "\(s) requires the device to be unlocked"
                : "\(s) is unavailable: \(r)"
        case .valueUnavailable(let d, let k, let r):
            "GetValue(\(d ?? "-")/\(k ?? "-")) failed: \(r)"
        case .badFraming(let l):
            "lockdown sent an implausible frame length (\(l))"
        case .badReply:
            "lockdown reply was not a plist dictionary"
        }
    }
}

// MARK: - Big-endian helpers

extension Data {
    mutating func appendBE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    func readBE(at offset: Int) -> UInt32 {
        guard count >= offset + 4 else { return 0 }
        return subdata(in: offset..<(offset + 4)).withUnsafeBytes {
            UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))
        }
    }
}
