import Foundation

/// What is actually occupying the device's RAM.
///
/// Answers "where did my 12 GB go" by category, using the process table that
/// jetsam reports carry. Reported rather than graded for the most part: a
/// suspended app holding memory is exactly what iOS is supposed to do, and only
/// becomes a problem when there is nothing left — which the free-memory and
/// thrashing figures cover.
public struct MemoryCensusProbe: Probe {
    public let id = "memory.census"
    public let title = "Memory Census"
    public let section = ReportSection.compute
    public let requiredCapabilities: Set<Capability> = [.crashLogs]

    public init() {}

    public func run(device: DeviceSnapshot, router: TransportRouter) async throws -> ProbeResult {
        let listing = try await router.fetch(.crashLogIndex, for: device)
        let index = DiagnosticReportIndex.parse(listing)

        // The most recent kill is the most representative worst moment.
        guard let entry = index.recent(.jetsam, limit: 1).first,
              let payload = try? await router.fetch(.crashLog(name: entry.path), for: device),
              let text = payload.text.string,
              let census = MemoryCensus.parse(text, date: entry.date)
        else {
            return result(.unsupported,
                "No readable memory snapshot — requires a jetsam report on the device")
        }

        // The census is historical, not live. Its age is itself informative:
        // no new jetsam report means iOS has not had to kill anything since,
        // which is the outcome you want after freeing memory.
        let age = census.date.map { Date().timeIntervalSince($0) }
        let ageNote: String = {
            guard let age else { return "captured when iOS last killed a process for memory" }
            let hours = age / 3600
            let stamp = hours < 1
                ? "\(Int(age / 60)) minutes ago"
                : (hours < 48 ? "\(hours.oneDecimal) hours ago" : "\((hours / 24).oneDecimal) days ago")
            return "captured \(stamp), when iOS last killed a process for memory — "
                + "nothing since means no further kills have been needed"
        }()

        var metrics: [Metric] = [
            .reading("snapshotAt", "Snapshot taken",
                .string(census.date.map { $0.formatted(date: .abbreviated, time: .shortened) }
                    ?? "unknown"),
                note: ageNote),
            .reading("processCount", "Processes resident",
                     .int(Int64(census.processes.count))),
        ]

        // Kernel accounting first: this is where the RAM actually is.
        metrics.append(.reading("wired", "Wired (non-evictable)",
            .bytes(census.kernel.wired),
            note: "kernel and drivers — cannot be freed or compressed"))
        metrics.append(.reading("active", "Active", .bytes(census.kernel.active)))
        metrics.append(.reading("inactive", "Inactive", .bytes(census.kernel.inactive),
            note: "reclaimable, but reclaiming costs work"))
        metrics.append(.reading("compressor", "Compressed page store",
            .bytes(census.kernel.compressor),
            note: "pages squeezed to make room — the larger this is, the harder "
                + "the memory system is working"))
        metrics.append(.graded(
            "free", "Free", Double(census.kernel.free) / 1_048_576, unit: "MB",
            warnAt: 500, failAt: 250, higherIsBetter: true,
            expectation: "a device with headroom keeps far more than this"
        ))

        // By category, so the answer is legible.
        for category in MemoryCensus.Category.allCases {
            let total = census.total(of: category)
            guard total > 0 else { continue }
            let count = census.processes.filter { $0.category == category }.count
            metrics.append(.reading("category.\(category.rawValue)", category.rawValue,
                .bytes(total), note: "\(count) process\(count == 1 ? "" : "es")"))
        }

        // Suspended apps: the memory that could be freed for nothing.
        let suspended = census.processes.filter(\.isSuspended)
        if !suspended.isEmpty {
            metrics.append(.reading("suspendedTotal", "Held by suspended apps",
                .bytes(census.suspendedTotal),
                note: "\(suspended.count) apps iOS is keeping in memory but not running — "
                    + "closing them frees this at no cost to performance"))
        }

        // The top consumers, named.
        for (rank, process) in census.processes.prefix(15).enumerated() {
            let state = process.states.isEmpty ? "" : " (\(process.states.joined(separator: ", ")))"
            metrics.append(.reading("top.\(rank)", "#\(rank + 1)  \(process.name)",
                .bytes(process.residentBytes),
                note: "\(process.category.rawValue)\(state)"))
        }

        let verdict = rollup(metrics)
        let summary = "\(census.processes.count) processes resident, "
            + "\(ByteCountFormatter.string(fromByteCount: census.kernel.wired, countStyle: .memory)) wired, "
            + "\(ByteCountFormatter.string(fromByteCount: census.kernel.free, countStyle: .memory)) free"
        return result(verdict, summary, metrics: metrics)
    }
}
