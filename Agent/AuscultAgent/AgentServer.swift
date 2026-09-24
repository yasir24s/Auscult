import Foundation
import Network
import UIKit

/// The agent's side of the host link.
///
/// The host reaches us through usbmuxd, which tunnels a Mac-side socket to a
/// TCP port on this device's loopback interface. That means we get a wired,
/// already-trusted channel for free: no Bonjour, no Wi-Fi, no Local Network
/// permission prompt, and no pairing beyond the one the Mac already has.
///
/// Only one host connection is served at a time. A diagnostic run has exclusive
/// use of the hardware — two concurrent clients would fight over the camera and
/// the audio session and produce nonsense.
///
/// Running tests is `DiagnosticRunner`'s job, not this class's. This one only
/// moves frames and forwards what the runner reports, which is why the app
/// works with no Mac attached at all.
@MainActor
@Observable
final class AgentServer {
    /// State of the *link*. What a test is doing lives on the runner — keeping
    /// the two apart is what allows a standalone run to show progress without
    /// pretending a host is connected.
    enum State: Equatable {
        case idle
        case listening
        case connected(host: String)
        case failed(String)

        var isConnected: Bool { if case .connected = self { true } else { false } }
    }

    private(set) var state: State = .idle
    private(set) var log: [LogEntry] = []

    struct LogEntry: Identifiable {
        let id = UUID()
        let at = Date()
        let text: String
        let isError: Bool
    }

    let runner: DiagnosticRunner

    private var listener: NWListener?
    private var connection: NWConnection?
    private var inbound = Data()
    private var heartbeatTask: Task<Void, Never>?
    /// When the last frame was sent, so the heartbeat only fires during silence.
    private var lastSendAt = Date.distantPast
    private let queue = DispatchQueue(label: "com.yasir.auscult.agent.net")

    init(runner: DiagnosticRunner) {
        self.runner = runner

        // Forward everything the runner reports to the host. Nil hooks are the
        // standalone case; the runner does not care either way.
        runner.onStarted = { [weak self] descriptor in
            self?.startHeartbeat(testID: descriptor.id)
        }
        runner.onProgress = { [weak self] progress in
            self?.send(.progress(progress))
        }
        runner.onFinished = { [weak self] result in
            self?.stopHeartbeat()
            self?.send(.result(result))
        }
        runner.onCancelled = { [weak self] in
            self?.stopHeartbeat()
        }
        runner.onNote = { [weak self] text, isError in
            self?.note(text, error: isError)
        }
    }

    // MARK: Lifecycle

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // Loopback only. usbmux arrives there, and refusing other
            // interfaces means the agent is never exposed on Wi-Fi.
            params.requiredInterfaceType = .loopback

            let listener = try NWListener(
                using: params,
                on: NWEndpoint.Port(rawValue: AgentProtocol.port)!
            )
            listener.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            listener.stateUpdateHandler = { [weak self] (st: NWListener.State) in
                Task { @MainActor in
                    switch st {
                    case .ready:
                        self?.state = .listening
                        self?.note("Listening on port \(AgentProtocol.port)")
                    case .failed(let e):
                        self?.state = .failed(e.localizedDescription)
                        self?.note("Listener failed: \(e.localizedDescription)", error: true)
                    case .cancelled:
                        self?.state = .idle
                    default: break
                    }
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            state = .failed(error.localizedDescription)
            note("Could not listen: \(error.localizedDescription)", error: true)
        }
    }

    func stop() {
        runner.cancel()
        connection?.cancel()
        listener?.cancel()
        connection = nil
        listener = nil
        state = .idle
    }

    private func accept(_ conn: NWConnection) {
        // Replace any previous host: a Mac that crashed mid-run would otherwise
        // hold the agent hostage until the app is killed.
        if let existing = connection {
            note("Replacing previous host connection")
            existing.cancel()
        }
        connection = conn
        inbound.removeAll()

        conn.stateUpdateHandler = { [weak self] (st: NWConnection.State) in
            Task { @MainActor in
                switch st {
                case .ready:
                    self?.state = .connected(host: "Mac")
                    self?.note("Host connected")
                case .failed(let e):
                    self?.note("Connection failed: \(e.localizedDescription)", error: true)
                    self?.hostWentAway()
                case .cancelled:
                    self?.hostWentAway()
                default: break
                }
            }
        }
        conn.start(queue: queue)
        receive(on: conn)
    }

