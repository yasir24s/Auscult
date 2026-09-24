import Foundation

// MARK: - Identity

/// Hardware identity. Cheap, always available, and the anchor for every other
/// probe's expectations (a battery's design capacity only means something once
/// you know which model you're holding).
public struct IdentityProbe: Probe {
    public let id = "identity"
    public let title = "Hardware Identity"
    public let section = ReportSection.identity
    public let requiredCapabilities: Set<Capability> = [.deviceIdentity]
    public var appliesToSimulators: Bool { true }

    public init() {}

    public func run(device: DeviceSnapshot, router: TransportRouter) async throws -> ProbeResult {
        // Discovery already gave us most of this; the details tree adds board
        // revision and richer CPU data when the device is actually reachable.
        let details = await router.tryFetch(.deviceDetails, for: device)

        var metrics: [Metric] = []
        metrics.append(.reading("model", "Model",
            .string(device.marketingName ?? device.productType ?? "unknown")))
        metrics.append(.reading("productType", "Product identifier",
            device.productType.map { .string($0) } ?? .absent))

        let board = device.hardwareModel
            ?? details.firstPresent(
                "properties.hardware.hardwareModel", "hardwareProperties.hardwareModel"
            ).string
        metrics.append(.reading("board", "Board", board.map { .string($0) } ?? .absent))

        metrics.append(.reading("chip", "CPU architecture",
            device.chipName.map { .string($0) } ?? .absent))

        if let p = device.physicalCores {
            let l = device.logicalCores ?? p
            metrics.append(.reading("cores", "CPU cores",
                .string(p == l ? "\(p)" : "\(p) physical / \(l) logical")))
        }

        metrics.append(.reading("capacity", "Nominal storage",
            device.storageCapacityBytes.map { .bytes($0) } ?? .absent))

        metrics.append(.reading("serial", "Serial number",
            device.serialNumber.map { .string($0) } ?? .absent))
        metrics.append(.reading("udid", "UDID",
            device.udid.map { .string($0) } ?? .absent))
        metrics.append(.reading("ecid", "ECID",
            device.ecid.map { .string($0) } ?? .absent,
            note: device.isSimulator ? "simulators have no ECID" : nil))

        metrics.append(.reading("biometrics", "Biometric hardware",
            device.supportedBiometrics.isEmpty ? .absent : .list(device.supportedBiometrics)))

        if let ab = device.hasActionButton {
            metrics.append(.reading("actionButton", "Action button", .bool(ab)))
        }

        let name = device.marketingName ?? device.productType ?? "Unidentified device"
        return result(.info, device.isSimulator ? "\(name) (simulator)" : name, metrics: metrics)
    }
}

// MARK: - Software

/// OS build identification, including whether this is a seed.
///
/// Beta detection matters for interpreting everything else: prerelease builds
/// legitimately log more panics, run hotter, and drain faster, so a warning on a
/// seed deserves different weight than the same warning on a shipping build.
public struct SoftwareProbe: Probe {
    public let id = "software"
    public let title = "Operating System"
    public let section = ReportSection.software
    public let requiredCapabilities: Set<Capability> = [.deviceIdentity]
    public var appliesToSimulators: Bool { true }

    public init() {}

    public func run(device: DeviceSnapshot, router: TransportRouter) async throws -> ProbeResult {
        var metrics: [Metric] = []

        metrics.append(.reading("platform", "Platform",
            device.osName.map { .string($0) } ?? .absent))
        metrics.append(.reading("version", "Version",
            device.osVersion.map { .string($0) } ?? .absent))
        metrics.append(.reading("build", "Build",
            device.osBuild.map { .string($0) } ?? .absent))

        if let train = device.osTrainProgram {
            metrics.append(.reading("train", "Build train", .string(train)))
        }

        let prerelease = device.isPrereleaseOS
        metrics.append(Metric(
            id: "prerelease", label: "Prerelease build",
            value: .bool(prerelease), verdict: .info,
            note: prerelease
                ? "seed build — elevated panic and thermal readings are expected"
                : "public release"
        ))

        if let rt = device.releaseType {
            var m = Metric.reading("releaseType", "Release type (CoreDevice)", .string(rt))
            if device.releaseTypeContradictsBuild {
                m.note = "reported by CoreDevice, but \(device.osBuild ?? "the build") is a release "
                    + "build, which is what decides the prerelease tag — this label may reflect "
                    + "beta-update enrolment rather than the installed software"
            }
            metrics.append(m)
        }

        // A supplemental build (rapid security response) is worth flagging
        // because it changes the build string without changing the version.
        let details = await router.tryFetch(.deviceDetails, for: device)
        if let supplemental = details.firstPresent(
            "properties.software.osBuildVersions.supplementalBuildVersion.name"
        ).string, supplemental != device.osBuild {
            metrics.append(.reading("supplemental", "Supplemental build", .string(supplemental)))
        }

        let summary = [device.osName, device.osVersion].compactMap { $0 }.joined(separator: " ")
        return result(
            .info,
            "\(summary.isEmpty ? "Unknown OS" : summary)\(device.osBuild.map { " (\($0))" } ?? "")"
                + (prerelease ? " — prerelease" : ""),
            metrics: metrics
        )
    }
}

// MARK: - Security posture

/// Trust and integrity state.
///
/// These flags decide how much of the rest of the report can be trusted. A
/// device with a writable root filesystem or a non-production fuse set is not a
/// device whose self-reported health numbers mean much.
public struct SecurityPostureProbe: Probe {
    public let id = "security"
    public let title = "Integrity & Trust"
    public let section = ReportSection.security
    public let requiredCapabilities: Set<Capability> = [.deviceIdentity]
    public var appliesToSimulators: Bool { true }

