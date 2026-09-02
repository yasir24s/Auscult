import Foundation

// MARK: - Storage

/// Capacity, free space, and where the space went.
///
/// Free space is a health signal, not just housekeeping: iOS needs headroom to
/// perform wear levelling, and a volume held under a few percent free will
/// produce jetsam kills and write stalls that look like hardware faults.
public struct StorageProbe: Probe {
    public let id = "storage"
    public let title = "Storage"
    public let section = ReportSection.storage
    public let requiredCapabilities: Set<Capability> = []
    public var anyCapabilities: Set<Capability> { [.configuratorProperties, .fileConduit] }

    /// Human label → cfgutil property name.
    private static let usageKeys: [(String, String)] = [
        ("Apps", "appDiskUsage"), ("Photos", "photosDiskUsage"),
        ("Video", "videoDiskUsage"), ("Audio", "audioDiskUsage"),
        ("Books", "booksDiskUsage"), ("Documents", "documentsDiskUsage"),
        ("Logs", "logsDiskUsage"), ("Other", "otherDiskUsage"),
    ]

    public init() {}

    public func run(device: DeviceSnapshot, router: TransportRouter) async throws -> ProbeResult {
        let keys = ["totalDiskCapacity", "freeDiskSpace", "totalSpaceAvailable"]
            + Self.usageKeys.map(\.1)
        let cfg = await router.tryFetch(.configuratorProperties(keys), for: device)

        var metrics: [Metric] = []

        let total = cfg.totalDiskCapacity.int ?? device.storageCapacityBytes
        let free = cfg.freeDiskSpace.int ?? cfg.totalSpaceAvailable.int

        if let total {
            metrics.append(.reading("total", "Total capacity", .bytes(total)))
        }

        if let total, let free, total > 0 {
            let freePercent = Double(free) / Double(total) * 100
            metrics.append(.reading("free", "Free space", .bytes(free)))
            metrics.append(.graded(
                "freePercent", "Free space", freePercent, unit: "%",
                warnAt: 10, failAt: 4, higherIsBetter: true,
                note: "iOS needs headroom for wear levelling and updates",
                expectation: "keep above 10%"
            ))
        } else if free != nil {
            metrics.append(.reading("free", "Free space", .bytes(free!)))
        }

        // Usage breakdown, only for categories that actually reported.
        for (label, key) in Self.usageKeys {
            if let v = cfg.path(key).int, v > 0 {
                metrics.append(.reading("usage.\(key)", label, .bytes(v)))
            }
        }

        guard !metrics.isEmpty else {
            return result(.unsupported, "No storage figures available — requires a wired connection")
        }

        let verdict = rollup(metrics)
        var summary = "Storage reported"
        if let total, let free {
            summary = "\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free of "
                + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        }
        return result(verdict, summary, metrics: metrics)
    }
}

// MARK: - Display

/// Panel geometry and refresh characteristics as the OS reports them.
///
/// This is the *declared* configuration, not a panel test. Dead pixels,
/// backlight uniformity, and touch response can only be measured by the
/// on-device agent; what we can verify from the host is that the display
/// pipeline enumerates correctly and matches the model's expected geometry.
public struct DisplayProbe: Probe {
    public let id = "display"
    public let title = "Display Configuration"
    public let section = ReportSection.display
    public let requiredCapabilities: Set<Capability> = [.displayInfo]

    public init() {}

