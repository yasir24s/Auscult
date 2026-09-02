import Foundation

/// What the device was doing each time the battery ran flat.
///
/// When iOS shuts down for low battery it writes a report recording the
/// awake/standby split, the foreground app, and every power assertion held at
/// that moment. Read across several such events, it answers the drain question
/// far more directly than any measurement the host can take: it says how much
/// of the time the device was awake at all, and names the subsystems that kept
/// it that way.
///
/// The awake share is the figure that matters. Consumption follows from it
/// almost mechanically — a phone that is awake 40% of the time cannot last a
/// day whatever its battery health, because the display alone costs a couple of
/// watts whenever it is lit.
public struct BatteryDeathProbe: Probe {
    public let id = "power.deaths"
    public let title = "Battery Exhaustion Events"
    public let section = ReportSection.power
    public let requiredCapabilities: Set<Capability> = [.crashLogs]
    public var applicableFamilies: Set<DeviceFamily> { [.iPhone, .iPad, .iPod] }

    /// How many recent events to open. Enough to distinguish a pattern from a
    /// one-off without a dozen file copies.
    private let eventLimit = 4

    public init() {}

    public func run(device: DeviceSnapshot, router: TransportRouter) async throws -> ProbeResult {
        let listing = try await router.fetch(.crashLogIndex, for: device)
        let index = DiagnosticReportIndex.parse(listing)
        let events = index.recent(.lowBattery, limit: eventLimit)

        guard !events.isEmpty else {
            return result(.pass, "No record of the battery running flat",
                          metrics: [.reading("events", "Exhaustion events", .int(0))])
        }

        var reports: [(entry: DiagnosticReportIndex.Entry, report: LowBatteryLogReport)] = []
        for entry in events {
            if Task.isCancelled { break }
            guard let payload = try? await router.fetch(.crashLog(name: entry.path), for: device),
                  let text = payload.text.string,
                  let report = LowBatteryLogReport.parse(text)
            else { continue }
            reports.append((entry, report))
        }

        guard !reports.isEmpty else {
            return result(.unsupported,
                "\(events.count) exhaustion event(s) on file but none could be read")
        }

        var metrics: [Metric] = []

        // How often is this happening?
        let total = index.count(of: .lowBattery)
        let span = reports.compactMap { $0.report.date ?? $0.entry.date }
        if let newest = span.max(), let oldest = span.min(), newest > oldest {
            let days = newest.timeIntervalSince(oldest) / 86400
            metrics.append(.graded(
                "frequency", "Times the battery ran flat", Double(reports.count),
                unit: "in \(days.oneDecimal) days",
                warnAt: 2, failAt: 3, higherIsBetter: false,
                note: "the device shut itself down for lack of charge",
                expectation: "should be rare"
            ))
        } else {
            metrics.append(.reading("events", "Exhaustion events", .int(Int64(total))))
        }

        // The headline: how much of the time is the device awake?
        let awakeShares = reports.compactMap { $0.report.awakePercent }
        if !awakeShares.isEmpty {
            let mean = awakeShares.reduce(0, +) / Double(awakeShares.count)
            metrics.append(.graded(
                "awakeShare", "Time awake rather than asleep", mean, unit: "%",
                warnAt: 25, failAt: 35, higherIsBetter: false,
                note: "averaged across \(awakeShares.count) exhaustion events — "
                    + "this is the dominant factor in battery life",
                expectation: "a lightly-used phone sits under 15%"
            ))
        }

        // Longest continuous screen-on stretch: the most expensive assertion.
        let backlightStretches = reports.compactMap { $0.report.longestBacklightSeconds }
        if let longest = backlightStretches.max() {
            metrics.append(.graded(
                "longestScreenOn", "Longest unbroken screen-on stretch",
                longest / 3600, unit: "h",
                warnAt: 1.5, failAt: 3, higherIsBetter: false,
                note: "the display draws 2–3 W whenever it is lit, so this is "
                    + "usually the largest single consumer",
                expectation: "under 1.5 h at a time"
            ))
        }

        // Which apps were in the foreground when the battery died?
        var foregroundCounts: [String: Int] = [:]
        for (_, report) in reports {
            for app in report.foregroundApps { foregroundCounts[app, default: 0] += 1 }
        }
        if !foregroundCounts.isEmpty {
            let ranked = foregroundCounts.sorted {
                $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
            }
            metrics.append(Metric(
                id: "foregroundAtDeath", label: "In the foreground when it died",
                value: .list(ranked.map { "\($0.key) (\($0.value)×)" }),
                verdict: ranked[0].value >= 2 ? .warn : .info,
                note: ranked[0].value >= 2
                    ? "\(ranked[0].key) was in front at \(ranked[0].value) of "
                      + "\(reports.count) exhaustion events"
                    : nil
            ))
        }

        // Aggregate the sleep-preventing assertions, excluding the display —
        // which is reported separately above because it dwarfs the rest.
        var assertionTotals: [String: Double] = [:]
        for (_, report) in reports {
            for assertion in report.assertions where !assertion.isBacklight {
                let key = "\(assertion.holder) — \(assertion.name)"
                assertionTotals[key] = (assertionTotals[key] ?? 0) + assertion.heldSeconds
            }
        }
        let topAssertions = assertionTotals
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(8)
        if !topAssertions.isEmpty {
            metrics.append(.reading("assertions", "Subsystems preventing sleep",
                .list(topAssertions.map { key, seconds in
                    "\(key.prefix(58)) — \(Self.clock(seconds))"
                }),
                note: "each of these kept the device from sleeping for the time shown"))
        }

        // Per-event detail, so the pattern is visible rather than averaged away.
        for (offset, pair) in reports.enumerated() {
            let when = (pair.report.date ?? pair.entry.date)
                .map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "unknown"
            var parts: [String] = []
            if let awake = pair.report.awakePercent {
                parts.append("\(awake.zeroDecimal)% awake")
            }
            if let screen = pair.report.longestBacklightSeconds {
                parts.append("screen on \(Self.clock(screen))")
            }
            if let app = pair.report.foregroundApps.first {
                parts.append("foreground \(app)")
            }
            if let brightness = pair.report.screenBrightness {
                parts.append("brightness \((brightness * 100).zeroDecimal)%")
            }
            metrics.append(.reading("event.\(offset)", when,
                                    .string(parts.joined(separator: ", "))))
        }

        let verdict = rollup(metrics)
        var summary = "Battery ran flat \(reports.count) time(s) on record"
        if let mean = awakeShares.isEmpty
            ? nil : awakeShares.reduce(0, +) / Double(awakeShares.count) {
            summary += "; awake \(mean.zeroDecimal)% of the time"
        }
        if let longest = backlightStretches.max() {
            summary += ", longest screen-on \(Self.clock(longest))"
        }
        return result(verdict, summary, metrics: metrics)
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        let hours = total / 3600, minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}
