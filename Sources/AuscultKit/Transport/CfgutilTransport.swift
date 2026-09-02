import Foundation

/// Apple Configurator's `cfgutil`, used as a second independent probe path.
///
/// Configurator ships separately from Xcode and speaks the classic USB pairing
/// protocol, which makes it a useful cross-check and a fallback when CoreDevice
/// is mid-upgrade after an OS seed. It also surfaces values `devicectl` doesn't
/// carry at all: IMEI/ICCID, MAC addresses, per-category disk usage, and the
/// live battery charge level.
///
/// Two hard-won facts shape this implementation:
///
///  * Every invocation pays a fixed ~10s device-detection cost, and `--timeout`
///    does not shorten it. So we ask for *every* property we could ever want in
///    one call and cache it, rather than letting each probe pay the toll.
///  * `cfgutil get` exits **1** if any single requested key is unavailable, even
///    when it has printed a perfectly good answer for all the others. Exit
///    status is therefore not a usable success signal — we parse stdout and
///    judge by what came back.
public final class CfgutilTransport: DeviceTransport, @unchecked Sendable {
    public let identifier = "cfgutil"
    public let displayName = "Apple Configurator (cfgutil)"
    public let priority = 30

    /// Everything worth pulling, fetched in a single invocation.
    public static let standardProperties = [
        "activationState", "batteryCurrentCapacity", "batteryIsCharging",
        "bluetoothAddress", "wifiAddress", "ethernetAddress",
        "buildVersion", "humanReadableProductVersion", "supplementalBuildVersion",
        "firmwareVersion", "deviceClass", "deviceType", "color", "enclosureColor",
        "ECID", "UDID", "serialNumber", "name",
        "IMEI", "IMEI2", "ICCID", "ICCID2", "phoneNumber", "hasTelephonyCapability",
        "totalDiskCapacity", "freeDiskSpace", "totalSpaceAvailable",
        "appDiskUsage", "audioDiskUsage", "booksDiskUsage", "documentsDiskUsage",
        "logsDiskUsage", "otherDiskUsage", "photosDiskUsage", "videoDiskUsage",
        "isSupervised", "isPaired", "passcodeProtected", "cloudBackupsAreEnabled",
        "bootedState", "isRestorable", "language", "locale",
    ]

    private let cfgutil: String?
    private let cache = PropertyCache()

    public init(cfgutilPath: String? = nil) {
        self.cfgutil = cfgutilPath ?? Self.locateCfgutil()
    }

    static func locateCfgutil() -> String? {
        Shell.locate("cfgutil", extraDirectories: [
            "/Applications/Apple Configurator.app/Contents/MacOS",
            "/Applications/Apple Configurator 2.app/Contents/MacOS",
            "/usr/local/bin",
        ])
    }

    // MARK: Availability

    public func probeAvailability() async -> TransportAvailability {
        guard let cfgutil else { return .no("Apple Configurator is not installed") }
        do {
            let r = try await Shell.run(cfgutil, ["version"], timeout: 15)
            guard r.succeeded else { return .no("cfgutil failed: \(r.err.trimmed.firstLine)") }
            return .yes(r.out.trimmed.firstLine)
        } catch {
            return .no(error.localizedDescription)
        }
    }

    // MARK: Discovery

    public func discover() async throws -> [DeviceSnapshot] {
        guard let cfgutil else { throw TransportError.unavailable(displayName) }
        let r = try await Shell.run(cfgutil, ["--format", "JSON", "list"], timeout: 45)
        // "no devices found" is a normal empty result, not a failure.
        let json = DynamicValue.parseJSON(r.stdout)
        let map = json.Output.exists ? json.Output : json

        return map.dictionary.compactMap { ecidKey, entry in
            guard entry.UDID.exists || entry.deviceType.exists else { return nil }
            var s = DeviceSnapshot(id: entry.UDID.string ?? ecidKey)
            s.udid = entry.UDID.string
            // cfgutil speaks hex ECIDs ("0x•••••••••401C"); CoreDevice speaks
            // decimal. Keep cfgutil's own form for selection and let the router
            // match devices on UDID instead.
            s.ecid = entry.ECID.string ?? ecidKey
            s.name = entry.name.string
            s.serialNumber = entry.serialNumber.string
            s.productType = entry.deviceType.string
            s.osVersion = entry.humanReadableProductVersion.string
            s.osBuild = entry.buildVersion.string
            s.link = .usb                    // Configurator only sees wired devices
            s.pairing = entry.isPaired.bool == false ? .unpaired : .paired
            s.family = Self.family(fromDeviceClass: entry.deviceClass.string,
                                   type: entry.deviceType.string)
            return s
        }
    }