    public func run(device: DeviceSnapshot, router: TransportRouter) async throws -> ProbeResult {
        let raw = try await router.fetch(.displays, for: device)

        // The container key has moved before; take whichever array we find.
        var displays = raw.displays.array
        if displays.isEmpty { displays = raw.search(forKey: "displays").array }
        if displays.isEmpty, raw.searchAll(forKey: "displayID").isEmpty == false {
            displays = [raw]
        }

        guard !displays.isEmpty else {
            return result(.unsupported, "Device returned no display information",
                          detail: "displays payload was empty or reshaped")
        }

        var metrics: [Metric] = []
        for (i, d) in displays.enumerated() {
            let prefix = displays.count == 1 ? "display" : "display\(i + 1)"
            let label = displays.count == 1 ? "Panel" : "Panel \(i + 1)"

            let w = d.firstPresent("width", "pixelWidth", "nativeWidth").int
            let h = d.firstPresent("height", "pixelHeight", "nativeHeight").int
            if let w, let h {
                metrics.append(.reading("\(prefix).resolution", "\(label) resolution",
                    .string("\(w) × \(h)"), unit: "px"))
            }

            if let scale = d.firstPresent("scaleFactor", "scale").double {
                metrics.append(.reading("\(prefix).scale", "\(label) scale", .double(scale), unit: "×"))
            }
            if let refresh = d.firstPresent(
                "maximumFramesPerSecond", "refreshRate", "maximumRefreshRate"
            ).double {
                metrics.append(.reading("\(prefix).refresh", "\(label) max refresh",
                    .double(refresh), unit: "Hz"))
            }
            if let hdr = d.firstPresent("isHDRSupported", "supportsHDR").bool {
                metrics.append(.reading("\(prefix).hdr", "\(label) HDR", .bool(hdr)))
            }
            if let main = d.firstPresent("isMainDisplay", "isPrimary").bool, displays.count > 1 {
                metrics.append(.reading("\(prefix).main", "\(label) is primary", .bool(main)))
            }
        }

        metrics.append(.absent("panelIntegrity", "Panel & touch integrity",
            why: "dead-pixel sweep and digitizer grid require the on-device agent"))

        return result(.info, "\(displays.count) display\(displays.count == 1 ? "" : "s") enumerated",
                      metrics: metrics)
    }
}

// MARK: - Radio identity

/// Cellular and wireless identifiers.
///
/// Not a radio *test* — that needs the agent — but confirming the baseband
/// reports an IMEI and the SIM stack reports an ICCID does establish that those
/// subsystems are alive and enumerated.
public struct RadioIdentityProbe: Probe {
    public let id = "radios"
    public let title = "Radio Identity"
    public let section = ReportSection.radios
    public let requiredCapabilities: Set<Capability> = [.configuratorProperties]

    public init() {}

    public func run(device: DeviceSnapshot, router: TransportRouter) async throws -> ProbeResult {
        let cfg = try await router.fetch(.configuratorProperties([
            "IMEI", "IMEI2", "ICCID", "ICCID2", "phoneNumber", "phoneNumber2",
            "hasTelephonyCapability", "bluetoothAddress", "wifiAddress",
            "ethernetAddress", "firmwareVersion", "activationState",
        ]), for: device)

        var metrics: [Metric] = []

        let telephony = cfg.hasTelephonyCapability.bool ?? false
        metrics.append(.reading("telephony", "Cellular capable", .bool(telephony)))

        if telephony {
            // A cellular device with no IMEI has a baseband that isn't talking.
            let imei = cfg.IMEI.string
            metrics.append(Metric(
                id: "imei", label: "IMEI",
                value: imei.map { .string($0) } ?? .absent,
                verdict: imei == nil ? .fail : .pass,
                note: imei == nil
                    ? "cellular device reported no IMEI — the baseband is not responding"
                    : nil
            ))
            if let imei2 = cfg.IMEI2.string {
                metrics.append(.reading("imei2", "IMEI (second)", .string(imei2)))
            }

            let iccid = cfg.ICCID.string
            metrics.append(Metric(
                id: "iccid", label: "ICCID",
                value: iccid.map { .string($0) } ?? .absent,
                verdict: .info,
                note: iccid == nil ? "no SIM or eSIM profile active" : nil
            ))
            if let iccid2 = cfg.ICCID2.string {
                metrics.append(.reading("iccid2", "ICCID (second)", .string(iccid2)))
            }
            if let n = cfg.phoneNumber.string {
                metrics.append(.reading("phone", "Phone number", .string(n)))
            }
            if let fw = cfg.firmwareVersion.string {
                metrics.append(.reading("baseband", "Baseband firmware", .string(fw)))
            }
        }

        // MAC addresses double as a presence check for each radio.
        for (key, label, radio) in [
            ("wifiAddress", "Wi-Fi MAC", "Wi-Fi"),
            ("bluetoothAddress", "Bluetooth MAC", "Bluetooth"),
        ] {
            let v = cfg.path(key).string
            metrics.append(Metric(
                id: key, label: label,
                value: v.map { .string($0) } ?? .absent,
                verdict: v == nil ? .warn : .pass,
                note: v == nil ? "\(radio) interface did not report an address" : nil
            ))
        }

        if let state = cfg.activationState.string {
            let activated = state.lowercased().contains("activated")
            metrics.append(Metric(
                id: "activation", label: "Activation state", value: .string(state),
                verdict: activated ? .pass : .warn,
                note: activated ? nil : "device is not activated"
            ))
        }

        metrics.append(.absent("radioPerformance", "Signal & scan performance",
            why: "Wi-Fi/Bluetooth scan and RSSI tests require the on-device agent"))

        let verdict = rollup(metrics)
        return result(verdict, verdict >= .warn
            ? "One or more radios did not enumerate cleanly"
            : "All expected radios enumerated", metrics: metrics)
    }
}

