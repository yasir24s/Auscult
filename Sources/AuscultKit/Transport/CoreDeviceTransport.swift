import Foundation

/// Apple's own CoreDevice stack, driven through `xcrun devicectl`.
///
/// This is the primary transport and the reason Auscult keeps working on iOS
/// seeds: `devicectl` ships inside Xcode and Apple updates it in lockstep with
/// every new OS build, including internal trains. Whatever handshake, tunnel, or
/// pairing scheme a beta introduces, this binary already speaks it.
///
/// The trade-off is surface area — CoreDevice deliberately exposes no battery
/// gas gauge or NAND wear. Those come from `LockdownTransport`; here we take the
/// breadth and the immunity.
public struct CoreDeviceTransport: DeviceTransport {
    public let identifier = "coredevice"
    public let displayName = "CoreDevice (devicectl)"
    public let priority = 10

    private let xcrun: String

    public init(xcrunPath: String = "/usr/bin/xcrun") { self.xcrun = xcrunPath }

    // MARK: Availability

    public func probeAvailability() async -> TransportAvailability {
        guard FileManager.default.isExecutableFile(atPath: xcrun) else {
            return .no("xcrun not found — install Xcode or the Command Line Tools")
        }
        do {
            let r = try await Shell.run(xcrun, ["devicectl", "--version"], timeout: 20)
            guard r.succeeded else {
                return .no("devicectl unavailable: \(r.err.trimmed.firstLine)")
            }
            return .yes(r.out.trimmed)
        } catch {
            return .no(error.localizedDescription)
        }
    }

    // MARK: Discovery

    public func discover() async throws -> [DeviceSnapshot] {
        let json = try await runJSON(["devicectl", "list", "devices"], timeout: 45)
        return json.result.devices.array.compactMap(Self.snapshot(from:))
    }

    /// Translate one CoreDevice entry into our model.
    ///
    /// Every field is read through `firstPresent`, newest schema first. Apple
    /// already deprecated the flat `*Properties` dictionaries in favour of
    /// `properties`; reading both means neither the removal of the old nor a
    /// further reshuffle of the new costs us the device.
    static func snapshot(from d: DynamicValue) -> DeviceSnapshot? {
        let udid = d.firstPresent(
            "properties.hardware.udid",
            "hardwareProperties.udid"
        ).string
        let ecid = d.firstPresent(
            "properties.hardware.ecid",
            "hardwareProperties.ecid"
        ).int.map(String.init)
        let coreID = d.identifier.string

        guard let key = udid ?? ecid ?? coreID else { return nil }
        var s = DeviceSnapshot(id: key)
        s.udid = udid
        s.ecid = ecid
        s.coreDeviceIdentifier = coreID

        // --- Hardware ---
        let hw = ["properties.hardware", "hardwareProperties"]
        s.serialNumber   = d.firstPresent(hw.map { "\($0).serialNumber" }).string
        s.productType    = d.firstPresent(hw.map { "\($0).productType" }).string
        s.marketingName  = d.firstPresent(hw.map { "\($0).marketingName" }).string
        s.hardwareModel  = d.firstPresent(hw.map { "\($0).hardwareModel" }).string
        s.chipName       = d.firstPresent(
            hw.map { "\($0).cpuType.name" } + hw.map { "\($0).cpuType.type" }
        ).string
        s.physicalCores  = d.firstPresent(hw.map { "\($0).cpuCount.physicalCores" }).int.map(Int.init)
        s.logicalCores   = d.firstPresent(hw.map { "\($0).cpuCount.logicalCores" }).int.map(Int.init)
        s.storageCapacityBytes = d.firstPresent(hw.map { "\($0).internalStorageCapacity" }).int
        s.supportedBiometrics  = d.firstPresent(hw.map { "\($0).supportedBiometrics" }).stringList
        s.hasActionButton      = d.firstPresent(hw.map { "\($0).hasActionButton" }).bool
        s.isProductionFused    = d.firstPresent(hw.map { "\($0).isProductionFused" }).bool

        let platform = d.firstPresent(hw.map { "\($0).platform" }).string
        s.osName = platform
        s.family = Self.family(
            deviceType: d.firstPresent(hw.map { "\($0).deviceType" }).string,
            platform: platform,
            productType: s.productType
        )

        // --- Software ---
        s.osVersion = d.firstPresent(
            "properties.software.osVersionNumber.stringValue",
            "deviceProperties.osVersionNumber"
        ).string
        s.osBuild = d.firstPresent(
            "properties.software.osBuildVersions.buildVersion.name",
            "deviceProperties.osBuildUpdate"
        ).string
        s.osTrainProgram = d.firstPresent(
            "properties.software.osBuildVersions.buildVersion.trainProgram"
        ).string
        s.releaseType = d.firstPresent(
            "properties.software.releaseType",
            "deviceProperties.releaseType"
        ).string

        // --- Security posture ---
        s.developerModeEnabled = d.firstPresent(
            "properties.state.developerModeStatus.enabled.mode",
            "deviceProperties.developerModeStatus"
        ).exists
            ? Self.developerModeIsOn(d)
            : nil
        s.rootFileSystemIsWritable = d.firstPresent(
            "deviceProperties.rootFileSystemIsWritable",
            "properties.state.rootFileSystemIsWritable"
        ).bool
        s.hasInternalOSBuild = d.firstPresent(
            "deviceProperties.hasInternalOSBuild",
            "properties.software.hasInternalOSBuild"
        ).bool
        s.bootState = d.firstPresent(
            "properties.state.bootState",
            "deviceProperties.bootState"
        ).string
        s.ddiServicesAvailable = d.firstPresent(
            "deviceProperties.ddiServicesAvailable",
            "properties.state.ddiServicesAvailable"
        ).bool

        // --- Name & link ---
        s.name = d.firstPresent(
            "properties.state.name",
            "deviceProperties.name"
        ).string

        let transport = d.firstPresent(
            "properties.connection.transportType",
            "connectionProperties.transportType"
        ).string?.lowercased()
        s.link = switch transport {
        case "wired", "usb": .usb
        case "localnetwork": .localNetwork
        case "samemachine": .sameMachine
        default: .unknown
        }
        s.isSimulator = s.link == .sameMachine || (ecid == nil && udid?.contains("-") == true && udid?.count == 36)

        s.pairing = switch d.firstPresent(
            "properties.connection.pairingState",
            "connectionProperties.pairingState"
        ).string?.lowercased() {
        case "paired": .paired
        case "unpaired", "notpaired": .unpaired
        case "pairingrequested": .pairingRequested
        default: .unknown
        }
        s.tunnelState = d.firstPresent(
            "properties.connection.state",
            "connectionProperties.tunnelState"
        ).string

        if let iso = d.firstPresent(
            "properties.connection.lastConnectionDate",
            "connectionProperties.lastConnectionDate"
        ).string {
            s.lastSeen = FlexibleDate.parse(iso)
        }

        return s
    }

