import Foundation

// This module is compiled into BOTH the macOS host and the iOS agent.
//
// It is deliberately pure Foundation — no Security, no Process, no UIKit — so
// the same source builds for both platforms. It is included by the Xcode agent
// project as plain sources rather than as a Swift package product, which keeps
// the iOS build free of any SwiftPM-in-Xcode entanglement.

/// Protocol version. The agent refuses a host whose major version differs,
/// because a sideloaded agent can easily be older than the Mac app driving it.
public enum AgentProtocol {
    public static let version = 1
    /// Port the agent listens on. In the dynamic/private range to avoid
    /// colliding with anything iOS itself uses.
    public static let port: UInt16 = 7431
    /// Guard against a desynchronised stream claiming an absurd payload.
    public static let maxFrameBytes = 32 * 1024 * 1024
}

/// Length-prefixed JSON framing: 4-byte big-endian length, then the payload.
///
/// Same shape as the lockdown and diagnostics-relay framing the host already
/// speaks, so the reading code reads familiarly — but JSON rather than plist,
/// since both ends are ours and `Codable` makes it free.
public enum AgentFraming {
    public static func encode<T: Encodable>(_ message: T) throws -> Data {
        let encoder = JSONEncoder()
        let payload = try encoder.encode(message)
        var frame = Data(capacity: payload.count + 4)
        let length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    public static func decode<T: Decodable>(_ type: T.Type, from payload: Data) throws -> T {
        try JSONDecoder().decode(type, from: payload)
    }

    /// Read the length prefix. Returns nil when fewer than 4 bytes are buffered.
    public static func frameLength(from buffer: Data) -> Int? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.prefix(4).withUnsafeBytes {
            UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))
        }
        return Int(length)
    }

    /// Pull one complete frame off the front of `buffer`, if there is one.
    /// Mutates `buffer` to drop what it consumed.
    public static func extractFrame(from buffer: inout Data) throws -> Data? {
        guard let length = frameLength(from: buffer) else { return nil }
        guard length >= 0, length <= AgentProtocol.maxFrameBytes else {
            throw AgentWireError.implausibleFrame(length)
        }
        guard buffer.count >= 4 + length else { return nil }
        let payload = buffer.dropFirst(4).prefix(length)
        buffer = buffer.dropFirst(4 + length)
        return Data(payload)
    }
}

public enum AgentWireError: LocalizedError {
    case implausibleFrame(Int)
    case protocolMismatch(agent: Int, host: Int)

    public var errorDescription: String? {
        switch self {
        case .implausibleFrame(let n):
            "frame claims \(n) bytes, which is outside the allowed range"
        case .protocolMismatch(let a, let h):
            "agent speaks protocol v\(a) but the host speaks v\(h) — rebuild and reinstall the agent"
        }
    }
}
