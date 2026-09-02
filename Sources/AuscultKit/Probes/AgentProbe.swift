import Foundation
import AuscultProtocol

/// A host probe that delegates to one on-device agent test.
///
/// These are synthesised from the agent's own catalogue rather than written by
/// hand, so the agent decides what exists and the host just presents it. The
/// agent already returns graded metrics in the host's vocabulary, so there is
/// no interpretation here — only translation.
public struct AgentTestProbe: Probe {
    public let descriptor: AgentTestDescriptor
    private let transport: AgentTransport

    public init(descriptor: AgentTestDescriptor, transport: AgentTransport) {
        self.descriptor = descriptor
        self.transport = transport
    }

    public var id: String { "agent.\(descriptor.id)" }
    public var title: String { descriptor.title }
    public var section: ReportSection {
        ReportSection(rawValue: descriptor.section) ?? .sensors
    }
    public var requiredCapabilities: Set<Capability> { [.agentLink] }
    public var appliesToSimulators: Bool { false }

    public func run(device: DeviceSnapshot, router: TransportRouter) async throws -> ProbeResult {
        if let reason = descriptor.unavailableReason {
            return result(.unsupported, reason)
        }
        if let permission = descriptor.permission, !descriptor.permissionGranted {
            return result(.skipped,
                "needs \(permission.rawValue) access — grant it in the agent on the device, then re-run")
        }

        let agentResult = try await transport.runTest(descriptor.id, on: device) { _ in
            // Progress is surfaced by the app through its own observation of the
            // transport; nothing to do per-frame here.
        }
        return Self.map(agentResult, probeID: id, fallbackSection: section)
    }

    /// Translate an agent result into a host `ProbeResult`.
    static func map(
        _ r: AgentTestResult, probeID: String, fallbackSection: ReportSection
    ) -> ProbeResult {
        ProbeResult(
            probeID: probeID,
            title: r.title,
            section: ReportSection(rawValue: r.section) ?? fallbackSection,
            verdict: Verdict(r.verdict),
            summary: r.summary,
            metrics: r.metrics.map(Metric.init),
            servedBy: "On-device agent",
            duration: r.duration,
            diagnosticDetail: r.detail
        )
    }
}

// MARK: - Wire → model translation

public extension Verdict {
    init(_ agent: AgentVerdict) {
        self = switch agent {
        case .pass: .pass
        case .warn: .warn
        case .fail: .fail
        case .info: .info
        case .unsupported: .unsupported
        case .skipped: .skipped
        case .error: .error
        }
    }
}

public extension Metric {
    /// Rebuild a typed metric from the agent's string-plus-tag wire form.
    ///
    /// Values cross the link as strings so the protocol stays stable as the
    /// host's `MetricValue` grows; a tag that no longer parses degrades to a
    /// plain string rather than losing the reading.
    init(_ agent: AgentMetric) {
        let value: MetricValue = switch agent.kind {
        case .string: .string(agent.raw)
        case .int: Int64(agent.raw).map { MetricValue.int($0) } ?? .string(agent.raw)
        case .double: Double(agent.raw).map { MetricValue.double($0) } ?? .string(agent.raw)
        case .bool: .bool(agent.raw == "true")
        case .bytes: Int64(agent.raw).map { MetricValue.bytes($0) } ?? .string(agent.raw)
        case .list: .list(
            agent.raw.isEmpty ? []
                // Unit separator: safe inside human-readable list entries.
                : agent.raw.components(separatedBy: "\u{1F}")
        )
        case .absent: .absent
        }
        self.init(
            id: agent.id, label: agent.label, value: value, unit: agent.unit,
            verdict: Verdict(agent.verdict), note: agent.note,
            expectation: agent.expectation
        )
    }
}

// MARK: - Agent link status

/// Reports whether the agent is reachable, and says how to fix it if not.
///
/// Without this, a device with no agent installed would simply show a shorter
/// report, and the reader would have no way to tell "this hardware is fine"
/// from "nobody tested this hardware".
public struct AgentLinkProbe: Probe {
    public let id = "agent.link"
    public let title = "On-device Agent"
    public let section = ReportSection.identity
    public let requiredCapabilities: Set<Capability> = []

    private let transport: AgentTransport

    public init(transport: AgentTransport) { self.transport = transport }

    public func run(device: DeviceSnapshot, router: TransportRouter) async throws -> ProbeResult {
        guard let identity = await transport.identity(for: device) else {
            let reason = await transport.unavailableReason(for: device)
                ?? "the agent did not answer"
            return result(.skipped,
                "Not reachable — hardware tests are unavailable",
                metrics: [
                    .absent("agent", "Agent link", why: reason),
                    .reading("remedy", "To enable",
                             .string("install the Auscult Agent app, open it, and keep it in the foreground")),
                ])
        }

        let runnable = identity.tests.filter(\.isRunnable)
        let blocked = identity.tests.filter { !$0.isRunnable }

        var metrics: [Metric] = [
            .reading("agentVersion", "Agent version", .string(identity.agentVersion)),
            .reading("protocol", "Protocol", .string("v\(identity.protocolVersion)")),
            .reading("tests", "Tests available", .int(Int64(runnable.count))),
        ]

        // The device the agent reports must be the device we think we're
        // talking to; a mismatch means the tunnel landed somewhere unexpected.
        let expected = device.productType
        metrics.append(Metric(
            id: "identityMatch", label: "Reported model",
            value: .string(identity.deviceModel),
            verdict: expected == nil || expected == identity.deviceModel ? .pass : .fail,
            note: expected == nil || expected == identity.deviceModel
                ? nil : "the agent reports a different model than the host expected (\(expected!))"
        ))

        let interactive = runnable.filter(\.requiresInteraction)
        if !interactive.isEmpty {
            metrics.append(.reading("guided", "Guided tests",
                .list(interactive.map(\.title)),
                note: "these need someone to look at or touch the device"))
        }
        if !blocked.isEmpty {
            metrics.append(.reading("unavailable", "Unavailable on this device",
                .list(blocked.map { "\($0.title): \($0.unavailableReason ?? "unknown")" })))
        }

        return result(rollup(metrics),
                      "Agent \(identity.agentVersion) connected — \(runnable.count) tests available",
                      metrics: metrics)
    }
}
