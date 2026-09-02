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
@MainActor
@Observable
final class AgentServer {
    enum State: Equatable {
        case idle
        case listening
        case connected(host: String)
        case running(test: String, fraction: Double, message: String)
        case failed(String)

        var isConnected: Bool {
            switch self { case .connected, .running: true; default: false }
        }
    }

    private(set) var state: State = .idle
    private(set) var log: [LogEntry] = []
    private(set) var lastResults: [AgentTestResult] = []
    /// Set when a test needs the person holding the device to do something.
    private(set) var userPrompt: UserPrompt?

    struct LogEntry: Identifiable {
        let id = UUID()
        let at = Date()
        let text: String
        let isError: Bool
    }

    struct UserPrompt: Equatable {
        var message: String
        var confirmTitle: String
        var rejectTitle: String?
    }

    private var listener: NWListener?
    private var connection: NWConnection?
    private var inbound = Data()
    private var runTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    /// When the last frame was sent, so the heartbeat only fires during silence.
    private var lastSendAt = Date.distantPast
    private let queue = DispatchQueue(label: "com.yasir.auscult.agent.net")
    private let registry = TestRegistry()

    /// How the person answered — or that they never did.
    ///
    /// A distinct `timedOut` case matters: treating "nobody was holding the
    /// device" as "the user saw a defect" would report a broken display on
    /// perfectly good hardware, which is the worst kind of wrong answer a
    /// diagnostic can give.
    enum PromptAnswer {
        case confirmed, rejected, timedOut
    }

    /// Continuation the interactive tests wait on for the user's answer.
    private var promptContinuation: CheckedContinuation<PromptAnswer, Never>?

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

            // Deliberately NOT disabling the idle timer here. Holding the
            // screen awake for the whole session costs a couple of watts on a
            // large OLED, which would corrupt the very drain measurements this
            // tool exists to take. It is enabled only while a test is running.
        } catch {
            state = .failed(error.localizedDescription)
            note("Could not listen: \(error.localizedDescription)", error: true)
        }
    }

    func stop() {
        runTask?.cancel()
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
        runTask?.cancel()
        connection = nil
        userPrompt = nil
        promptContinuation?.resume(returning: .timedOut)
        promptContinuation = nil
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
            send(.tests(registry.catalogue()))

        case .runTest(let id, let parameters):
            run(testID: id, parameters: parameters)

        case .cancelTest:
            runTask?.cancel()
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
            tests: registry.catalogue()
        )
    }

    private func run(testID: String, parameters: [String: String]) {
        guard let test = registry.test(withID: testID) else {
            send(.failure(AgentFailure(testID: testID, message: "No such test: \(testID)")))
            return
        }
        runTask?.cancel()

        // Detached, NOT @MainActor. The compute and thermal tests saturate every
        // core for seconds at a time; running that on the main actor blocks the
        // run loop and iOS's watchdog kills the app outright — which the host
        // sees as the connection dropping mid-test. UI and socket work hops back
        // to the main actor explicitly.
        let descriptor = test.descriptor
        runTask = Task.detached(priority: .userInitiated) { [weak self] in
            let started = Date()
            await MainActor.run { [weak self] in
                self?.state = .running(test: descriptor.title, fraction: 0, message: "Starting")
                self?.note("Running \(descriptor.title)")
                // Keep the screen alive for the duration of this test only.
                UIApplication.shared.isIdleTimerDisabled = true
                self?.startHeartbeat(testID: testID)
            }

            var result: AgentTestResult
            do {
                result = try await test.run(context: AgentTestContext(
                    progress: { fraction, message in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.state = .running(
                                test: descriptor.title, fraction: fraction, message: message
                            )
                            self.send(.progress(AgentProgress(
                                testID: testID, fraction: fraction, message: message
                            )))
                        }
                    },
                    askUser: { prompt in
                        await self?.askUser(prompt, testID: testID) ?? .timedOut
                    },
                    awaitingUser: { message in
                        Task { @MainActor [weak self] in
                            self?.send(.progress(AgentProgress(
                                testID: testID, fraction: 0.5,
                                message: message, awaitingUser: true
                            )))
                        }
                    }
                ))
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    self?.stopHeartbeat()
                    UIApplication.shared.isIdleTimerDisabled = false
                    self?.state = .connected(host: "Mac")
                }
                return
            } catch {
                result = AgentTestResult(
                    testID: testID, title: descriptor.title,
                    section: descriptor.section, verdict: .error,
                    summary: "Test failed unexpectedly",
                    detail: error.localizedDescription
                )
            }
            result.duration = Date().timeIntervalSince(started)

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.stopHeartbeat()
                UIApplication.shared.isIdleTimerDisabled = false
                self.lastResults.removeAll { $0.testID == result.testID }
                self.lastResults.append(result)
                self.userPrompt = nil
                self.state = .connected(host: "Mac")
                self.send(.result(result))
            }
        }
    }

    // MARK: Interactive prompts

    func askUser(
        _ prompt: UserPrompt, testID: String, timeout: TimeInterval = 45
    ) async -> PromptAnswer {
        send(.progress(AgentProgress(
            testID: testID, fraction: 0.5,
            message: prompt.message, awaitingUser: true
        )))
        userPrompt = prompt

        let answer = await withCheckedContinuation { (c: CheckedContinuation<PromptAnswer, Never>) in
            promptContinuation = c
            // Give up on our own schedule rather than blocking the host forever
            // on someone who has put the phone down.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.resolvePrompt(.timedOut)
            }
        }
        userPrompt = nil
        return answer
    }

    /// Called from the UI when the person answers an on-device prompt.
    func answerPrompt(_ confirmed: Bool) {
        resolvePrompt(confirmed ? .confirmed : .rejected)
    }

    private func resolvePrompt(_ answer: PromptAnswer) {
        guard let continuation = promptContinuation else { return }
        promptContinuation = nil
        userPrompt = nil
        continuation.resume(returning: answer)
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
    static let version = "0.1.0"
}
