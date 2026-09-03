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

// MARK: - Paired accessories

/// Diagnostics forwarded from paired accessories, chiefly an Apple Watch.
///
/// A Watch has no direct link to a Mac — it pairs to a phone, and forwards its
/// crash and resource reports through it. Those land in the phone's crash-log
/// directory under `ProxiedDevice-<id>/`, which means a useful slice of Watch
/// health is reachable from the host without the Watch being paired to Xcode at
/// all.
///
/// It is a slice, not a full diagnostic: there is no battery gauge, no
/// IORegistry and no on-device agent for the accessory. What it does give is
/// crash and resource-exhaustion history, which is exactly what identifies an
/// app misbehaving on the wrist.
public struct AccessoryHealthProbe: Probe {
    public let id = "accessory.health"
    public let title = "Paired Accessory Health"
    public let section = ReportSection.stability
    public let requiredCapabilities: Set<Capability> = [.crashLogs]

    public init() {}

    public func run(device: DeviceSnapshot, router: TransportRouter) async throws -> ProbeResult {
        let listing = try await router.fetch(.crashLogIndex, for: device)
        let index = DiagnosticReportIndex.parse(listing)
        let accessories = index.accessories

        guard !accessories.isEmpty else {
            return result(.info, "No paired accessory has forwarded diagnostics")
        }

        var metrics: [Metric] = [
            .reading("accessoryCount", "Accessories forwarding reports",
                     .int(Int64(accessories.count))),
        ]
        var worstVerdict = Verdict.info

        for accessoryID in accessories {
            let origin = DiagnosticReportIndex.Origin.accessory(id: accessoryID)
            let reports = index.entries(from: origin)
            // Several proxy entries are placeholders with nothing in them.
            guard reports.count > 4 else { continue }

            let short = String(accessoryID.prefix(12))
            let crashes = index.count(of: .crash, origin: origin)
            let kills = index.count(of: .jetsam, origin: origin)

            metrics.append(.reading("acc.\(short).reports", "Accessory \(short) — reports",
                                    .int(Int64(reports.count))))

            // Which process dominates? On a Watch this is almost always one
            // misbehaving app, and it is worth naming.
            var counts: [String: Int] = [:]
            for report in reports where report.kind == .crash {
                guard !report.process.hasPrefix("Analytics") else { continue }
                counts[report.process, default: 0] += 1
            }
            let worst = counts.max { $0.value < $1.value }

            // Sample the worst offender's own report. The header carries the
            // accessory's model and OS; the body carries the termination reason
            // — and it must be *that app's* reason, not whichever report
            // happened to be first.
            let sampleEntry = reports.first {
                $0.kind == .crash && $0.process == (worst?.key ?? "")
            } ?? reports.first { $0.kind == .crash && !$0.process.hasPrefix("Analytics") }

            if let sample = sampleEntry,
               let payload = try? await router.fetch(.crashLog(name: sample.path), for: device),
               let text = payload.text.string,
               let summary = CrashReportSummary.parse(text) {
                if let model = summary.modelCode {
                    metrics.append(.reading("acc.\(short).model", "Accessory \(short) — hardware",
                                            .string(AccessoryNames.describe(model)),
                                            note: model))
                }
                if let train = summary.osTrain {
                    metrics.append(.reading("acc.\(short).os", "Accessory \(short) — system",
                        .string(train + (summary.osBuild.map { " (\($0))" } ?? ""))))
                }
                if let reason = summary.reasonSummary {
                    metrics.append(Metric(
                        id: "acc.\(short).reason",
                        label: "Accessory \(short) — why \(summary.process) fails",
                        value: .string(reason),
                        verdict: .info,
                        note: [
                            summary.terminationNamespace.map { "terminated by \($0)" },
                            summary.appVersion.map { "app version \($0)" },
                        ].compactMap { $0 }.joined(separator: ", ")
                    ))
                }
            }

            // A daily rate, not just a total. A count only ever grows, so it
            // cannot show whether a fix worked; the rate can, and the most
            // recent crash says whether the problem is still live.
            if let (name, _) = worst {
                let crashDates = reports
                    .filter { $0.kind == .crash && $0.process == name }
                    .compactMap(\.date)
                    .sorted()
                if let earliest = crashDates.first, let latest = crashDates.last {
                    let days = max(latest.timeIntervalSince(earliest) / 86400, 1)
                    let perDay = Double(crashDates.count) / days
                    metrics.append(.graded(
                        "acc.\(short).crashRate", "Accessory \(short) — \(name) crash rate",
                        perDay, unit: "/day",
                        warnAt: 1, failAt: 5, higherIsBetter: false,
                        note: "over \(Int(days)) days. Re-run after reinstalling the app: "
                            + "the rate is what shows whether it worked, since the total "
                            + "can only ever climb",
                        expectation: "0 for a healthy app"
                    ))
                    let sinceLast = Date().timeIntervalSince(latest) / 3600
                    metrics.append(.reading(
                        "acc.\(short).lastCrash", "Accessory \(short) — most recent crash",
                        .string(latest.formatted(date: .abbreviated, time: .shortened)),
                        note: sinceLast > 24
                            ? "none in \(Int(sinceLast / 24)) days — the problem may be resolved"
                            : "\(Int(sinceLast))h ago, so the problem is still live"))
                }
            }

            if let (name, count) = worst, count >= 5 {
                // A repeatedly crashing app costs battery on the accessory:
                // every relaunch repeats its startup work on a very small cell.
                let verdict: Verdict = count >= 25 ? .fail : .warn
                worstVerdict = max(worstVerdict, verdict)
                metrics.append(Metric(
                    id: "acc.\(short).worst", label: "Accessory \(short) — worst offender",
                    value: .string("\(name) — \(count) crashes"),
                    verdict: verdict,
                    note: "a repeatedly crashing app drains an accessory's battery, "
                        + "because each relaunch repeats its startup work. "
                        + "Reinstalling it on the accessory usually clears this"
                ))
            }

            if kills > 0 {
                metrics.append(.reading("acc.\(short).kills", "Accessory \(short) — memory kills",
                                        .int(Int64(kills))))
            }
            if crashes > 0, counts.count > 1 {
                // Grouped by process, with the report kinds nested underneath.
                var kindsByProcess: [String: [String: Int]] = [:]
                for entry in reports {
                    kindsByProcess[entry.process, default: [:]][entry.kind.rawValue, default: 0] += 1
                }
                let groups: [MetricGroup] = counts
                    .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                    .prefix(8)
                    .map { process, total in
                        MetricGroup(
                            owner: process,
                            summary: "\(total) report\(total == 1 ? "" : "s")",
                            entries: (kindsByProcess[process] ?? [:])
                                .sorted { $0.value > $1.value }
                                .map { "\($0.value) × \($0.key.lowercased())" }
                        )
                    }
                metrics.append(.reading("acc.\(short).processes",
                    "Accessory \(short) — processes reporting", .grouped(groups),
                    note: "expand a process to see what kinds of report it produced"))
            }
        }

        metrics.append(.absent("accessoryDeep", "Accessory battery & sensors",
            why: "an accessory forwards reports but exposes no gauge or agent — "
               + "pair it to Xcode over Wi-Fi for direct probing"))

        return result(worstVerdict,
                      "\(accessories.count) paired accessory(ies) forwarding diagnostics",
                      metrics: metrics)
    }
}
