import Foundation
import AuscultProtocol

/// The host's side of the on-device agent link.
///
/// Reaches the agent through the same usbmux tunnel the lockdown stack uses,
/// but aimed at a TCP port the agent opened on the device's loopback interface
/// rather than at `lockdownd`. That means the agent needs no special service
/// registration, no network, and no pairing beyond the one we already have —
/// and it works identically on any iOS version, because usbmux port forwarding
/// is not something OS seeds change.
///
/// Synchronous, like the rest of the deep stack; callers wrap it in
/// `BlockingIO` so a blocking read never parks a cooperative thread.
final class AgentClient {
    private let socket: RawSocket
    private var inbound = Data()

    private init(socket: RawSocket) { self.socket = socket }

    /// Open a tunnel to the agent.
    ///
    /// The generous read timeout is deliberate: a guided test can legitimately
    /// sit for a minute while somebody traces the screen, and treating that as
    /// a dead connection would make the interactive tests unusable.
    static func connect(deviceID: Int, readTimeout: TimeInterval = 180) throws -> AgentClient {
        let mux = UsbmuxClient()
        let socket = try mux.connect(deviceID: deviceID, port: AgentProtocol.port)
        socket.setReadTimeout(readTimeout)
        return AgentClient(socket: socket)
    }

    // MARK: Conversation

    /// Handshake. Also yields the test catalogue, so one round trip tells us
    /// both who we're talking to and what it can do.
    func hello() throws -> AgentIdentity {
        try send(.hello(hostVersion: Auscult.version, protocolVersion: AgentProtocol.version))
        switch try receive() {
        case .hello(let identity):
            guard identity.protocolVersion == AgentProtocol.version else {
                throw AgentClientError.protocolMismatch(
                    agent: identity.protocolVersion, host: AgentProtocol.version
                )
            }
            return identity
        case .failure(let f):
            throw AgentClientError.agentRefused(f.message)
        default:
            throw AgentClientError.unexpectedResponse("expected hello")
        }
    }

    func listTests() throws -> [AgentTestDescriptor] {
        try send(.listTests)
        guard case .tests(let tests) = try receive() else {
            throw AgentClientError.unexpectedResponse("expected the test catalogue")
        }
        return tests
    }

    /// Run one test, forwarding progress until a result arrives.
    ///
    /// The agent may emit any number of progress frames before the result, and
    /// interactive tests emit one flagged `awaitingUser` — surfaced through the
    /// same callback so the host UI can tell the operator to go look at the
    /// device rather than appearing to hang.
    func runTest(
        id: String,
        parameters: [String: String] = [:],
        onProgress: ((AgentProgress) -> Void)? = nil
    ) throws -> AgentTestResult {
        try send(.runTest(id: id, parameters: parameters))
        while true {
            switch try receive() {
            case .progress(let p):
                onProgress?(p)
            case .result(let r):
                return r
            case .failure(let f):
                throw AgentClientError.testFailed(id: f.testID ?? id, message: f.message)
            case .bye:
                throw AgentClientError.disconnected
            default:
                continue   // catalogue or hello arriving late is harmless
            }
        }
    }

    func goodbye() {
        try? send(.goodbye)
        socket.close()
    }

    func close() { socket.close() }

    // MARK: Framing

    private func send(_ request: AgentRequest) throws {
        try socket.write(try AgentFraming.encode(request))
    }

    private func receive() throws -> AgentResponse {
        // Drain anything already buffered from a previous oversized read first.
        if let framed = try AgentFraming.extractFrame(from: &inbound) {
            return try AgentFraming.decode(AgentResponse.self, from: framed)
        }
        let header = try socket.readExactly(4)
        guard let length = AgentFraming.frameLength(from: header) else {
            throw AgentClientError.badFraming
        }
        guard length > 0, length <= AgentProtocol.maxFrameBytes else {
            throw AgentClientError.badFraming
        }
        let payload = try socket.readExactly(length)
        return try AgentFraming.decode(AgentResponse.self, from: payload)
    }
}

enum AgentClientError: LocalizedError {
    case protocolMismatch(agent: Int, host: Int)
    case agentRefused(String)
    case unexpectedResponse(String)
    case testFailed(id: String, message: String)
    case disconnected
    case badFraming
    case notRunning

    var errorDescription: String? {
        switch self {
        case .protocolMismatch(let a, let h):
            "The agent speaks protocol v\(a) but this host speaks v\(h) — rebuild and reinstall the agent"
        case .agentRefused(let m): "The agent refused the connection: \(m)"
        case .unexpectedResponse(let what): "Agent sent an unexpected message (\(what))"
        case .testFailed(let id, let m): "Agent test '\(id)' failed: \(m)"
        case .disconnected: "The agent closed the connection"
        case .badFraming: "The agent sent a malformed frame"
        case .notRunning:
            "The Auscult Agent app is not running in the foreground on the device — "
            + "open it and keep it on screen"
        }
    }
}
