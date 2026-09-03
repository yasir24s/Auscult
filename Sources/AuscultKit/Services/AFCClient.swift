import Foundation

/// Client for `com.apple.afc`, the Apple File Conduit.
///
/// AFC is the service that exposes the device's media filesystem, and — the
/// reason it is here — answers `GetDeviceInfo` with the volume's total and free
/// byte counts. Those figures previously came from Apple Configurator, which
/// only speaks USB; AFC runs over the ordinary lockdown session, so it works
/// wherever the relay does, including Wi-Fi.
///
/// The framing is a fixed 40-byte header followed by a payload. Unlike lockdown
/// and the diagnostics relay, which exchange plists, AFC is a binary protocol
/// with little-endian fields and NUL-separated string payloads.
final class AFCClient {
    static let serviceName = "com.apple.afc"

    /// Every AFC packet starts with this.
    private static let magic = Array("CFA6LPAA".utf8)
    private static let headerLength = 40

    /// The subset of operations this client needs.
    private enum Operation: UInt64 {
        case status = 0x00000001
        case data = 0x00000002
        case readDirectory = 0x00000003
        // Opcode order matters and is easy to get wrong: 0x0A is file info and
        // 0x0B is device info, not the other way round. Swapping them returns
        // st_* attributes for the root directory, which looks like a plausible
        // reply right up until you look for FSFreeBytes.
        case getFileInfo = 0x0000000A
        case getDeviceInfo = 0x0000000B
    }

    private let stream: ByteStream
    private var packetNumber: UInt64 = 0

    init(stream: ByteStream) { self.stream = stream }

    static func open(on client: LockdownClient) throws -> AFCClient {
        AFCClient(stream: try client.startService(serviceName))
    }

    // MARK: Requests

    /// Volume totals, as reported by the device itself.
    ///
    /// Returns the raw key/value pairs — `FSTotalBytes`, `FSFreeBytes`,
    /// `FSBlockSize`, `Model` — rather than a typed struct, so a firmware that
    /// adds or renames a key degrades one reading instead of failing to decode.
    func deviceInfo() throws -> [String: String] {
        let payload = try send(.getDeviceInfo, payload: Data())
        return Self.parseKeyValues(payload)
    }

    /// Names of the entries in a directory on the media partition.
    func readDirectory(_ path: String) throws -> [String] {
        var payload = Data(path.utf8)
        payload.append(0)
        let response = try send(.readDirectory, payload: payload)
        return Self.parseStrings(response).filter { $0 != "." && $0 != ".." }
    }

    /// Attributes of one file, as key/value pairs (`st_size`, `st_ifmt`, …).
    func fileInfo(_ path: String) throws -> [String: String] {
        var payload = Data(path.utf8)
        payload.append(0)
        return Self.parseKeyValues(try send(.getFileInfo, payload: payload))
    }

    func close() { stream.close() }

    // MARK: Framing

    private func send(_ operation: Operation, payload: Data) throws -> Data {
        packetNumber &+= 1
        let total = UInt64(Self.headerLength + payload.count)

        var packet = Data(capacity: Self.headerLength + payload.count)
        packet.append(contentsOf: Self.magic)
        packet.appendLE64(total)      // entire_length: header + payload
        packet.appendLE64(total)      // this_length: all of it in one packet
        packet.appendLE64(packetNumber)
        packet.appendLE64(operation.rawValue)
        packet.append(payload)
        try stream.write(packet)

        return try receive()
    }

    private func receive() throws -> Data {
        let header = try stream.readExactly(Self.headerLength)
        guard Array(header.prefix(8)) == Self.magic else {
            throw AFCError.badMagic
        }
        let entireLength = header.readLE64(at: 8)
        let thisLength = header.readLE64(at: 16)
        let operation = header.readLE64(at: 32)

        guard entireLength >= UInt64(Self.headerLength),
              entireLength < 64 * 1024 * 1024
        else { throw AFCError.implausibleLength(Int(entireLength)) }

        // `this_length` covers what arrives with the header; `entire_length`
        // may promise more in follow-on packets.
        var body = Data()
        let inThisPacket = Int(thisLength) - Self.headerLength
        if inThisPacket > 0 { body.append(try stream.readExactly(inThisPacket)) }

        var remaining = Int(entireLength) - Int(thisLength)
        while remaining > 0 {
            let chunk = try stream.readExactly(min(remaining, 1 << 20))
            body.append(chunk)
            remaining -= chunk.count
        }

        if operation == Operation.status.rawValue {
            let code = body.count >= 8 ? body.readLE64(at: 0) : 0
            // 0 is success; anything else is an error the device is reporting.
            guard code == 0 else { throw AFCError.deviceError(code) }
            return Data()
        }
        return body
    }

    // MARK: Payload parsing

    /// AFC returns strings as a run of NUL-terminated values.
    static func parseStrings(_ data: Data) -> [String] {
        data.split(separator: UInt8(0), omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
            .filter { !$0.isEmpty }
    }

    /// The same run, read as alternating keys and values.
    static func parseKeyValues(_ data: Data) -> [String: String] {
        let parts = parseStrings(data)
        var result: [String: String] = [:]
        var index = 0
        while index + 1 < parts.count {
            result[parts[index]] = parts[index + 1]
            index += 2
        }
        return result
    }

    enum AFCError: LocalizedError {
        case badMagic
        case implausibleLength(Int)
        case deviceError(UInt64)

        var errorDescription: String? {
            switch self {
            case .badMagic:
                "AFC reply did not start with the expected magic — the stream is desynchronised"
            case .implausibleLength(let n):
                "AFC declared a packet of \(n) bytes, which is outside the allowed range"
            case .deviceError(let code):
                "AFC returned error \(code)\(code == 8 ? " (object not found)" : "")"
            }
        }
    }
}

// MARK: - Little-endian 64-bit helpers

extension Data {
    mutating func appendLE64(_ value: UInt64) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    func readLE64(at offset: Int) -> UInt64 {
        guard count >= offset + 8 else { return 0 }
        return subdata(in: offset..<(offset + 8)).withUnsafeBytes {
            UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))
        }
    }
}