    private static func family(fromDeviceClass cls: String?, type: String?) -> DeviceFamily {
        let hay = [cls, type].compactMap { $0 }.joined(separator: " ").lowercased()
        if hay.contains("ipad") { return .iPad }
        if hay.contains("iphone") { return .iPhone }
        if hay.contains("ipod") { return .iPod }
        if hay.contains("appletv") { return .appleTV }
        if hay.contains("watch") { return .appleWatch }
        return .unknown
    }

    // MARK: Capabilities

    public func capabilities(for device: DeviceSnapshot) async -> Set<Capability> {
        // Wired, physical, and identifiable only. Simulators and network-only
        // devices are invisible to Configurator.
        guard cfgutil != nil, !device.isSimulator, device.link == .usb,
              device.ecid != nil || device.udid != nil
        else { return [] }
        return [.configuratorProperties]
    }

    // MARK: Fetch

    public func fetch(_ request: TransportRequest, for device: DeviceSnapshot) async throws -> DynamicValue {
        guard let cfgutil else { throw TransportError.unavailable(displayName) }
        guard case .configuratorProperties = request else {
            throw TransportError.unsupportedRequest(request, transport: displayName)
        }
        // The requested key list is ignored on purpose: one invocation gets
        // everything, and every probe reads from the same cached result.
        return try await cache.properties(for: device, cfgutil: cfgutil)
    }
}

/// Caches the one-shot property fetch per device.
private actor PropertyCache {
    private var cached: [String: DynamicValue] = [:]
    private var failed: [String: String] = [:]

    func properties(for device: DeviceSnapshot, cfgutil: String) async throws -> DynamicValue {
        if let hit = cached[device.id] { return hit }
        if let why = failed[device.id] { throw TransportError.malformedResponse(why) }

        // Prefer the UDID: it is unambiguous and format-stable, whereas ECID
        // notation differs between cfgutil and CoreDevice.
        var selector: [String] = []
        if let ecid = device.ecid { selector = ["--ecid", ecid] }

        let result = try? await Shell.run(
            cfgutil,
            ["--format", "JSON"] + selector + ["get"] + CfgutilTransport.standardProperties,
            timeout: 90
        )
        guard let result else {
            let why = "cfgutil did not return within 90s"
            failed[device.id] = why
            throw TransportError.malformedResponse(why)
        }

        // Deliberately not checking exit status: cfgutil returns 1 whenever any
        // one key is unavailable, while still printing the rest.
        let json = DynamicValue.parseJSON(result.stdout)
        guard json.exists else {
            let why = result.err.trimmed.firstLine.isEmpty
                ? "cfgutil produced no parseable output (exit \(result.status))"
                : result.err.trimmed.firstLine
            failed[device.id] = why
            throw TransportError.malformedResponse(why)
        }

        // Shape is { Output: { "<ecid>": {...properties...}, Errors: {...} } }.
        // Unwrap the ECID level so probes can read properties by name.
        let output = json.Output.exists ? json.Output : json
        var flattened: [String: Any] = [:]
        for (key, value) in output.dictionary {
            if key == "Errors" { continue }
            if let dict = value.raw as? [String: Any] {
                // A per-device sub-dictionary.
                for (k, v) in dict { flattened[k] = v }
            } else if let raw = value.raw {
                // Already flat (older Configurator releases).
                flattened[key] = raw
            }
        }
        guard !flattened.isEmpty else {
            let why = "cfgutil returned no readable properties"
            failed[device.id] = why
            throw TransportError.malformedResponse(why)
        }

        let value = DynamicValue(flattened)
        cached[device.id] = value
        return value
    }
}
