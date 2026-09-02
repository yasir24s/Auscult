import Foundation

/// Whether the device is thrashing its memory compressor.
///
/// This is a drain cause that no power measurement reveals directly. When RAM
/// runs out, iOS compresses inactive pages rather than paging to flash — and
/// when there is *persistently* too little, it spends its time compressing and
/// immediately decompressing the same pages. That work costs CPU continuously
/// and produces nothing, so the device draws power while appearing idle.
///
/// The counters live in jetsam reports, which iOS writes whenever it kills a
/// process for memory. Comparing two reports gives the compression *rate*,
/// which is the figure that distinguishes normal memory management from
/// thrashing: the absolute count only ever climbs.
public struct MemoryPressureProbe: Probe {
    public let id = "memory.pressure"
    public let title = "Memory Pressure"
    public let section = ReportSection.compute
    public let requiredCapabilities: Set<Capability> = [.crashLogs]

    /// Reports to open. Two is the minimum for a rate; more smooths it out.
    private let sampleLimit = 5

    public init() {}

    public func run(device: DeviceSnapshot, router: TransportRouter) async throws -> ProbeResult {
        let listing = try await router.fetch(.crashLogIndex, for: device)
        let index = DiagnosticReportIndex.parse(listing)
        let events = index.recent(.jetsam, limit: sampleLimit)

        guard !events.isEmpty else {
            return result(.pass, "No memory kills on record",
                          metrics: [.reading("kills", "Memory kill events", .int(0))])
        }

        struct Sample {
            var date: Date
            var compressions: Double
            var decompressions: Double
            var freeBytes: Double
            var reasons: [String]
            var victims: [(name: String, reason: String)]
        }

        var samples: [Sample] = []
        for entry in events {
            if Task.isCancelled { break }
            guard let payload = try? await router.fetch(.crashLog(name: entry.path), for: device),
                  let text = payload.text.string
            else { continue }

            // A jetsam report is a JSON header line followed by a JSON body.
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            guard lines.count > 1 else { continue }
            let bodyText = lines.dropFirst().joined(separator: "\n")
            guard let bodyData = bodyText.data(using: .utf8) else { continue }
            let body = DynamicValue.parseJSON(bodyData)

            let status = body.memoryStatus
            let pageSize = status.pageSize.double ?? 16384
            let processes = body.processes.array
            let victims = processes.compactMap { process -> (String, String)? in
                guard let reason = process.reason.string, !reason.isEmpty,
                      let name = process.name.string else { return nil }
                return (name, reason)
            }

            samples.append(Sample(
                date: entry.date ?? Date.distantPast,
                compressions: status.compressions.double ?? 0,
                decompressions: status.decompressions.double ?? 0,
                freeBytes: (status.memoryPages.free.double ?? 0) * pageSize,
                reasons: Array(Set(victims.map(\.1))).sorted(),
                victims: victims
            ))
        }

        guard !samples.isEmpty else {
            return result(.unsupported, "Memory kill reports could not be read")
        }
        samples.sort { $0.date < $1.date }

        var metrics: [Metric] = [
            .reading("killEvents", "Memory kill events on device",
                     .int(Int64(index.count(of: .jetsam)))),
        ]

        // Free memory at the moment of a kill. On a device with 11 GB of RAM,
        // triple digits of megabytes is exhaustion.
        if let lowest = samples.map(\.freeBytes).min() {
            metrics.append(.graded(
                "freeAtKill", "Lowest free memory at a kill",
                lowest / 1_048_576, unit: "MB",
                warnAt: 400, failAt: 200, higherIsBetter: true,
                note: "how much RAM was left when iOS started killing processes",
                expectation: "a healthy device does not get this low"
            ))
        }

        // The rate is the diagnosis. An absolute count always rises.
        if samples.count >= 2, let first = samples.first, let last = samples.last {
            let seconds = last.date.timeIntervalSince(first.date)
            let delta = last.compressions - first.compressions
            if seconds > 60, delta > 0 {
                let perSecond = delta / seconds
                metrics.append(.graded(
                    "compressionRate", "Page compression rate", perSecond, unit: "/s",
                    warnAt: 200, failAt: 600, higherIsBetter: false,
                    note: "\(Int(delta).formatted()) compressions over "
                        + "\((seconds / 3600).oneDecimal)h — each one is CPU work that "
                        + "produces nothing, so this burns power while the device looks idle",
                    expectation: "an untroubled device is near zero between kills"
                ))
                // Decompressing what was just compressed is the definition of
                // thrashing, as opposed to compressing pages once and leaving them.
                let decompressionDelta = last.decompressions - first.decompressions
                if decompressionDelta > 0 {
                    let ratio = decompressionDelta / delta * 100
                    metrics.append(.graded(
                        "thrashRatio", "Pages decompressed again", ratio, unit: "%",
                        warnAt: 40, failAt: 60, higherIsBetter: false,
                        note: "share of compressed pages that were immediately needed back — "
                            + "high means the compressor is thrashing rather than archiving",
                        expectation: "well under 40%"
                    ))
                }
            }
        }

        // Kill reasons name the mechanism.
        let allReasons = samples.flatMap(\.reasons)
        var reasonCounts: [String: Int] = [:]
        for reason in allReasons { reasonCounts[reason, default: 0] += 1 }
        if !reasonCounts.isEmpty {
            let thrashing = reasonCounts.keys.contains { $0.contains("thrashing") }
            metrics.append(Metric(
                id: "killReasons", label: "Kill reasons",
                value: .list(reasonCounts.sorted { $0.value > $1.value }
                    .map { "\($0.key) (\($0.value))" }),
                verdict: thrashing ? .fail : .info,
                note: thrashing
                    ? "'thrashing' means iOS killed a process because the memory system "
                      + "could not keep up — the device is short of RAM, not just busy"
                    : nil
            ))
        }

        // Who is being killed repeatedly? A process killed and relaunched
        // repeats its startup cost every time.
        var victimCounts: [String: Int] = [:]
        for sample in samples {
            for victim in sample.victims { victimCounts[victim.name, default: 0] += 1 }
        }
        let repeatVictims = victimCounts.filter { $0.value >= 2 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        if !repeatVictims.isEmpty {
            metrics.append(.reading("repeatVictims", "Killed repeatedly",
                .list(repeatVictims.map { "\($0.key) (\($0.value)×)" }),
                note: "each relaunch repeats the process's startup work"))
        }

        let verdict = rollup(metrics)
        let summary: String
        if let first = samples.first, let last = samples.last, samples.count >= 2,
           last.date.timeIntervalSince(first.date) > 60 {
            let seconds = last.date.timeIntervalSince(first.date)
            let perSecond = (last.compressions - first.compressions) / seconds
            let lowestFreeMB = (samples.map(\.freeBytes).min() ?? 0) / 1_048_576
            summary = "\(Int(perSecond).formatted()) page compressions/s sustained; "
                + "\(lowestFreeMB.zeroDecimal) MB free at the worst kill"
        } else {
            summary = "\(index.count(of: .jetsam)) memory kills on record"
        }
        return result(verdict, summary, metrics: metrics)
    }
}