    private static func developerModeIsOn(_ d: DynamicValue) -> Bool {
        let v = d.firstPresent(
            "properties.state.developerModeStatus.enabled.mode",
            "deviceProperties.developerModeStatus"
        )
        if let b = v.bool { return b }
        guard let s = v.string?.lowercased() else { return false }
        return s.contains("enabled") || s.contains("on") || s == "development"
    }

    private static func family(deviceType: String?, platform: String?, productType: String?) -> DeviceFamily {
        let hay = [deviceType, platform, productType].compactMap { $0 }.joined(separator: " ").lowercased()
        if hay.contains("ipad") { return .iPad }
        if hay.contains("iphone") { return .iPhone }
        if hay.contains("ipod") { return .iPod }
        if hay.contains("appletv") || hay.contains("tvos") { return .appleTV }
        if hay.contains("watch") { return .appleWatch }
        if hay.contains("realitydevice") || hay.contains("xros") || hay.contains("visionos") { return .appleVision }
        if hay.contains("mac") { return .mac }
        return .unknown
    }

    // MARK: Capabilities

    public func capabilities(for device: DeviceSnapshot) async -> Set<Capability> {
        // Identity always works — we already have it from discovery.
        var caps: Set<Capability> = [.deviceIdentity]

        // Everything else needs a live connection to the device.
        guard device.isReachable else { return caps }

        caps.formUnion([.displayInfo, .screenCapture, .sysdiagnose, .crashLogs])

        // The developer-disk-image services gate process listing and app
        // inventory. Ask rather than assume: on a fresh seed the DDI may still
        // be mounting, and on a device without Developer Mode it never will.
        if device.ddiServicesAvailable == true {
            caps.formUnion([.processList, .appInventory, .ddiServices])
        } else if device.developerModeEnabled == true || device.link == .usb {
            // Over a cable with Developer Mode on these generally work even
            // when CoreDevice hasn't yet reported the DDI as mounted. If they
            // don't, devicectl fails cleanly and the probe says so.
            caps.formUnion([.appInventory, .processList, .ddiServices])
        }
        return caps
    }

    // MARK: Fetch

