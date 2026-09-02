import Foundation

/// Outcome of a single probe or metric.
public enum Verdict: String, Codable, Sendable, Comparable {
    /// Measured and within expectation.
    case pass
    /// Measured, outside ideal but not a defect.
    case warn
    /// Measured and indicates a real fault.
    case fail
    /// Measured, no pass/fail semantics (informational reading).
    case info
    /// Could not run: the device or OS did not expose it.
    case unsupported
    /// Could not run: a precondition wasn't met (locked, no agent, offline).
    case skipped
    /// Tried and blew up. Distinct from `unsupported` — this is our bug or a
    /// protocol change, and is what tells us a new beta moved something.
    case error

    private var severity: Int {
        switch self {
        case .pass: 0; case .info: 1; case .unsupported: 2
        case .skipped: 3; case .warn: 4; case .error: 5; case .fail: 6
        }
    }

    public static func < (a: Verdict, b: Verdict) -> Bool { a.severity < b.severity }

    /// Did this outcome actually measure something?
    ///
    /// `unsupported` and `skipped` describe *coverage* — what we couldn't
    /// reach — not device health. Keeping the distinction in one place stops
    /// the two from being conflated when verdicts are rolled up.
    public var isGraded: Bool {
        switch self {
        case .pass, .warn, .fail, .error: true
        case .info, .unsupported, .skipped: false
        }
    }

    public var symbol: String {
        switch self {
        case .pass: "✓"; case .warn: "!"; case .fail: "✗"; case .info: "·"
        case .unsupported: "–"; case .skipped: "◦"; case .error: "⚠"
        }
    }
}

/// A single measured value.
public struct Metric: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var label: String
    public var value: MetricValue
    public var unit: String?
    public var verdict: Verdict
    /// Why this verdict — shown next to the value.
    public var note: String?
    /// Human-readable expected range, for report context.
    public var expectation: String?

    public init(
        id: String,
        label: String,
        value: MetricValue,
        unit: String? = nil,
        verdict: Verdict = .info,
        note: String? = nil,
        expectation: String? = nil
    ) {
        self.id = id; self.label = label; self.value = value; self.unit = unit
        self.verdict = verdict; self.note = note; self.expectation = expectation
    }

    public var formattedValue: String {
        let base = value.description
        guard let unit else { return base }
        return "\(base)\(unit.hasPrefix("%") || unit.hasPrefix("°") ? "" : " ")\(unit)"
    }
}

/// Type-preserving metric payload, so JSON reports stay machine-usable.
public enum MetricValue: Codable, Sendable, Hashable, CustomStringConvertible {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case bytes(Int64)
    case list([String])
    case absent

    public var description: String {
        switch self {
        case .string(let s): s
        case .int(let i): i.formatted(.number)
        case .double(let d): Self.formatDouble(d)
        case .bool(let b): b ? "yes" : "no"
        case .bytes(let b): ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
        case .list(let l): l.isEmpty ? "none" : l.joined(separator: ", ")
        case .absent: "—"
        }
    }

    /// Format without collapsing small magnitudes to "0" — a sensor noise
    /// floor of 4e-4 must not print as zero, which would read as a dead sensor.
    static func formatDouble(_ d: Double) -> String {
        // `Int(_:)` traps on infinity and NaN, so guard before converting.
        guard d.isFinite else { return d.isNaN ? "not a number" : (d > 0 ? "∞" : "-∞") }
        if d == d.rounded() { return String(Int(d)) }
        let magnitude = abs(d)
        if magnitude < 0.001 { return String(format: "%.5f", d) }
        if magnitude < 0.1 { return String(format: "%.4f", d) }
        return d.formatted(.number.precision(.fractionLength(0...2)))
    }

    // Compact single-key encoding keeps the JSON readable by other tools.
    private enum CodingKeys: String, CodingKey { case type, value }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let v): try c.encode("string", forKey: .type); try c.encode(v, forKey: .value)
        case .int(let v): try c.encode("int", forKey: .type); try c.encode(v, forKey: .value)
        case .double(let v): try c.encode("double", forKey: .type); try c.encode(v, forKey: .value)
        case .bool(let v): try c.encode("bool", forKey: .type); try c.encode(v, forKey: .value)
        case .bytes(let v): try c.encode("bytes", forKey: .type); try c.encode(v, forKey: .value)
        case .list(let v): try c.encode("list", forKey: .type); try c.encode(v, forKey: .value)
        case .absent: try c.encode("absent", forKey: .type)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "string": self = .string(try c.decode(String.self, forKey: .value))
        case "int": self = .int(try c.decode(Int64.self, forKey: .value))
        case "double": self = .double(try c.decode(Double.self, forKey: .value))
        case "bool": self = .bool(try c.decode(Bool.self, forKey: .value))
        case "bytes": self = .bytes(try c.decode(Int64.self, forKey: .value))
        case "list": self = .list(try c.decode([String].self, forKey: .value))
        default: self = .absent
        }
    }
}

