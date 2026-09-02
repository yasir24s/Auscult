import Foundation

/// Chooses which transport answers which request, and caches the answers.
///
/// The router is the only component that knows more than one transport exists.
/// Probes ask it for data by `TransportRequest`; it finds a transport that has
/// advertised the matching capability for that specific device and calls it. If
/// that transport fails at request time — which is exactly what an OS seed
/// looks like — it demotes it and tries the next one before giving up.
public actor TransportRouter {
    public struct Provenance: Sendable {
        public var availability: [String: TransportAvailability] = [:]
        /// capability → transport identifier that claimed it
        public var servingTransport: [Capability: String] = [:]
    }

    private let transports: [any DeviceTransport]
    private var availability: [String: TransportAvailability] = [:]
    private var didProbeAvailability = false

    /// Per-device capability map, resolved lazily and cached for the run.
    private var capabilityCache: [String: [Capability: String]] = [:]
    /// Response cache, keyed by device + request, so several probes can share
    /// one expensive fetch (the details tree feeds five different probes).
    private var responseCache: [CacheKey: Result<DynamicValue, TransportErrorBox>] = [:]

    private struct CacheKey: Hashable { let device: String; let request: TransportRequest }
    /// `Error` isn't `Sendable`/`Hashable`; box the message we actually need.
    private struct TransportErrorBox: Error { let message: String }

    public init(transports: [any DeviceTransport]? = nil) {
        self.transports = (transports ?? Self.defaultTransports)
            .sorted { $0.priority < $1.priority }
    }

    public static var defaultTransports: [any DeviceTransport] {
        [CoreDeviceTransport(), LockdownTransport(), CfgutilTransport()]
    }

    // MARK: Availability

    /// Probe every transport once. Cheap, and it tells the user up front which
    /// data paths exist on this host rather than failing probe by probe.
    @discardableResult
    public func resolveAvailability() async -> [String: TransportAvailability] {
        guard !didProbeAvailability else { return availability }
        var result: [String: TransportAvailability] = [:]
        await withTaskGroup(of: (String, TransportAvailability).self) { group in
            for t in transports {
                group.addTask { (t.identifier, await t.probeAvailability()) }
            }
            for await (id, a) in group { result[id] = a }
        }
        availability = result
        didProbeAvailability = true
        return result
    }

    private var liveTransports: [any DeviceTransport] {
        transports.filter { availability[$0.identifier]?.isAvailable ?? false }
    }

    // MARK: Discovery

    /// Union of everything every live transport can see, deduplicated.
    public func discover() async -> (devices: [DeviceSnapshot], errors: [String]) {
        await resolveAvailability()

        var collected: [(Int, [DeviceSnapshot])] = []
        var errors: [String] = []

        await withTaskGroup(of: (Int, [DeviceSnapshot], String?).self) { group in
            for t in liveTransports {
                group.addTask {
                    do { return (t.priority, try await t.discover(), nil) }
                    catch { return (t.priority, [], "\(t.displayName): \(error.localizedDescription)") }
                }
            }
            for await (prio, devices, err) in group {
                collected.append((prio, devices))
                if let err { errors.append(err) }
            }
        }

        // Merge lower priority (more authoritative) last so it wins conflicts.
        var merged: [DeviceSnapshot] = []
        for (_, batch) in collected.sorted(by: { $0.0 > $1.0 }) {
            for d in batch {
                if let i = merged.firstIndex(where: { $0.isSameDevice(as: d) }) {
                    merged[i] = merged[i].merged(with: d)
                } else {
                    merged.append(d)
                }
            }
        }
        merged.sort { a, b in
            if a.isSimulator != b.isSimulator { return !a.isSimulator }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
        return (merged, errors)
    }

    // MARK: Capabilities

    /// Which capabilities exist for this device, and who provides each.
    public func capabilityMap(for device: DeviceSnapshot) async -> [Capability: String] {
        if let cached = capabilityCache[device.id] { return cached }

        var map: [Capability: String] = [:]
        // Ascending priority: the first (best) transport to claim a capability
        // keeps it.
        for t in liveTransports {
            let caps = await t.capabilities(for: device)
            for c in caps where map[c] == nil { map[c] = t.identifier }
        }
        capabilityCache[device.id] = map
        return map
    }

    public func capabilities(for device: DeviceSnapshot) async -> Set<Capability> {
        Set(await capabilityMap(for: device).keys)
    }

    public func has(_ capability: Capability, for device: DeviceSnapshot) async -> Bool {
        await capabilityMap(for: device)[capability] != nil
    }

    // MARK: Fetch

    /// Serve a request, trying every transport that could plausibly handle it.
    public func fetch(
        _ request: TransportRequest, for device: DeviceSnapshot
    ) async throws -> DynamicValue {
        let key = CacheKey(device: device.id, request: request)
        if let cached = responseCache[key] {
            switch cached {
            case .success(let v): return v
            case .failure(let e): throw TransportError.malformedResponse(e.message)
            }
        }

        try Task.checkCancellation()

        let cap = request.requiredCapability
        let map = await capabilityMap(for: device)
        guard map[cap] != nil else {
            throw TransportError.noTransport(cap)
        }

        // Preferred transport first, then any other live transport that also
        // claims the capability — a seed that breaks one path often leaves
        // another working.
        var ordered = liveTransports.filter { $0.identifier == map[cap] }
        for t in liveTransports where t.identifier != map[cap] {
            if await t.capabilities(for: device).contains(cap) { ordered.append(t) }
        }

        var lastMessage = "no transport succeeded"
        for t in ordered {
            do {
                let value = try await t.fetch(request, for: device)
                responseCache[key] = .success(value)
                return value
            } catch is CancellationError {
                // Cancellation says nothing about the device — it means *we*
                // went away. Propagate it untouched and cache nothing, or a
                // superseded run would poison every later one.
                throw CancellationError()
            } catch {
                lastMessage = "\(t.displayName): \(error.localizedDescription)"
            }
        }
        // Only genuine failures are cached, and only so that an expensive dead
        // end (cfgutil costs ~10s per call) isn't retried by every probe.
        responseCache[key] = .failure(TransportErrorBox(message: lastMessage))
        throw TransportError.malformedResponse(lastMessage)
    }

    /// Fetch bypassing the response cache.
    ///
    /// Needed by anything that samples a value repeatedly over time: the cache
    /// exists so several probes can share one expensive read, but a drain
    /// measurement that polls the gas gauge would otherwise get the same
    /// reading twenty times and conclude the current never changes.
    public func fetchFresh(
        _ request: TransportRequest, for device: DeviceSnapshot
    ) async throws -> DynamicValue {
        responseCache.removeValue(forKey: CacheKey(device: device.id, request: request))
        return try await fetch(request, for: device)
    }

    /// Fetch without throwing — probes usually want "absent" not a failure.
    public func tryFetch(
        _ request: TransportRequest, for device: DeviceSnapshot
    ) async -> DynamicValue {
        (try? await fetch(request, for: device)) ?? .missing
    }

    public func availabilitySnapshot() -> [String: TransportAvailability] { availability }

    public func transportName(_ identifier: String) -> String {
        transports.first { $0.identifier == identifier }?.displayName ?? identifier
    }

    /// Drop cached responses so a re-run measures the device again.
    public func invalidate() {
        responseCache.removeAll()
        capabilityCache.removeAll()
    }
}

// MARK: - Snapshot merging

extension DeviceSnapshot {
    /// Do two sightings refer to one physical device?
    func isSameDevice(as other: DeviceSnapshot) -> Bool {
        if let a = udid, let b = other.udid { return a == b }
        if let a = ecid, let b = other.ecid { return a == b }
        if let a = serialNumber, let b = other.serialNumber { return a == b }
        return id == other.id
    }

    /// Fill our gaps from `other`. Our own non-nil values win, because the
    /// caller feeds higher-priority transports in last.
    func merged(with other: DeviceSnapshot) -> DeviceSnapshot {
        var m = self
        func fill<T>(_ kp: WritableKeyPath<DeviceSnapshot, T?>) {
            if m[keyPath: kp] == nil { m[keyPath: kp] = other[keyPath: kp] }
        }
        fill(\.udid); fill(\.ecid); fill(\.serialNumber); fill(\.name)
        fill(\.coreDeviceIdentifier)
        fill(\.productType); fill(\.marketingName); fill(\.hardwareModel)
        fill(\.chipName); fill(\.physicalCores); fill(\.logicalCores)
        fill(\.storageCapacityBytes); fill(\.hasActionButton)
        fill(\.osName); fill(\.osVersion); fill(\.osBuild)
        fill(\.osTrainProgram); fill(\.releaseType)
        fill(\.isProductionFused); fill(\.developerModeEnabled)
        fill(\.rootFileSystemIsWritable); fill(\.hasInternalOSBuild)
        fill(\.bootState); fill(\.ddiServicesAvailable)
        fill(\.tunnelState); fill(\.lastSeen)

        if m.family == .unknown { m.family = other.family }
        if m.supportedBiometrics.isEmpty { m.supportedBiometrics = other.supportedBiometrics }
        // A wired sighting is strictly more useful than a network one, and
        // unlocks services that refuse to run over a tunnel.
        if other.link == .usb || m.link == .unknown { m.link = other.link }
        if m.pairing == .unknown { m.pairing = other.pairing }
        return m
    }
}
