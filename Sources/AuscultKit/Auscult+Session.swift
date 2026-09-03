import Foundation
import AuscultProtocol

/// Convenience façade over router + engine, shared by the CLI and the app.
public struct DiagnosticSession: Sendable {
    public let router: TransportRouter
    public let engine: ProbeEngine
    /// Held concretely because the agent's surface is richer than
    /// `DeviceTransport` — it runs tests rather than serving data requests.
    public let agent: AgentTransport

    private let hostProbes: [any Probe]

    public init(
        transports: [any DeviceTransport]? = nil,
        probes: [any Probe] = ProbeEngine.standardProbes
    ) {
        let agent = AgentTransport()
        self.agent = agent
        let all = transports ?? (TransportRouter.defaultTransports + [agent])
        self.router = TransportRouter(transports: all)
        self.hostProbes = probes
        self.engine = ProbeEngine(probes: probes)
    }

    public func transportStatus() async -> [(name: String, availability: TransportAvailability)] {
        let map = await router.resolveAvailability()
        var out: [(String, TransportAvailability)] = []
        for (id, a) in map.sorted(by: { $0.key < $1.key }) {
            out.append((await router.transportName(id), a))
        }
        return out
    }

    public func devices() async -> (devices: [DeviceSnapshot], errors: [String]) {
        await router.discover()
    }

    /// Bring the agent to the foreground so its listening socket is alive.
    ///
    /// Worth doing before every run: iOS suspends a backgrounded app and the
    /// socket dies with it, so a device that worked five minutes ago may be
    /// unreachable now.
    @discardableResult
    public func prepareAgent(on device: DeviceSnapshot) async -> Bool {
        guard !device.isSimulator else { return false }
        let launched = await agent.launchAgent(on: device)
        if launched {
            // Give the app a moment to come up and bind its port.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        return launched
    }

    /// The probe set for a specific device: the fixed host probes, plus one
    /// synthesised per test the agent reports it can run.
    /// - Parameter includeInteractive: guided tests block until somebody looks
    ///   at or touches the device, so they are opt-in. A default run must never
    ///   sit waiting on a human who doesn't know they're needed.
    public func probes(
        for device: DeviceSnapshot, includeInteractive: Bool = false
    ) async -> [any Probe] {
        var probes = hostProbes
        probes.append(AgentLinkProbe(transport: agent))
        if let identity = await agent.identity(for: device) {
            // Non-interactive first: the operator shouldn't be made to stand
            // over the device before the automated results are in.
            let ordered = identity.tests.sorted {
                $0.requiresInteraction == $1.requiresInteraction
                    ? $0.id < $1.id
                    : !$0.requiresInteraction
            }
            for test in ordered where includeInteractive || !test.requiresInteraction {
                probes.append(AgentTestProbe(descriptor: test, transport: agent))
            }
        }
        return probes
    }

    public func run(
        _ device: DeviceSnapshot,
        includeAgent: Bool = true,
        includeInteractive: Bool = false,
        onProgress: (@Sendable (ProbeEngine.Progress) -> Void)? = nil
    ) async -> DiagnosticReport {
        var engine = self.engine
        if includeAgent {
            await prepareAgent(on: device)
            engine = ProbeEngine(
                probes: await probes(for: device, includeInteractive: includeInteractive)
            )
        }
        let report = await engine.run(device: device, router: router, onProgress: onProgress)
        if includeAgent { await agent.disconnect(from: device) }
        return report
    }
}
