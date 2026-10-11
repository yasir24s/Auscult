import Foundation
import AuscultProtocol

/// The on-device agent, as a data path.
///
/// Unlike the other transports this one doesn't serve `TransportRequest`s —
/// it runs *tests*, which take time, stream progress, and sometimes need a
/// human. It still lives in the router so availability, capability resolution
/// and provenance work the same way as everything else, and so the UI can show
/// it alongside the other paths.
///
/// The agent is the source of truth for what it can test: the host asks for a
/// catalogue and synthesises one probe per entry. Adding a test to the agent
/// therefore requires no host change at all.
public final class AgentTransport: DeviceTransport, @unchecked Sendable {
    public let identifier = "agent"
    public let displayName = "On-device agent"
    public let priority = 40

    public static let bundleIdentifier = "com.yasir.auscult.agent"

    private let sessions = AgentSessionPool()
    private let xcrun: String

    public init(xcrunPath: String = "/usr/bin/xcrun") { self.xcrun = xcrunPath }

    // MARK: Availability

    public func probeAvailability() async -> TransportAvailability {
        guard FileManager.default.fileExists(atPath: UsbmuxClient.socketPath) else {
            return .no("usbmuxd is absent, so the agent cannot be reached")
        }
        return .yes("protocol v\(AgentProtocol.version)")
    }

    public func discover() async throws -> [DeviceSnapshot] { [] }

    // MARK: Capabilities

    public func capabilities(for device: DeviceSnapshot) async -> Set<Capability> {
        // Not gated to USB: the agent listens on the device's loopback
        // interface and usbmux tunnels to it over whichever transport it has,
        // so a network sighting reaches the agent just as a cable does.
        guard !device.isSimulator, device.udid != nil else { return [] }
        guard let identity = await sessions.identity(for: device) else { return [] }

        var caps: Set<Capability> = [.agentLink]
        // Advertise a capability per section the catalogue actually covers, so
        // a device whose agent is older than the host degrades one section at a
        // time instead of all at once.
        for test in identity.tests where test.isRunnable {
            switch ReportSection(rawValue: test.section) {
            case .sensors: caps.insert(.agentMotion)
            case .display: caps.insert(.agentDisplay)
            case .audio: caps.insert(.agentAudio)
            case .cameras: caps.insert(.agentCameras)
            case .thermal: caps.insert(.agentThermal)
            case .radios: caps.insert(.agentRadios)
            default: break
            }
        }
        return caps
    }

    public func fetch(_ request: TransportRequest, for device: DeviceSnapshot) async throws -> DynamicValue {
        // The agent runs tests; it does not answer data requests.
        throw TransportError.unsupportedRequest(request, transport: displayName)
    }

    // MARK: Agent-specific surface

    /// Identity and catalogue, or nil if the agent isn't reachable.
    public func identity(for device: DeviceSnapshot) async -> AgentIdentity? {
        await sessions.identity(for: device)
    }

    /// Why the agent couldn't be reached, for reporting.
    public func unavailableReason(for device: DeviceSnapshot) async -> String? {
        await sessions.lastFailure(for: device)
    }

    /// Bring the agent to the foreground. iOS suspends backgrounded apps and
    /// the listening socket dies with them, so this is a precondition, not a
    /// convenience.
    @discardableResult
    public func launchAgent(on device: DeviceSnapshot) async -> Bool {
        guard let selector = device.devicectlSelector else { return false }
        let result = try? await Shell.run(xcrun, [
            "devicectl", "device", "process", "launch",
            "--device", selector, "--activate", Self.bundleIdentifier,
        ], timeout: 60)
        return result?.succeeded ?? false
    }

    public func runTest(
        _ id: String, on device: DeviceSnapshot,
        onProgress: (@Sendable (AgentProgress) -> Void)? = nil
    ) async throws -> AgentTestResult {
        try await sessions.run(testID: id, device: device, onProgress: onProgress)
    }

    public func disconnect(from device: DeviceSnapshot) async {
        await sessions.close(device: device)
    }
}

/// One live agent connection per device, serialised.
///
/// A diagnostic run has exclusive use of the hardware, and the agent itself
/// only serves one host at a time — so an actor holding a single session is
/// both the simplest and the only correct arrangement.
private actor AgentSessionPool {
    private var clients: [String: AgentClient] = [:]
    private var identities: [String: AgentIdentity] = [:]
    private var failures: [String: String] = [:]

    func identity(for device: DeviceSnapshot) async -> AgentIdentity? {
        guard let udid = device.udid else { return nil }
        if let cached = identities[udid] { return cached }
        if failures[udid] != nil { return nil }
        do {
            let (_, identity) = try await establish(udid: udid)
            return identity
        } catch {
            failures[udid] = error.localizedDescription
            return nil
        }
    }

    func lastFailure(for device: DeviceSnapshot) -> String? {
        device.udid.flatMap { failures[$0] }
    }

    func run(
        testID: String, device: DeviceSnapshot,
        onProgress: (@Sendable (AgentProgress) -> Void)?
    ) async throws -> AgentTestResult {
        guard let udid = device.udid else {
            throw TransportError.deviceUnreachable(device.displayName)
        }
        let (client, _) = try await establish(udid: udid)
        return try await BlockingIO.run {
            try client.runTest(id: testID, onProgress: onProgress)
        }
    }

    private func establish(udid: String) async throws -> (AgentClient, AgentIdentity) {
        if let client = clients[udid], let identity = identities[udid] {
            return (client, identity)
        }
        let result = try await BlockingIO.run { () -> (AgentClient, AgentIdentity) in
            let mux = UsbmuxClient()
            let sightings = try mux.listDevices().filter { $0.serialNumber == udid }
            // Prefer the cable for latency, but a network sighting works.
            guard let device = sightings.first(where: \.isUSB) ?? sightings.first else {
                throw TransportError.deviceUnreachable("\(Redaction.identifier(udid)) is not visible to usbmuxd")
            }
            let client = try AgentClient.connect(deviceID: device.deviceID)
            do {
                return (client, try client.hello())
            } catch {
                client.close()
                throw error
            }
        }
        clients[udid] = result.0
        identities[udid] = result.1
        failures.removeValue(forKey: udid)
        return result
    }

    func close(device: DeviceSnapshot) async {
        guard let udid = device.udid, let client = clients[udid] else { return }
        clients.removeValue(forKey: udid)
        identities.removeValue(forKey: udid)
        try? await BlockingIO.run { client.goodbye() }
    }
}
