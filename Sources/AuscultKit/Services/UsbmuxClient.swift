import Foundation

/// Client for `usbmuxd`, the multiplexer every wired iOS connection goes
/// through on macOS.
///
/// The protocol is a 16-byte header followed by a binary plist. It has been
/// stable for well over a decade and is not touched by OS seeds, which is
/// precisely why it's the foundation for the deep probes: Apple changes the
/// *services* behind lockdown, not the mux that reaches them.
///
/// Notably it also hands out pair records without requiring root, which is what
/// makes an unprivileged TLS session possible.
///
/// Synchronous by design: see `BlockingIO` for why the deep stack keeps its
/// blocking calls in one place rather than sprinkling `async` through them.
struct UsbmuxClient {
    static let socketPath = "/var/run/usbmuxd"

    /// Message types in the mux header.
    private enum PayloadType: UInt32 {
        case plist = 8
    }

    /// One device as usbmuxd sees it.
    struct MuxDevice: Sendable {
        let deviceID: Int
        let serialNumber: String     // this is the UDID
        let connectionType: String   // "USB" | "Network"
        let productID: Int?

        var isUSB: Bool { connectionType.caseInsensitiveCompare("USB") == .orderedSame }
    }

    init() {}

    // MARK: Requests

    func listDevices() throws -> [MuxDevice] {
        let reply = try request(["MessageType": "ListDevices"])
        let list = DynamicValue(reply).DeviceList.array
        return list.compactMap { entry in
            let props = entry.Properties
            guard let serial = props.SerialNumber.string,
                  let id = entry.DeviceID.int ?? props.DeviceID.int
            else { return nil }
            return MuxDevice(
                deviceID: Int(id),
                serialNumber: serial,
                connectionType: props.ConnectionType.string ?? "unknown",
                productID: props.ProductID.int.map(Int.init)
            )
        }
    }

    /// The host's pairing credentials for a device: certificates, private key,
    /// HostID, and the escrow bag. Everything the TLS handshake needs.
    func readPairRecord(udid: String) throws -> PairRecord {
        let reply = try request([
            "MessageType": "ReadPairRecord",
            "PairRecordID": udid,
        ])
        let d = DynamicValue(reply)
        guard let data = d.PairRecordData.raw as? Data else {
            throw UsbmuxError.noPairRecord(udid)
        }
        let inner = DynamicValue.parsePlist(data)
        guard let record = PairRecord(inner) else {
            throw UsbmuxError.malformedPairRecord(udid)
        }
        return record
    }

    /// Open a tunnel to a TCP port on the device. On success the returned
    /// socket is no longer speaking mux protocol — it is a raw pipe to the
    /// device, ready for the lockdown handshake.
    func connect(deviceID: Int, port: UInt16) throws -> RawSocket {
        let socket = try RawSocket.connectUnix(path: Self.socketPath)
        // usbmuxd wants the port byte-swapped (network order in a host field).
        let swapped = Int(port.byteSwapped)
        let reply = try send(
            ["MessageType": "Connect", "DeviceID": deviceID, "PortNumber": swapped],
            on: socket
        )
        let d = DynamicValue(reply)
        let number = d.Number.int ?? -1
        guard number == 0 else {
            socket.close()
            throw UsbmuxError.connectRefused(port: port, code: Int(number),
                                             detail: Self.resultDescription(Int(number)))
        }
        return socket
    }

    // MARK: Framing

    /// One request on a throwaway connection. usbmuxd allows several requests
    /// per connection, but a fresh socket per query keeps state simple and
    /// costs nothing on a local unix socket.
    private func request(_ message: [String: Any]) throws -> [String: Any] {
        let socket = try RawSocket.connectUnix(path: Self.socketPath)
        defer { socket.close() }
        return try send(message, on: socket)
    }