/// Result of running one probe against one device.
public struct ProbeResult: Codable, Sendable, Identifiable {
    public var id: String { probeID }
    public var probeID: String
    public var title: String
    public var section: ReportSection
    public var verdict: Verdict
    public var summary: String
    public var metrics: [Metric]
    /// Which transport actually served this probe, for provenance.
    public var servedBy: String?
    public var duration: TimeInterval
    /// Populated when `verdict == .error` — the raw failure, kept for triage.
    public var diagnosticDetail: String?

    public init(
        probeID: String,
        title: String,
        section: ReportSection,
        verdict: Verdict,
        summary: String,
        metrics: [Metric] = [],
        servedBy: String? = nil,
        duration: TimeInterval = 0,
        diagnosticDetail: String? = nil
    ) {
        self.probeID = probeID; self.title = title; self.section = section
        self.verdict = verdict; self.summary = summary; self.metrics = metrics
        self.servedBy = servedBy; self.duration = duration
        self.diagnosticDetail = diagnosticDetail
    }
}

public enum ReportSection: String, Codable, Sendable, CaseIterable {
    case identity   = "Identity"
    case software   = "Software"
    case security   = "Security"
    case power      = "Power & Battery"
    case thermal    = "Thermal"
    case storage    = "Storage"
    case display    = "Display"
    case sensors    = "Sensors"
    case audio      = "Audio"
    case cameras    = "Cameras"
    case radios     = "Radios"
    case stability  = "Stability"
    case compute    = "Compute"

    public var order: Int { Self.allCases.firstIndex(of: self) ?? 99 }
}

/// A complete diagnostic run.
public struct DiagnosticReport: Codable, Sendable, Identifiable {
    public var id: UUID = UUID()
    public var device: DeviceSnapshot
    public var startedAt: Date
    public var finishedAt: Date
    public var results: [ProbeResult]
    /// Capabilities the router established for this device, for provenance.
    public var capabilities: [String]
    public var hostInfo: HostInfo

    /// The headline verdict.
    ///
    /// Driven only by probes that actually graded something. Checks that were
    /// skipped or unsupported are reported separately, under "not measured" —
    /// they describe coverage, not device health, and a device shouldn't be
    /// labelled faulty because we couldn't reach one subsystem.
    public var overallVerdict: Verdict {
        results.map(\.verdict).filter(\.isGraded).max() ?? .info
    }

    /// Checks that produced no measurement, for the coverage section.
    public var unmeasured: [ProbeResult] {
        results.filter { $0.verdict == .unsupported || $0.verdict == .skipped }
    }

    public var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }

    public func results(in section: ReportSection) -> [ProbeResult] {
        results.filter { $0.section == section }
    }

    public var populatedSections: [ReportSection] {
        ReportSection.allCases.filter { s in results.contains { $0.section == s } }
    }

    public init(
        device: DeviceSnapshot, startedAt: Date, finishedAt: Date,
        results: [ProbeResult], capabilities: [String], hostInfo: HostInfo
    ) {
        self.device = device; self.startedAt = startedAt; self.finishedAt = finishedAt
        self.results = results; self.capabilities = capabilities; self.hostInfo = hostInfo
    }
}

public struct HostInfo: Codable, Sendable {
    public var macOSVersion: String
    public var xcodeVersion: String?
    public var devicectlVersion: String?
    public var cfgutilVersion: String?
    public var auscultVersion: String

    public init(
        macOSVersion: String, xcodeVersion: String?, devicectlVersion: String?,
        cfgutilVersion: String?, auscultVersion: String
    ) {
        self.macOSVersion = macOSVersion; self.xcodeVersion = xcodeVersion
        self.devicectlVersion = devicectlVersion; self.cfgutilVersion = cfgutilVersion
        self.auscultVersion = auscultVersion
    }
}
