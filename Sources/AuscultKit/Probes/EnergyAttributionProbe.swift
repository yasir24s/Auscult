import Foundation

/// Which app is draining the battery.
///
/// iOS exposes no per-process energy API to third parties, but it does write a
/// report every time a process exceeds a resource limit — and each report is
/// named for the culprit. Counting and weighting those reports attributes
/// misbehaviour to specific apps using nothing but a directory listing.
///
/// This is evidence, not proof. A CPU-exhaustion report means the process held
/// a core at high utilisation for minutes, which certainly costs energy; a
/// disk-writes report costs less. So the kinds are weighted rather than summed,
/// and the ranking is presented as a shortlist to check against Settings ›
/// Battery, which is where iOS does the real attribution.
public struct EnergyAttributionProbe: Probe {
    public let id = "power.attribution"
    public let title = "Energy Offenders"
    public let section = ReportSection.power
    public let requiredCapabilities: Set<Capability> = [.crashLogs]
    public var applicableFamilies: Set<DeviceFamily> { [.iPhone, .iPad, .iPod] }

    /// How far back to look. Long enough to see a pattern, recent enough that
    /// an app uninstalled last month doesn't top the list.
    private let window: TimeInterval = 14 * 24 * 3600
    /// How many CPU reports to open for real numbers. Each costs a file copy,
    /// so the index does the ranking and only the worst get read.
    private let detailLimit = 6

    public init() {}

    public func run(device: DeviceSnapshot, router: TransportRouter) async throws -> ProbeResult {
        let listing = try await router.fetch(.crashLogIndex, for: device)
        let index = DiagnosticReportIndex.parse(listing)

        guard !index.entries.isEmpty else {
            return result(.unsupported, "The device reported no diagnostic files")
        }

        let cutoff = Date().addingTimeInterval(-window)
        let offenders = index.offenders(since: cutoff)

        var metrics: [Metric] = [
            .reading("reportsTotal", "Diagnostic reports on device",
                     .int(Int64(index.entries.count))),
            .reading("windowDays", "Attribution window", .int(14), unit: "days"),
        ]

        // Counts by kind, so the reader can see what the ranking is built from.
        for kind in DiagnosticReportIndex.Kind.allCases where kind.implicatesEnergy {
            let count = index.count(of: kind)
            guard count > 0 else { continue }
            metrics.append(.reading("kind.\(kind.rawValue)", kind.rawValue,
                                    .int(Int64(count))))
        }

        guard !offenders.isEmpty else {
            metrics.append(.reading("verdict", "Offenders found", .int(0)))
            return result(.pass,
                "No process has exceeded a resource limit in the last 14 days",
                metrics: metrics)
        }

        // Open the worst CPU reports for the actual numbers. CPU exhaustion is
        // the only kind that states a measurable energy cost.
        var cpuDetails: [String: (seconds: Double, percent: Double, when: Date?, samples: Int)] = [:]
        let worstCPU = index.recent(.cpuResource, limit: detailLimit)
        for entry in worstCPU {
            if Task.isCancelled { break }
            guard let payload = try? await router.fetch(
                .crashLog(name: entry.path), for: device
            ), let text = payload.text.string,
               let report = ResourceReport.parse(text)
            else { continue }

            let existing = cpuDetails[report.process]
            let seconds = (existing?.seconds ?? 0) + (report.cpuSecondsUsed ?? 0)
            let percent = max(existing?.percent ?? 0, report.cpuAveragePercent ?? 0)
            cpuDetails[report.process] = (
                seconds, percent, report.date ?? entry.date, (existing?.samples ?? 0) + 1
            )
        }

        // Rank the offenders.
        for (rank, offender) in offenders.prefix(10).enumerated() {
            let key = "offender.\(rank)"
            var note = offender.breakdown
            if let detail = cpuDetails[offender.process], detail.seconds > 0 {
                // Be explicit that this totals only the reports we opened, not
                // every report the process has produced.
                let episodes = offender.counts[.cpuResource, default: 0]
                note += " — \(detail.seconds.zeroDecimal)s of CPU at up to "
                     + "\(detail.percent.zeroDecimal)% across \(detail.samples) of "
                     + "\(episodes) episodes examined"
            }
            if let when = offender.mostRecent {
                note += ", most recently \(when.formatted(date: .abbreviated, time: .shortened))"
            }

            // Only the leaders are graded; a single disk-writes report is noise.
            let verdict: Verdict = if offender.counts[.cpuResource, default: 0] >= 2 {
                .fail
            } else if offender.score >= 12 {
                .warn
            } else {
                .info
            }

            metrics.append(Metric(
                id: key, label: "#\(rank + 1)  \(offender.process)",
                value: .int(Int64(offender.total)), unit: "reports",
                verdict: verdict, note: note
            ))
        }

        // Say plainly what this does and does not establish.
        metrics.append(.reading("method", "How this is derived",
            .string("counts of iOS resource-limit reports, weighted by kind"),
            note: "evidence of misbehaviour, not a direct energy measurement — "
                + "Settings › Battery does the authoritative per-app attribution"))

        let verdict = rollup(metrics)
        let leader = offenders[0]
        let summary: String
        if leader.counts[.cpuResource, default: 0] >= 1 {
            let episodes = leader.counts[.cpuResource, default: 0]
            let cpuNote = cpuDetails[leader.process].map {
                ", \($0.percent.zeroDecimal)% CPU peak over \(episodes) episodes"
            } ?? ""
            summary = "\(leader.process) is the leading suspect\(cpuNote); "
                + "\(offenders.count) processes exceeded limits in 14 days"
        } else {
            summary = "\(leader.process) leads with \(leader.breakdown); "
                + "\(offenders.count) processes exceeded limits in 14 days"
        }
        return result(verdict, summary, metrics: metrics)
    }
}