// MARK: - Runtime

/// Live process state, used as a liveness check on each major subsystem.
///
/// Rather than looking for specific process names, each check names a
/// *subsystem* and lists every daemon known to have implemented it. Apple
/// renames and splits these freely — `mediaserverd` no longer exists on iOS 27,
/// having become `mediaplaybackd` and `audiomxd` — so a name-based check would
/// report a healthy device's audio stack as dead. Matching any one of a group
/// survives that, and only a subsystem with *nothing* alive is a finding.
public struct RuntimeProbe: Probe {
    public let id = "runtime"
    public let title = "Subsystem Liveness"
    public let section = ReportSection.stability
    public let requiredCapabilities: Set<Capability> = [.processList]
    public var appliesToSimulators: Bool { true }

    /// A subsystem, the daemons that have implemented it, and how bad its
    /// absence is.
    private struct Subsystem {
        let label: String
        let daemons: [String]
        let severity: Verdict
        /// Restrict to families where this subsystem should exist at all.
        var families: Set<DeviceFamily> = []
    }

    private static let subsystems: [Subsystem] = [
        .init(label: "Init (launchd)", daemons: ["launchd"], severity: .fail),
        .init(label: "Window server", daemons: ["backboardd"], severity: .fail),
        .init(label: "Shell / UI", daemons: ["SpringBoard", "Home"], severity: .warn),
        .init(label: "Process lifecycle", daemons: ["runningboardd", "assertiond"], severity: .warn),
        .init(label: "Media stack",
              daemons: ["mediaplaybackd", "audiomxd", "mediaserverd"], severity: .warn),
        .init(label: "Power management", daemons: ["powerd"], severity: .warn),
        .init(label: "Thermal management", daemons: ["thermalmonitord"], severity: .warn),
        .init(label: "Location", daemons: ["locationd"], severity: .warn),
        .init(label: "Security / trust", daemons: ["securityd", "trustd"], severity: .warn),
        .init(label: "Preferences", daemons: ["cfprefsd"], severity: .warn),
        .init(label: "Wi-Fi", daemons: ["wifid", "wifianalyticsd", "wifip2pd"], severity: .warn),
        .init(label: "Cellular", daemons: ["CommCenter"], severity: .warn,
              families: [.iPhone, .iPad]),
    ]

    public init() {}