    public func fetch(_ request: TransportRequest, for device: DeviceSnapshot) async throws -> DynamicValue {
        guard let selector = device.devicectlSelector else {
            throw TransportError.deviceUnreachable(device.displayName)
        }
        // Fail fast rather than letting every probe pay devicectl's ~10s
        // connect timeout against a device we already know is offline.
        guard device.isReachable else {
            throw TransportError.deviceUnreachable(device.displayName)
        }
        switch request {
        case .deviceDetails:
            return try await runJSON(
                ["devicectl", "device", "info", "details", "--device", selector], timeout: 45
            ).result
        case .displays:
            return try await runJSON(
                ["devicectl", "device", "info", "displays", "--device", selector], timeout: 45
            ).result
        case .processes:
            return try await runJSON(
                ["devicectl", "device", "info", "processes", "--device", selector], timeout: 60
            ).result
        case .apps:
            // Without this flag devicectl reports only developer-installed
            // apps, which reads as a near-empty device.
            return try await runJSON(
                ["devicectl", "device", "info", "apps", "--device", selector,
                 "--include-all-apps"], timeout: 120
            ).result
        case .ddiServices:
            return try await runJSON(
                ["devicectl", "device", "info", "ddiServices", "--device", selector], timeout: 45
            ).result

        case .crashLogIndex:
            // The systemCrashLogs domain is iOS's own diagnostic directory:
            // crash reports, jetsam events, and — the reason we want it —
            // resource-exhaustion reports naming the process that misbehaved.
            return try await runJSON([
                "devicectl", "device", "info", "files", "--device", selector,
                "--domain-type", "systemCrashLogs", "--recurse",
            ], timeout: 180).result

        case .crashLog(let name):
            return try await copyCrashLog(named: name, selector: selector)
        default:
            throw TransportError.unsupportedRequest(request, transport: displayName)
        }
    }

    /// Copy one file out of the crash-log domain and return its text.
    ///
    /// Reports are plain text with a JSON first line, so they are returned as a
    /// string for the parsers rather than as structured data — the body format
    /// is Apple's and changes shape between report types.
    private func copyCrashLog(named name: String, selector: String) async throws -> DynamicValue {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("auscult-report-\(UUID().uuidString).ips")
        defer { try? FileManager.default.removeItem(at: destination) }

        let result = try await Shell.run(xcrun, [
            "devicectl", "device", "copy", "from", "--device", selector,
            "--domain-type", "systemCrashLogs",
            "--source", name,
            "--destination", destination.path,
        ], timeout: 90)

        guard let data = FileManager.default.contents(atPath: destination.path) else {
            throw TransportError.malformedResponse(
                result.err.trimmed.firstLine.isEmpty
                    ? "could not copy \(name) off the device"
                    : result.err.trimmed.firstLine
            )
        }
        return DynamicValue([
            "name": name,
            "text": String(lossyUTF8: data),
            "size": data.count,
        ])
    }

    // MARK: Plumbing

    /// Run devicectl with JSON on stdout and surface Apple's own error text.
    private func runJSON(_ args: [String], timeout: TimeInterval) async throws -> DynamicValue {
        let r = try await Shell.run(xcrun, args + ["--json-output", "-", "--quiet"], timeout: timeout)
        let json = DynamicValue.parseJSON(r.stdout)

        // devicectl reports failure inside the JSON envelope as well as via
        // exit status; prefer its structured message when present.
        if let outcome = json.info.outcome.string, outcome != "success" {
            let msg = json.error.userInfo.NSLocalizedDescription.string
                ?? json.error.localizedDescription.string
                ?? r.err.trimmed.firstLine
            throw TransportError.malformedResponse(msg.isEmpty ? "devicectl outcome: \(outcome)" : msg)
        }
        guard r.succeeded || json.result.exists else {
            throw TransportError.malformedResponse(
                r.err.trimmed.firstLine.isEmpty ? "devicectl exited \(r.status)" : r.err.trimmed.firstLine
            )
        }
        return json
    }
}

// MARK: - Helpers

public extension DeviceSnapshot {
    /// Is the device in a state where live queries can succeed?
    ///
    /// Order matters: the negative forms *contain* the positive ones
    /// ("disconnected" contains "connected"), so they must be tested first.
    var isReachable: Bool {
        // A wired sighting from usbmux is ground truth and outranks everything
        // else. CoreDevice's `tunnelState` describes its own network tunnel, so
        // it reads "disconnected" for a device sitting on the end of a cable —
        // trusting that over the cable would disable every deep probe.
        if link == .usb { return true }

        if let t = tunnelState?.lowercased() {
            // Order matters: the negative forms contain the positive ones
            // ("disconnected" contains "connected").
            if t.contains("disconnected") || t.contains("unavailable")
                || t.contains("shutdown") || t.contains("shut down") { return false }
            if t.contains("connected") || t.contains("available") { return true }
        }
        if let boot = bootState?.lowercased() {
            if boot.contains("shutdown") || boot.contains("shut down") { return false }
        }
        return false
    }

    /// What to pass to `devicectl --device`.
    var devicectlSelector: String? { udid ?? coreDeviceIdentifier ?? ecid }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var firstLine: String { split(separator: "\n").first.map(String.init) ?? "" }
}

/// Apple mixes fractional-second and whole-second ISO stamps in the same
/// output, sometimes within one document. Try both rather than dropping a date.
enum FlexibleDate {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    static func parse(_ s: String) -> Date? {
        withFraction.date(from: s) ?? plain.date(from: s)
    }
}
