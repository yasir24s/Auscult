import Foundation

/// One diagnostic check.
///
/// A probe declares the capabilities it needs and is handed a router that can
/// satisfy them. It never learns which transport served it, and it never checks
/// an OS version — if the data is reachable the probe runs, and if it isn't the
/// engine reports `unsupported` with the missing capability named.
public protocol Probe: Sendable {
    var id: String { get }
    var title: String { get }
    var section: ReportSection { get }

    /// Without all of these the probe cannot run at all.
    var requiredCapabilities: Set<Capability> { get }
    /// At least one of these must exist. Use when several transports can
    /// answer the same question and any one of them is enough.
    var anyCapabilities: Set<Capability> { get }
    /// Nice to have; the probe degrades gracefully without them.
    var optionalCapabilities: Set<Capability> { get }

    /// Device families this check is meaningful for. Empty means all.
    var applicableFamilies: Set<DeviceFamily> { get }
    /// Simulators can answer software questions but never hardware ones.
    var appliesToSimulators: Bool { get }

    func run(device: DeviceSnapshot, router: TransportRouter) async throws -> ProbeResult
}

public extension Probe {
    var anyCapabilities: Set<Capability> { [] }
    var optionalCapabilities: Set<Capability> { [] }

    /// Everything this probe might touch, for provenance lookup.
    var allCapabilities: [Capability] {
        Array(requiredCapabilities) + Array(anyCapabilities) + Array(optionalCapabilities)
    }
    var applicableFamilies: Set<DeviceFamily> { [] }
    var appliesToSimulators: Bool { false }

    /// Build a result already tagged with this probe's identity.
    func result(
        _ verdict: Verdict,
        _ summary: String,
        metrics: [Metric] = [],
        servedBy: String? = nil,
        detail: String? = nil
    ) -> ProbeResult {
        ProbeResult(
            probeID: id, title: title, section: section, verdict: verdict,
            summary: summary, metrics: metrics, servedBy: servedBy,
            diagnosticDetail: detail
        )
    }

    /// Roll a set of metrics up into the probe's own verdict.
    ///
    /// Only graded outcomes count. A probe that measured six things
    /// successfully and noted a seventh as "needs the on-device agent" is a
    /// passing probe — letting that placeholder dominate would mark healthy
    /// hardware as unmeasured, and would propagate up to the whole report.
    func rollup(_ metrics: [Metric]) -> Verdict {
        if let worst = metrics.map(\.verdict).filter(\.isGraded).max() { return worst }
        return metrics.isEmpty ? .unsupported : .info
    }
}

// MARK: - Metric construction helpers

public extension Metric {
    /// A plain reading with no pass/fail meaning.
    static func reading(
        _ id: String, _ label: String, _ value: MetricValue,
        unit: String? = nil, note: String? = nil
    ) -> Metric {
        Metric(id: id, label: label, value: value, unit: unit, verdict: .info, note: note)
    }

    /// A reading that's missing because the device didn't expose it.
    static func absent(_ id: String, _ label: String, why: String) -> Metric {
        Metric(id: id, label: label, value: .absent, verdict: .unsupported, note: why)
    }

    /// Grade a number against warn/fail thresholds.
    /// `higherIsBetter` flips the comparison for things like battery health.
    static func graded(
        _ id: String, _ label: String, _ value: Double,
        unit: String? = nil,
        warnAt warn: Double, failAt fail: Double,
        higherIsBetter: Bool,
        note: String? = nil,
        expectation: String? = nil
    ) -> Metric {
        let verdict: Verdict = if higherIsBetter {
            value <= fail ? .fail : (value <= warn ? .warn : .pass)
        } else {
            value >= fail ? .fail : (value >= warn ? .warn : .pass)
        }
        return Metric(
            id: id, label: label, value: .double(value), unit: unit,
            verdict: verdict, note: note,
            expectation: expectation ?? (higherIsBetter
                ? "warn ≤ \(warn.clean)\(unit ?? ""), fail ≤ \(fail.clean)\(unit ?? "")"
                : "warn ≥ \(warn.clean)\(unit ?? ""), fail ≥ \(fail.clean)\(unit ?? "")")
        )
    }

    /// Grade a boolean where one value is the healthy one.
    static func expected(
        _ id: String, _ label: String, _ value: Bool,
        shouldBe expected: Bool,
        severityIfNot: Verdict = .warn,
        note: String? = nil
    ) -> Metric {
        Metric(
            id: id, label: label, value: .bool(value),
            verdict: value == expected ? .pass : severityIfNot, note: note
        )
    }
}

extension Double {
    /// Trim trailing zeros for threshold text.
    var clean: String {
        self == rounded() ? String(Int(self)) : String(format: "%.1f", self)
    }
}