    public init() {}

    public func run(device: DeviceSnapshot, router: TransportRouter) async throws -> ProbeResult {
        var metrics: [Metric] = []

        if device.isSimulator {
            return result(.skipped, "Simulator — no hardware trust state to evaluate", metrics: [
                .reading("simulator", "Simulator", .bool(true))
            ])
        }

        if let fused = device.isProductionFused {
            metrics.append(Metric(
                id: "productionFused", label: "Production fused",
                value: .bool(fused),
                verdict: fused ? .pass : .warn,
                note: fused
                    ? "retail security configuration"
                    : "development/internal fuse set — this is not a retail unit"
            ))
        }

        if let writable = device.rootFileSystemIsWritable {
            metrics.append(Metric(
                id: "rootWritable", label: "Root filesystem writable",
                value: .bool(writable),
                verdict: writable ? .fail : .pass,
                note: writable
                    ? "system volume is mutable — sealed-system integrity is not intact"
                    : "system volume is sealed as expected"
            ))
        }

        if let internalBuild = device.hasInternalOSBuild {
            metrics.append(Metric(
                id: "internalBuild", label: "Internal OS build",
                value: .bool(internalBuild),
                verdict: internalBuild ? .warn : .pass,
                note: internalBuild ? "carrier build not intended for customer devices" : nil
            ))
        }

        if let devMode = device.developerModeEnabled {
            metrics.append(Metric(
                id: "developerMode", label: "Developer Mode",
                value: .bool(devMode), verdict: .info,
                note: devMode
                    ? "enabled — required for the deepest probes and the on-device agent"
                    : "disabled — process listing, app install, and the agent are unavailable"
            ))
        }

        if let boot = device.bootState {
            let normal = boot.lowercased().contains("booted")
            metrics.append(Metric(
                id: "bootState", label: "Boot state", value: .string(boot),
                verdict: normal ? .pass : .warn,
                note: normal ? nil : "device is not in a normally booted state"
            ))
        }

        let verdict = rollup(metrics)
        let summary = switch verdict {
        case .fail: "Integrity concerns found — readings below may not be trustworthy"
        case .warn: "Non-retail or non-standard configuration detected"
        default: "Trust state consistent with a stock retail device"
        }
        return result(verdict, summary, metrics: metrics)
    }
}

// MARK: - Connectivity

/// How we're attached, and what that costs us in coverage.
public struct ConnectivityProbe: Probe {
    public let id = "connectivity"
    public let title = "Host Link"
    public let section = ReportSection.identity
    public let requiredCapabilities: Set<Capability> = []
    public var appliesToSimulators: Bool { true }

    public init() {}

    public func run(device: DeviceSnapshot, router: TransportRouter) async throws -> ProbeResult {
        let caps = await router.capabilityMap(for: device)
        var metrics: [Metric] = []

        metrics.append(.reading("link", "Transport", .string(device.link.rawValue)))
        metrics.append(Metric(
            id: "pairing", label: "Pairing", value: .string(device.pairing.rawValue),
            verdict: device.pairing == .paired ? .pass : .warn,
            note: device.pairing == .paired ? nil : "unpaired devices expose almost nothing"
        ))

        if let t = device.tunnelState {
            metrics.append(.reading("tunnel", "Connection state", .string(t)))
        }
        if let seen = device.lastSeen {
            metrics.append(.reading("lastSeen", "Last connected",
                .string(seen.formatted(date: .abbreviated, time: .shortened))))
        }

        metrics.append(.reading("capabilities", "Resolved capabilities",
            .list(caps.keys.map(\.rawValue).sorted())))

        // Name the transports so the user can see which path is carrying the run.
        var byTransport: [String: Int] = [:]
        for t in caps.values { byTransport[t, default: 0] += 1 }
        for (tid, count) in byTransport.sorted(by: { $0.key < $1.key }) {
            metrics.append(.reading("served.\(tid)", await router.transportName(tid),
                .string("\(count) capabilit\(count == 1 ? "y" : "ies")")))
        }

        // Judge connectivity by what actually resolved, not by a flag.
        //
        // `isReachable` infers from transport and tunnel state, and for a device
        // reachable only over Wi-Fi it says "no" while eight capabilities
        // resolve perfectly well — a report that contradicts itself. The count
        // of working capabilities is the honest measure.
        let reachable = caps.count > 1

        // Only advise a cable when it would actually add something.
        let deepCaps: Set<Capability> = [.batteryGauge, .nandStats, .crashLogs, .configuratorProperties]
        let missingDeep = deepCaps.subtracting(caps.keys)
        if !device.isSimulator, !missingDeep.isEmpty {
            metrics.append(Metric(
                id: "wiredAdvice", label: "Coverage", value: .string("partial"),
                verdict: .info,
                note: "a USB connection would add: "
                    + missingDeep.map(\.rawValue).sorted().joined(separator: ", ")
            ))
        }

        let verdict = rollup(metrics)
        let summary: String
        if !reachable {
            summary = "Not reachable — no capabilities resolved beyond cached identity"
        } else if device.link == .usb {
            summary = "Connected over USB with \(caps.count) capabilities"
        } else {
            summary = "Reachable over \(device.link.rawValue) with \(caps.count) capabilities"
        }
        return result(reachable ? verdict : .skipped, summary, metrics: metrics)
    }
}
