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
        // AFC answers volume totals over the same session, so storage no longer
        // depends on a USB-only tool.
        if await pool.canServeStorage(udid: udid) { caps.insert(.fileConduit) }
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
        case .storageTotals:
            return try await pool.storageTotals(udid: udid)
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
    /// Devices we've failed to reach, with when we gave up.
    ///
    /// Caching failures avoids retrying a doomed handshake once per probe. But
    /// caching them *forever* is wrong: a phone that was briefly locked or off
    /// Wi-Fi gets written off for the rest of the session, and every probe then
    /// claims the capability needs a USB cable when it does not. Failures now
    /// expire so a device that comes back is picked up.
    private var failures: [String: (error: Error, at: Date)] = [:]
    /// How long a failure is trusted before trying again.
    private let failureTimeout: TimeInterval = 45
    private var batteryOK: [String: Bool] = [:]
    private var nandOK: [String: Bool] = [:]
    private var storageOK: [String: Bool] = [:]

    func relay(forUDID udid: String) async -> DiagnosticsRelay? {
        try? await establish(udid: udid).relay
    }

    /// A cached failure that has not yet expired.
    private func liveFailure(for udid: String) -> Error? {
        guard let record = failures[udid] else { return nil }
        guard Date().timeIntervalSince(record.at) < failureTimeout else {
            failures.removeValue(forKey: udid)
            return nil
        }
        return record.error
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

    func canServeStorage(udid: String) async -> Bool {
        if let cached = storageOK[udid] { return cached }
        let ok = ((try? await storageTotals(udid: udid))?.exists) ?? false
        storageOK[udid] = ok
        return ok
    }

    /// Volume totals via AFC.
    ///
    /// A short-lived client rather than a pooled one: AFC is only consulted
    /// once or twice per run, and holding the service open for the whole run
    /// would keep a file-conduit session on the device for no benefit.
    func storageTotals(udid: String) async throws -> DynamicValue {
        let entry = try await establish(udid: udid)
        let client = entry.client
        return try await BlockingIO.run {
            let afc = try AFCClient.open(on: client)
            defer { afc.close() }
            let info = try afc.deviceInfo()
            guard !info.isEmpty else {
                throw TransportError.malformedResponse("AFC returned no device info")
            }
            return DynamicValue(info)
        }
    }

    private func establish(udid: String) async throws -> Entry {
        if let existing = entries[udid] { return existing }
        if let failure = liveFailure(for: udid) { throw failure }

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
            failures[udid] = (error, Date())
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
        storageOK.removeAll()
    }
}
