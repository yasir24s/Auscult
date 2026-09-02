import Foundation

/// Convenience façade over router + engine, shared by the CLI and the app.
public struct DiagnosticSession: Sendable {
    public let router: TransportRouter
    public let engine: ProbeEngine

    public init(
        transports: [any DeviceTransport]? = nil,
        probes: [any Probe] = ProbeEngine.standardProbes
    ) {
        self.router = TransportRouter(transports: transports)
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

    public func run(
        _ device: DeviceSnapshot,
        onProgress: (@Sendable (ProbeEngine.Progress) -> Void)? = nil
    ) async -> DiagnosticReport {
        await engine.run(device: device, router: router, onProgress: onProgress)
    }
}