    public func run(device: DeviceSnapshot, router: TransportRouter) async throws -> ProbeResult {
        let raw = try await router.fetch(.processes, for: device)
        var list = raw.runningProcesses.array
        if list.isEmpty { list = raw.search(forKey: "runningProcesses").array }
        if list.isEmpty { list = raw.search(forKey: "processes").array }

        guard !list.isEmpty else {
            return result(.unsupported, "Device returned no process list",
                          detail: "process payload was empty or reshaped")
        }

        // devicectl reports an executable path; the daemon name is its leaf.
        let names = Set(list.compactMap { p -> String? in
            guard let n = p.firstPresent("executable", "path", "name").string else { return nil }
            return (n as NSString).lastPathComponent
        })

        var metrics: [Metric] = [
            .reading("count", "Running processes", .int(Int64(list.count)))
        ]

        var missing: [String] = []
        for sub in Self.subsystems {
            if !sub.families.isEmpty && !sub.families.contains(device.family) { continue }
            let found = sub.daemons.filter { names.contains($0) }
            let alive = !found.isEmpty
            if !alive { missing.append(sub.label) }
            metrics.append(Metric(
                id: "subsystem.\(sub.label)",
                label: sub.label,
                value: alive ? .list(found) : .absent,
                verdict: alive ? .pass : sub.severity,
                note: alive ? nil : "no known daemon for this subsystem is running"
            ))
        }

        let verdict = rollup(metrics)
        let summary = missing.isEmpty
            ? "\(list.count) processes; all expected subsystems alive"
            : "\(list.count) processes; not running: \(missing.joined(separator: ", "))"
        return result(verdict, summary, metrics: metrics)
    }
}

// MARK: - Installed apps

/// App inventory. Useful for provenance — enterprise or sideloaded payloads
/// change how much of the rest of the report can be taken at face value.
public struct AppInventoryProbe: Probe {
    public let id = "apps"
    public let title = "Installed Applications"
    public let section = ReportSection.software
    public let requiredCapabilities: Set<Capability> = [.appInventory]
    public var appliesToSimulators: Bool { true }

    public init() {}

    public func run(device: DeviceSnapshot, router: TransportRouter) async throws -> ProbeResult {
        let raw = try await router.fetch(.apps, for: device)
        var apps = raw.apps.array
        if apps.isEmpty { apps = raw.search(forKey: "apps").array }

        guard !apps.isEmpty else {
            return result(.unsupported, "Device returned no app inventory")
        }

        var byType: [String: Int] = [:]
        for a in apps {
            // Only string-valued keys are usable as a grouping label; devicectl
            // also carries booleans like `appClip` that would bucket as "0".
            let t = a.firstPresent("installationType", "type").string
                ?? (a.bundleIdentifier.string?.hasPrefix("com.apple.") == true ? "system" : "user")
            byType[t, default: 0] += 1
        }

        var metrics: [Metric] = [.reading("count", "Total apps", .int(Int64(apps.count)))]
        for (t, n) in byType.sorted(by: { $0.key < $1.key }) {
            metrics.append(.reading("type.\(t)", t.capitalized, .int(Int64(n))))
        }

        // Developer-signed apps are what the agent will join, so surface them.
        let devSigned = apps.filter {
            $0.firstPresent("installationType", "type").string?.lowercased().contains("develop") == true
        }
        if !devSigned.isEmpty {
            metrics.append(.reading("developerSigned", "Developer-signed apps",
                .list(devSigned.compactMap { $0.bundleIdentifier.string }.sorted())))
        }

        return result(.info, "\(apps.count) applications installed", metrics: metrics)
    }
}

// MARK: - Third-party processes

/// Lists the third-party apps resident in memory.
///
/// The host cannot get per-process energy attribution — that lives in the
/// device's power log — but it can say what is *resident*, and for a drain
/// investigation that is a useful lead.
///
/// An important caveat, stated in the output as well as here: iOS keeps
/// recently-used apps in memory in a **suspended** state. A suspended app holds
/// a process and appears in this list while consuming no CPU at all. So a long
/// list is not by itself evidence of a drain — it is a shortlist of candidates
/// to check against Settings › Battery, which is the only place per-app energy
/// is actually attributed.
///
/// Third-party code is identified by path: installed apps live under
/// `/private/var/containers/Bundle/Application/`, whereas system binaries come
/// from the sealed system volume.
public struct RunningAppsProbe: Probe {
    public let id = "runtime.thirdparty"
    public let title = "Third-party Processes"
    public let section = ReportSection.stability
    public let requiredCapabilities: Set<Capability> = [.processList]
    public var appliesToSimulators: Bool { true }