    private func hostWentAway() {
        runner.cancel()
        connection = nil
        if listener != nil { state = .listening }
    }

    // MARK: Receiving

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { @MainActor in
                if let data, !data.isEmpty {
                    self.inbound.append(data)
                    self.drainFrames()
                }
                if isComplete || error != nil {
                    self.hostWentAway()
                    return
                }
                self.receive(on: conn)
            }
        }
    }

    private func drainFrames() {
        while true {
            do {
                guard let payload = try AgentFraming.extractFrame(from: &inbound) else { return }
                let request = try AgentFraming.decode(AgentRequest.self, from: payload)
                handle(request)
            } catch {
                note("Malformed frame: \(error.localizedDescription)", error: true)
                // A desynchronised stream can't be recovered; drop the host.
                connection?.cancel()
                return
            }
        }
    }

    // MARK: Dispatch

    private func handle(_ request: AgentRequest) {
        switch request {
        case .hello(let hostVersion, let protocolVersion):
            guard protocolVersion == AgentProtocol.version else {
                note("Host speaks protocol v\(protocolVersion), agent speaks v\(AgentProtocol.version)", error: true)
                send(.failure(AgentFailure(
                    message: AgentWireError
                        .protocolMismatch(agent: AgentProtocol.version, host: protocolVersion)
                        .localizedDescription,
                    isFatal: true
                )))
                return
            }
            note("Host \(hostVersion) said hello")
            send(.hello(identity()))

        case .listTests:
            send(.tests(runner.catalogue))

        case .runTest(let id, _):
            guard runner.descriptor(for: id) != nil else {
                send(.failure(AgentFailure(testID: id, message: "No such test: \(id)")))
                return
            }
            runner.run(testID: id)

        case .cancelTest:
            runner.cancel()
            note("Run cancelled by host")

        case .goodbye:
            send(.bye)
            connection?.cancel()
        }
    }

    private func identity() -> AgentIdentity {
        AgentIdentity(
            agentVersion: AgentInfo.version,
            protocolVersion: AgentProtocol.version,
            deviceModel: DeviceFacts.machine,
            deviceName: UIDevice.current.name,
            osName: UIDevice.current.systemName,
            osVersion: UIDevice.current.systemVersion,
            osBuild: DeviceFacts.osBuild,
            isSimulator: DeviceFacts.isSimulator,
            tests: runner.catalogue
        )
    }

    // MARK: Sending

    /// Emit a progress frame periodically while a test is running.
    ///
    /// Some tests are legitimately silent for a long time — a camera or
    /// microphone permission prompt sits until somebody taps it, and a guided
    /// test waits on a person. Without traffic the host cannot tell a working
    /// agent from a dead one, and its socket read times out. A heartbeat during
    /// silence makes waiting distinguishable from failure.
    private func startHeartbeat(testID: String) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard Date().timeIntervalSince(self.lastSendAt) >= 4 else { continue }
                self.send(.progress(AgentProgress(
                    testID: testID, fraction: -1,
                    message: "still working", awaitingUser: false
                )))
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func send(_ response: AgentResponse) {
        guard let connection else { return }
        lastSendAt = Date()
        do {
            let frame = try AgentFraming.encode(response)
            connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                Task { @MainActor in
                    self?.note("Send failed: \(error.localizedDescription)", error: true)
                }
            })
        } catch {
            note("Could not encode response: \(error.localizedDescription)", error: true)
        }
    }

    private func note(_ text: String, error: Bool = false) {
        log.append(LogEntry(text: text, isError: error))
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}

enum AgentInfo {
    static let version = "0.4.2"
}