/// Stability history: memory kills, panics, and crashes.
///
/// Complements the energy attribution — an app being killed for memory
/// repeatedly is both a stability problem and an energy one, because iOS
/// relaunches it and it does its startup work again.
public struct StabilityHistoryProbe: Probe {
    public let id = "stability.history"
    public let title = "Crash & Kill History"
    public let section = ReportSection.stability
    public let requiredCapabilities: Set<Capability> = [.crashLogs]

    public init() {}

    public func run(device: DeviceSnapshot, router: TransportRouter) async throws -> ProbeResult {
        let listing = try await router.fetch(.crashLogIndex, for: device)
        let index = DiagnosticReportIndex.parse(listing)

        guard !index.entries.isEmpty else {
            return result(.unsupported, "The device reported no diagnostic files")
        }

        let panics = index.count(of: .panic)
        let jetsams = index.count(of: .jetsam)
        let crashes = index.count(of: .crash)
        let stackshots = index.count(of: .stackshot)

        var metrics: [Metric] = [
            // A kernel panic is the one unambiguous hardware-or-driver signal here.
            .graded("panics", "Kernel panics", Double(panics),
                    warnAt: 1, failAt: 3, higherIsBetter: false,
                    note: panics > 0
                        ? "kernel panics point at a driver or hardware fault, not an app"
                        : nil,
                    expectation: "should be 0"),
            .reading("jetsams", "Memory kills", .int(Int64(jetsams)),
                     note: "processes terminated under memory pressure"),
            .reading("crashes", "Crash reports", .int(Int64(crashes))),
        ]
        if stackshots > 0 {
            metrics.append(.reading("stackshots", "Stackshots", .int(Int64(stackshots)),
                note: "system-wide samples, taken when the device was struggling"))
        }

        // Which apps crash most — a repeat offender is worth knowing about.
        var crashCounts: [String: Int] = [:]
        for entry in index.entries where entry.kind == .crash {
            crashCounts[entry.process, default: 0] += 1
        }
        let repeatOffenders = crashCounts.filter { $0.value >= 3 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        if !repeatOffenders.isEmpty {
            metrics.append(.reading("repeatCrashers", "Processes crashing repeatedly",
                .list(repeatOffenders.prefix(10).map { "\($0.key) (\($0.value))" })))
        }

        let verdict = rollup(metrics)
        let summary = panics > 0
            ? "\(panics) kernel panic\(panics == 1 ? "" : "s") recorded — investigate before anything else"
            : "No kernel panics; \(jetsams) memory kills and \(crashes) crash reports on file"
        return result(verdict, summary, metrics: metrics)
    }
}