    public init() {}

    public func run(device: DeviceSnapshot, router: TransportRouter) async throws -> ProbeResult {
        let raw = try await router.fetch(.processes, for: device)
        var list = raw.runningProcesses.array
        if list.isEmpty { list = raw.search(forKey: "runningProcesses").array }

        guard !list.isEmpty else {
            return result(.unsupported, "Device returned no process list")
        }

        var thirdParty: [String] = []
        var appExtensions: [String] = []

        for process in list {
            guard let path = process.firstPresent("executable", "path", "name").string
            else { continue }

            // Container-resident code is installed, not part of the OS.
            guard path.contains("/containers/Bundle/Application/")
                    || path.contains("/var/containers/Bundle/")
            else { continue }

            // Paths arrive percent-encoded, so "Auscult%20Agent" needs decoding.
            let raw = (path as NSString).lastPathComponent
            let name = raw.removingPercentEncoding ?? raw
            // Extensions run on an app's behalf (widgets, keyboards, share
            // sheets) and are a common source of background work.
            if path.contains(".appex/") {
                appExtensions.append(name)
            } else {
                thirdParty.append(name)
            }
        }

        thirdParty = Array(Set(thirdParty)).sorted()
        appExtensions = Array(Set(appExtensions)).sorted()

        // Some classes of app are persistent *by design* and so cost power
        // continuously rather than occasionally. A VPN holds a network
        // extension up permanently; a location-sharing app keeps locationd
        // running. These are worth naming separately because the remedy is
        // different: you cannot fix them with Background App Refresh, only by
        // removing or reconfiguring the app.
        let persistentPatterns = [
            "vpn", "hotspotshield", "proton", "wireguard", "openvpn", "tunnel",
            "life360", "find", "tile", "adblock", "dns",
        ]
        let persistent = (thirdParty + appExtensions).filter { name in
            persistentPatterns.contains { name.localizedCaseInsensitiveContains($0) }
        }.sorted()

        var metrics: [Metric] = [
            .reading("total", "Total processes", .int(Int64(list.count))),
            .reading("thirdPartyCount", "Third-party apps resident",
                     .int(Int64(thirdParty.count)),
                     note: "includes apps iOS is holding suspended, which use no CPU"),
        ]
        if !thirdParty.isEmpty {
            metrics.append(.reading("thirdParty", "Apps in memory", .list(thirdParty),
                note: "a shortlist to check against Settings › Battery — "
                    + "residency alone does not mean an app is consuming power"))
        }
        if !persistent.isEmpty {
            metrics.append(Metric(
                id: "persistent", label: "Continuously-running app classes",
                value: .list(persistent),
                verdict: persistent.count >= 2 ? .warn : .info,
                note: "VPNs, location sharing and content blockers hold system "
                    + "extensions up permanently — Background App Refresh does not "
                    + "affect them. Two VPNs is one more than any device needs."
            ))
        }
        if !appExtensions.isEmpty {
            metrics.append(.reading("extensions", "App extensions resident",
                .list(appExtensions),
                note: "widgets, keyboards and notification handlers run on an app's behalf "
                    + "and are woken by the system rather than by you"))
        }

        // Informational by design: a running app is not a fault, and the number
        // that would justify a warning depends entirely on what the person was
        // just doing with the phone.
        let summary = thirdParty.isEmpty
            ? "No third-party apps resident"
            : "\(thirdParty.count) third-party app\(thirdParty.count == 1 ? "" : "s") "
              + "and \(appExtensions.count) extension\(appExtensions.count == 1 ? "" : "s") resident"
        return result(.info, summary, metrics: metrics)
    }
}
