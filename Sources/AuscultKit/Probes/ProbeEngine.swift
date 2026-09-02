import Foundation

/// Runs a probe set against one device and assembles the report.
public struct ProbeEngine: Sendable {
    public let probes: [any Probe]

    public init(probes: [any Probe] = ProbeEngine.standardProbes) {
        self.probes = probes
    }

    /// Every host-side probe, in report order.
    public static var standardProbes: [any Probe] {
        [
            IdentityProbe(),
            SoftwareProbe(),
            SecurityPostureProbe(),
            ConnectivityProbe(),
            BatteryProbe(),
            PowerTelemetryProbe(),
            PowerHistoryProbe(),
            LiveDrainProbe(),
            EnergyAttributionProbe(),
            BatteryDeathProbe(),
            StorageProbe(),
            DisplayProbe(),
            RadioIdentityProbe(),
            RuntimeProbe(),
            RunningAppsProbe(),
            StabilityHistoryProbe(),
            AccessoryHealthProbe(),
            MemoryPressureProbe(),
            MemoryCensusProbe(),
            AppInventoryProbe(),
        ]
    }

    public struct Progress: Sendable {
        public let completed: Int
        public let total: Int
        public let currentTitle: String
        public var fraction: Double { total == 0 ? 1 : Double(completed) / Double(total) }
    }

    /// Execute the run. Probes run sequentially so a single device isn't hit by
    /// ten concurrent service connections — lockdownd serialises anyway and
    /// parallelism there mostly produces spurious failures.
    public func run(
        device: DeviceSnapshot,
        router: TransportRouter,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async -> DiagnosticReport {
        let started = Date()
        let capabilityMap = await router.capabilityMap(for: device)
        let available = Set(capabilityMap.keys)

        var results: [ProbeResult] = []
        for (index, probe) in probes.enumerated() {
            onProgress?(Progress(completed: index, total: probes.count, currentTitle: probe.title))

            if let skip = Self.skipReason(for: probe, device: device, available: available) {
                results.append(skip)
                continue
            }

            let t0 = Date()
            var outcome: ProbeResult
            do {
                outcome = try await probe.run(device: device, router: router)
            } catch is CancellationError {
                break
            } catch {
                // An unexpected throw is the signal that something moved
                // underneath us. Surface it loudly instead of as "unsupported".
                outcome = ProbeResult(
                    probeID: probe.id, title: probe.title, section: probe.section,
                    verdict: .error,
                    summary: "Probe failed unexpectedly — the data path may have changed",
                    diagnosticDetail: error.localizedDescription
                )
            }
            outcome.duration = Date().timeIntervalSince(t0)
            if outcome.servedBy == nil,
               let served = probe.allCapabilities.compactMap({ capabilityMap[$0] }).first {
                outcome.servedBy = await router.transportName(served)
            }
            results.append(outcome)
        }

        onProgress?(Progress(completed: probes.count, total: probes.count, currentTitle: "Done"))
        results.sort { ($0.section.order, $0.probeID) < ($1.section.order, $1.probeID) }

        return DiagnosticReport(
            device: device,
            startedAt: started,
            finishedAt: Date(),
            results: results,
            capabilities: available.map(\.rawValue).sorted(),
            hostInfo: await HostInfo.current(router: router)
        )
    }

    /// Decide up front whether a probe can meaningfully run, so the report says
    /// *why* something is absent rather than just omitting it.
    static func skipReason(
        for probe: any Probe, device: DeviceSnapshot, available: Set<Capability>
    ) -> ProbeResult? {
        func make(_ v: Verdict, _ s: String) -> ProbeResult {
            ProbeResult(
                probeID: probe.id, title: probe.title, section: probe.section,
                verdict: v, summary: s
            )
        }

        if device.isSimulator && !probe.appliesToSimulators {
            return make(.skipped, "Not applicable to a simulator — no hardware to measure")
        }
        if !probe.applicableFamilies.isEmpty && !probe.applicableFamilies.contains(device.family) {
            return make(.skipped, "Not applicable to \(device.family.rawValue)")
        }
        if !probe.anyCapabilities.isEmpty && probe.anyCapabilities.isDisjoint(with: available) {
            let names = probe.anyCapabilities.map(\.rawValue).sorted().joined(separator: " or ")
            return make(.unsupported, device.isReachable
                ? "needs one of: \(names) — none available on this host"
                : "device is not connected — connect over USB and retry (needs \(names))")
        }
        let missing = probe.requiredCapabilities.subtracting(available)
        if !missing.isEmpty {
            let names = missing.map(\.rawValue).sorted().joined(separator: ", ")
            let hint = device.isReachable
                ? "no available transport provides: \(names)"
                : "device is not connected — connect over USB and retry (needs: \(names))"
            return make(.unsupported, hint)
        }
        return nil
    }
}

public extension HostInfo {
    /// Record the host toolchain in every report — when a probe breaks on a new
    /// seed, the first question is always which devicectl produced it.
    static func current(router: TransportRouter) async -> HostInfo {
        let av = await router.availabilitySnapshot()
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var xcode: String?
        if let r = try? await Shell.run("/usr/bin/xcodebuild", ["-version"], timeout: 20), r.succeeded {
            xcode = r.out.trimmed.replacingOccurrences(of: "\n", with: " ")
        }
        return HostInfo(
            macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            xcodeVersion: xcode,
            devicectlVersion: av["coredevice"]?.version,
            cfgutilVersion: av["cfgutil"]?.version,
            auscultVersion: Auscult.version
        )
    }
}

public enum Auscult {
    public static let version = "0.1.0"
}
