import Foundation

/// The deep transport: usbmux → lockdown → diagnostics relay.
///
/// Everything CoreDevice deliberately withholds comes from here — battery gas
/// gauge, NAND wear, raw IORegistry, MobileGestalt. It runs alongside
/// `CoreDeviceTransport` rather than replacing it: CoreDevice supplies breadth
/// and beta-immunity, this supplies depth.
///
/// Requires a wired connection and a valid pair record. It does not require
/// root, because usbmuxd hands out pair records to any local client.
public final class LockdownTransport: DeviceTransport, @unchecked Sendable {
    public let identifier = "lockdown"
    public let displayName = "Lockdown (diagnostics relay)"
    /// Runs after CoreDevice for shared capabilities, but it is the only
    /// provider of the deep ones, so ordering only affects overlap.
    public let priority = 20

    private let pool = ConnectionPool()

    public init() {}

    // MARK: Availability

    public func probeAvailability() async -> TransportAvailability {
        guard FileManager.default.fileExists(atPath: UsbmuxClient.socketPath) else {
            return .no("usbmuxd socket is absent — no Apple mobile device support on this host")
        }
        do {
            let devices = try await BlockingIO.run { try UsbmuxClient().listDevices() }
            let wired = devices.filter(\.isUSB).count
            return .yes("usbmuxd · \(devices.count) attached\(wired > 0 ? ", \(wired) wired" : "")")
        } catch {
            return .no("usbmuxd did not respond: \(error.localizedDescription)")
        }
    }

    // MARK: Discovery

    public func discover() async throws -> [DeviceSnapshot] {
        let sightings = try await BlockingIO.run { try UsbmuxClient().listDevices() }
        return sightings.map { mux in
            var s = DeviceSnapshot(id: mux.serialNumber)
            s.udid = mux.serialNumber
            s.link = mux.isUSB ? .usb : .localNetwork
            s.pairing = .unknown
            // usbmux knows identity only as a UDID; CoreDevice fills the rest
            // in when the router merges the two sightings.
            return s
        }
    }

    // MARK: Capabilities

    public func capabilities(for device: DeviceSnapshot) async -> Set<Capability> {
        guard !device.isSimulator, let udid = device.udid else { return [] }

        // Establishing a session is the only honest way to know whether the
        // relay is reachable: the device may be locked, the pairing stale, or
        // the service withdrawn. Probe once and cache the answer.
        guard let relay = await pool.relay(forUDID: udid) else { return [] }
        _ = relay

        var caps: Set<Capability> = [.ioRegistry, .mobileGestalt]
        // Advertise the specific data sets only if the device actually answers,
        // so a probe never gets a capability that yields nothing.
        if await pool.canServeBattery(udid: udid) { caps.insert(.batteryGauge) }
        if await pool.canServeNAND(udid: udid) { caps.insert(.nandStats) }
        return caps
    }

    // MARK: Fetch

    public func fetch(_ request: TransportRequest, for device: DeviceSnapshot) async throws -> DynamicValue {
        guard let udid = device.udid else {
            throw TransportError.deviceUnreachable(device.displayName)
        }
        switch request {
        case .batteryGauge:
            return try await pool.withRelay(udid: udid) { try $0.batteryGauge() }
        case .nandStatistics:
            return try await pool.withRelay(udid: udid) { try $0.nandStatistics() }
        case .wifiDiagnostics:
            return try await pool.withRelay(udid: udid) { try $0.wifiDiagnostics() }
        case .ioRegistry(let entryName, let plane):
            return try await pool.withRelay(udid: udid) {
                try $0.ioRegistry(entryName: entryName, plane: plane)
            }
        case .mobileGestalt(let keys):
            return try await pool.withRelay(udid: udid) { try $0.mobileGestalt(keys: keys) }
        default:
            throw TransportError.unsupportedRequest(request, transport: displayName)
        }
    }

    /// Release every held session. Called when a run finishes so we don't sit
    /// on the device's lockdown connections.
    public func disconnectAll() async {
        await pool.closeAll()
    }
}

/// Owns live lockdown sessions, one per device, serialised.
///
/// lockdownd tolerates concurrent sessions poorly and the relay is
/// single-request-at-a-time, so an actor here is both simpler and more reliable
/// than connection-per-request.
private actor ConnectionPool {
    /// Crosses the `BlockingIO` boundary; the pool actor guarantees only one
    /// task touches a given entry at a time.
    private struct Entry: @unchecked Sendable {
        let client: LockdownClient
        let relay: DiagnosticsRelay
    }

    private var entries: [String: Entry] = [:]
    /// Devices we've already failed to reach, so we don't retry a doomed
    /// handshake once per probe.
    private var failures: [String: Error] = [:]
    private var batteryOK: [String: Bool] = [:]
    private var nandOK: [String: Bool] = [:]

    func relay(forUDID udid: String) async -> DiagnosticsRelay? {
        try? await establish(udid: udid).relay
    }

    func withRelay<T>(
        udid: String, _ body: @escaping (DiagnosticsRelay) throws -> T
    ) async throws -> T {
        let entry = try await establish(udid: udid)
        let relay = entry.relay
        return try await BlockingIO.run { try body(relay) }
    }

    func canServeBattery(udid: String) async -> Bool {
        if let cached = batteryOK[udid] { return cached }
        let ok = (try? await withRelay(udid: udid) { relay -> Bool in
            let g = try relay.batteryGauge()
            return g.exists && !g.dictionary.isEmpty
        }) ?? false
        batteryOK[udid] = ok
        return ok
    }

    func canServeNAND(udid: String) async -> Bool {
        if let cached = nandOK[udid] { return cached }
        let ok = (try? await withRelay(udid: udid) { relay -> Bool in
            let n = try relay.nandStatistics()
            return n.exists && !n.dictionary.isEmpty
        }) ?? false
        nandOK[udid] = ok
        return ok
    }

    private func establish(udid: String) async throws -> Entry {
        if let existing = entries[udid] { return existing }
        if let failure = failures[udid] { throw failure }

        do {
            // One hop off the cooperative pool covers the whole chain: mux
            // listing, pair record, TLS handshake, and service start are all
            // blocking, and splitting them would just multiply the hops.
            let entry = try await BlockingIO.run { () -> Entry in
                let mux = UsbmuxClient()
                // A device can appear twice — once wired, once over the
                // network. Always take the wired entry: it's faster, and
                // several services refuse to start over a network link.
                let sightings = try mux.listDevices().filter { $0.serialNumber == udid }
                guard let device = sightings.first(where: \.isUSB) ?? sightings.first
                else { throw UsbmuxError.deviceNotFound(udid) }

                let client = try LockdownClient.connect(
                    deviceID: device.deviceID, udid: udid, mux: mux
                )
                let relay = try DiagnosticsRelay.open(on: client)
                return Entry(client: client, relay: relay)
            }
            entries[udid] = entry
            return entry
        } catch {
            failures[udid] = error
            throw error
        }
    }

    func closeAll() async {
        let open = Array(entries.values)
        try? await BlockingIO.run {
            for entry in open {
                entry.relay.goodbye()
                entry.client.close()
            }
        }
        entries.removeAll()
        failures.removeAll()
        batteryOK.removeAll()
        nandOK.removeAll()
    }
}
