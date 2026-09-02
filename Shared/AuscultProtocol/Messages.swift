import Foundation

// MARK: - Host → Agent

public enum AgentRequest: Codable, Sendable {
    /// Handshake. The agent replies with its identity and test catalogue.
    case hello(hostVersion: String, protocolVersion: Int)
    /// Re-query the catalogue (permissions may have changed since hello).
    case listTests
    /// Run one test. `parameters` is test-specific and always optional.
    case runTest(id: String, parameters: [String: String])
    /// Ask the agent to abandon the running test.
    case cancelTest
    /// Close down cleanly.
    case goodbye
}

// MARK: - Agent → Host

public enum AgentResponse: Codable, Sendable {
    case hello(AgentIdentity)
    case tests([AgentTestDescriptor])
    case progress(AgentProgress)
    case result(AgentTestResult)
    case failure(AgentFailure)
    case bye
}

public struct AgentIdentity: Codable, Sendable {
    public var agentVersion: String
    public var protocolVersion: Int
    public var deviceModel: String        // raw identifier, e.g. "iPhone18,2"
    public var deviceName: String
    public var osName: String
    public var osVersion: String
    public var osBuild: String?
    public var isSimulator: Bool
    public var tests: [AgentTestDescriptor]

    public init(
        agentVersion: String, protocolVersion: Int, deviceModel: String,
        deviceName: String, osName: String, osVersion: String, osBuild: String?,
        isSimulator: Bool, tests: [AgentTestDescriptor]
    ) {
        self.agentVersion = agentVersion; self.protocolVersion = protocolVersion
        self.deviceModel = deviceModel; self.deviceName = deviceName
        self.osName = osName; self.osVersion = osVersion; self.osBuild = osBuild
        self.isSimulator = isSimulator; self.tests = tests
    }
}

/// What a test is, and what it needs before it can run.
public struct AgentTestDescriptor: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    /// Maps onto the host's `ReportSection` raw value.
    public var section: String
    /// Needs a human to look at the screen or touch it.
    public var requiresInteraction: Bool
    /// Present and unauthorised means the agent must prompt first.
    public var permission: AgentPermission?
    /// Authorisation state of `permission`, as of this catalogue.
    public var permissionGranted: Bool
    /// Rough duration, so the host can show sensible progress.
    public var estimatedSeconds: Double
    /// Why this test can't run right now, if it can't.
    public var unavailableReason: String?

    public var isRunnable: Bool { unavailableReason == nil }

    public init(
        id: String, title: String, section: String,
        requiresInteraction: Bool = false,
        permission: AgentPermission? = nil,
        permissionGranted: Bool = true,
        estimatedSeconds: Double = 1,
        unavailableReason: String? = nil
    ) {
        self.id = id; self.title = title; self.section = section
        self.requiresInteraction = requiresInteraction
        self.permission = permission; self.permissionGranted = permissionGranted
        self.estimatedSeconds = estimatedSeconds
        self.unavailableReason = unavailableReason
    }
}

public enum AgentPermission: String, Codable, Sendable {
    case camera, microphone, location, bluetooth, motion, photos
}

public struct AgentProgress: Codable, Sendable {
    public var testID: String
    public var fraction: Double
    public var message: String
    /// Set when the agent is waiting for the user to do something on-device.
    public var awaitingUser: Bool

    public init(testID: String, fraction: Double, message: String, awaitingUser: Bool = false) {
        self.testID = testID; self.fraction = fraction
        self.message = message; self.awaitingUser = awaitingUser
    }
}

/// Mirrors the host's `Verdict` so results map across without interpretation.
public enum AgentVerdict: String, Codable, Sendable {
    case pass, warn, fail, info, unsupported, skipped, error
}

/// Mirrors the host's `Metric`. Values are carried as strings plus a type tag
/// so the wire format stays stable even as the host's `MetricValue` evolves.
public struct AgentMetric: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case string, int, double, bool, bytes, list, absent
    }

    public var id: String
    public var label: String
    public var kind: Kind
    public var raw: String
    public var unit: String?
    public var verdict: AgentVerdict
    public var note: String?
    public var expectation: String?

    public init(
        id: String, label: String, kind: Kind, raw: String, unit: String? = nil,
        verdict: AgentVerdict = .info, note: String? = nil, expectation: String? = nil
    ) {
        self.id = id; self.label = label; self.kind = kind; self.raw = raw
        self.unit = unit; self.verdict = verdict; self.note = note
        self.expectation = expectation
    }
}

public struct AgentTestResult: Codable, Sendable {
    public var testID: String
    public var title: String
    public var section: String
    public var verdict: AgentVerdict
    public var summary: String
    public var metrics: [AgentMetric]
    public var detail: String?
    public var duration: Double

    public init(
        testID: String, title: String, section: String, verdict: AgentVerdict,
        summary: String, metrics: [AgentMetric] = [], detail: String? = nil,
        duration: Double = 0
    ) {
        self.testID = testID; self.title = title; self.section = section
        self.verdict = verdict; self.summary = summary; self.metrics = metrics
        self.detail = detail; self.duration = duration
    }
}

public struct AgentFailure: Codable, Sendable {
    public var testID: String?
    public var message: String
    public var isFatal: Bool

    public init(testID: String? = nil, message: String, isFatal: Bool = false) {
        self.testID = testID; self.message = message; self.isFatal = isFatal
    }
}