    private func send(_ message: [String: Any], on socket: RawSocket) throws -> [String: Any] {
        var body = message
        // usbmuxd rejects plist requests without these identification keys.
        body["ClientVersionString"] = "auscult-\(Auscult.version)"
        body["ProgName"] = "Auscult"
        body["kLibUSBMuxVersion"] = 3

        let payload = try PropertyListSerialization.data(
            fromPropertyList: body, format: .xml, options: 0
        )

        var header = Data()
        header.appendLE(UInt32(16 + payload.count))  // total length
        header.appendLE(UInt32(1))                   // protocol version
        header.appendLE(PayloadType.plist.rawValue)  // message type
        header.appendLE(1)   // request tag; usbmuxd echoes it and we only ever have one in flight
        try socket.write(header + payload)

        let replyHeader = try socket.readExactly(16)
        let total = replyHeader.readLE(at: 0)
        guard total >= 16, total < 64 * 1024 * 1024 else {
            throw UsbmuxError.badFraming(length: Int(total))
        }
        let replyBody = try socket.readExactly(Int(total) - 16)
        guard let plist = try PropertyListSerialization.propertyList(
            from: replyBody, format: nil
        ) as? [String: Any] else {
            throw UsbmuxError.badReply
        }
        return plist
    }

    private static func resultDescription(_ code: Int) -> String {
        switch code {
        case 0: "success"
        case 2: "device not connected — usbmuxd knows it but has no live link"
        case 3: "port refused by the device"
        case 5: "malformed request"
        case 6: "connection refused — the device may be locked, or the service isn't running"
        default: "usbmux result code \(code)"
        }
    }
}

enum UsbmuxError: LocalizedError {
    case noPairRecord(String)
    case malformedPairRecord(String)
    case connectRefused(port: UInt16, code: Int, detail: String)
    case badFraming(length: Int)
    case badReply
    case deviceNotFound(String)

    var errorDescription: String? {
        switch self {
        case .noPairRecord(let u):
            "No pair record for \(u) — trust this Mac on the device, then retry"
        case .malformedPairRecord(let u):
            "Pair record for \(u) is missing its certificates"
        case .connectRefused(let p, _, let d):
            "usbmuxd refused a tunnel to port \(p): \(d)"
        case .badFraming(let l):
            "usbmuxd sent an implausible frame length (\(l))"
        case .badReply:
            "usbmuxd reply was not a plist dictionary"
        case .deviceNotFound(let u):
            "usbmuxd does not see \(u) — connect it over USB"
        }
    }
}

/// The host↔device trust material, as stored by usbmuxd.
struct PairRecord: Sendable {
    let hostID: String
    let systemBUID: String
    let hostCertificatePEM: Data
    let hostPrivateKeyPEM: Data
    let deviceCertificatePEM: Data
    let rootCertificatePEM: Data
    let rootPrivateKeyPEM: Data?
    let escrowBag: Data?
    let wifiMACAddress: String?

    init?(_ d: DynamicValue) {
        func pem(_ key: String) -> Data? {
            if let data = d[key].raw as? Data { return data }
            if let s = d[key].string { return Data(s.utf8) }
            return nil
        }
        guard let hostID = d.HostID.string,
              let hostCert = pem("HostCertificate"),
              let hostKey = pem("HostPrivateKey"),
              let deviceCert = pem("DeviceCertificate"),
              let rootCert = pem("RootCertificate")
        else { return nil }

        self.hostID = hostID
        self.systemBUID = d.SystemBUID.string ?? ""
        self.hostCertificatePEM = hostCert
        self.hostPrivateKeyPEM = hostKey
        self.deviceCertificatePEM = deviceCert
        self.rootCertificatePEM = rootCert
        self.rootPrivateKeyPEM = pem("RootPrivateKey")
        self.escrowBag = d.EscrowBag.raw as? Data
        self.wifiMACAddress = d.WiFiMACAddress.string
    }
}

// MARK: - Little-endian helpers

extension Data {
    mutating func appendLE(_ value: UInt32) {
        // Qualified so this resolves to the free function, not Data's own
        // withUnsafeBytes instance method.
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    func readLE(at offset: Int) -> UInt32 {
        guard count >= offset + 4 else { return 0 }
        return subdata(in: offset..<(offset + 4)).withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
        }
    }
}
