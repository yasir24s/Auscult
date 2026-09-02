import Foundation
import UIKit

/// What a test is handed so it can report progress and ask the user things.
struct AgentTestContext {
    /// Report progress; `fraction` is 0...1.
    let progress: (Double, String) -> Void
    /// Put a question on the device's screen and wait for the answer.
    /// Distinguishes a rejection from nobody answering at all.
    let askUser: (AgentServer.UserPrompt) async -> AgentServer.PromptAnswer
    /// Tell the host we are blocked waiting on the person holding the device,
    /// for interactions richer than a yes/no.
    let awaitingUser: (String) -> Void
}

/// One on-device hardware test.
protocol AgentTest {
    var descriptor: AgentTestDescriptor { get }
    func run(context: AgentTestContext) async throws -> AgentTestResult
}

extension AgentTest {
    func result(
        _ verdict: AgentVerdict, _ summary: String,
        metrics: [AgentMetric] = [], detail: String? = nil
    ) -> AgentTestResult {
        AgentTestResult(
            testID: descriptor.id, title: descriptor.title,
            section: descriptor.section, verdict: verdict,
            summary: summary, metrics: metrics, detail: detail
        )
    }

    /// Worst graded metric wins, matching the host's rollup rules so a result
    /// means the same thing on both sides of the link.
    func rollup(_ metrics: [AgentMetric]) -> AgentVerdict {
        let order: [AgentVerdict] = [.pass, .warn, .error, .fail]
        let graded = metrics.map(\.verdict).filter { order.contains($0) }
        return graded.max { a, b in
            (order.firstIndex(of: a) ?? 0) < (order.firstIndex(of: b) ?? 0)
        } ?? (metrics.isEmpty ? .unsupported : .info)
    }
}

/// Everything the agent can do on this device.
struct TestRegistry {
    private let tests: [AgentTest] = [
        AccelerometerTest(),
        GyroscopeTest(),
        MagnetometerTest(),
        BarometerTest(),
        DisplayTest(),
        CPUTest(),
        GPUTest(),
        ThermalTest(),
        StorageThroughputTest(),
        MemoryTest(),
        BiometricsTest(),
        PowerContextTest(),
        CameraTest(),
        AudioLoopbackTest(),
        BluetoothScanTest(),
        LocationFixTest(),
        DeadPixelSweepTest(),
        TouchGridTest(),
    ]

    func catalogue() -> [AgentTestDescriptor] { tests.map(\.descriptor) }

    func test(withID id: String) -> AgentTest? {
        tests.first { $0.descriptor.id == id }
    }
}

// MARK: - Metric helpers

extension AgentMetric {
    static func reading(
        _ id: String, _ label: String, _ value: String,
        unit: String? = nil, note: String? = nil
    ) -> AgentMetric {
        AgentMetric(id: id, label: label, kind: .string, raw: value,
                    unit: unit, verdict: .info, note: note)
    }

    static func number(
        _ id: String, _ label: String, _ value: Double,
        unit: String? = nil, note: String? = nil
    ) -> AgentMetric {
        AgentMetric(id: id, label: label, kind: .double, raw: String(value),
                    unit: unit, verdict: .info, note: note)
    }

    static func bytes(_ id: String, _ label: String, _ value: Int64, note: String? = nil) -> AgentMetric {
        AgentMetric(id: id, label: label, kind: .bytes, raw: String(value),
                    verdict: .info, note: note)
    }

    static func flag(
        _ id: String, _ label: String, _ value: Bool,
        shouldBe expected: Bool? = nil,
        severityIfNot: AgentVerdict = .warn,
        note: String? = nil
    ) -> AgentMetric {
        let verdict: AgentVerdict = if let expected {
            value == expected ? .pass : severityIfNot
        } else { .info }
        return AgentMetric(id: id, label: label, kind: .bool, raw: value ? "true" : "false",
                           verdict: verdict, note: note)
    }

    static func absent(_ id: String, _ label: String, why: String) -> AgentMetric {
        AgentMetric(id: id, label: label, kind: .absent, raw: "",
                    verdict: .unsupported, note: why)
    }

    static func list(_ id: String, _ label: String, _ values: [String], note: String? = nil) -> AgentMetric {
        AgentMetric(id: id, label: label, kind: .list,
                    raw: values.joined(separator: "\u{1F}"),
                    verdict: .info, note: note)
    }

    /// Grade a value against warn/fail thresholds.
    static func graded(
        _ id: String, _ label: String, _ value: Double,
        unit: String? = nil,
        warnAt warn: Double, failAt fail: Double,
        higherIsBetter: Bool,
        note: String? = nil, expectation: String? = nil
    ) -> AgentMetric {
        let verdict: AgentVerdict = if higherIsBetter {
            value <= fail ? .fail : (value <= warn ? .warn : .pass)
        } else {
            value >= fail ? .fail : (value >= warn ? .warn : .pass)
        }
        return AgentMetric(id: id, label: label, kind: .double, raw: String(value),
                           unit: unit, verdict: verdict, note: note,
                           expectation: expectation)
    }

    /// Grade a value that must sit inside a window — the usual shape for a
    /// sensor reading, where both too-low and too-high mean a fault.
    static func inRange(
        _ id: String, _ label: String, _ value: Double,
        expected range: ClosedRange<Double>,
        tolerance: Double = 0,
        unit: String? = nil, note: String? = nil
    ) -> AgentMetric {
        let wide = (range.lowerBound - tolerance)...(range.upperBound + tolerance)
        let verdict: AgentVerdict = range.contains(value)
            ? .pass : (wide.contains(value) ? .warn : .fail)
        return AgentMetric(
            id: id, label: label, kind: .double, raw: String(value),
            unit: unit, verdict: verdict, note: note,
            expectation: "\(range.lowerBound.clean)–\(range.upperBound.clean)\(unit.map { " \($0)" } ?? "")"
        )
    }
}

extension Double {
    /// Human-readable, without collapsing small magnitudes to "0".
    ///
    /// Sensor noise floors are legitimately of order 1e-4; formatting those to
    /// two decimal places prints "0 g", which reads as a frozen sensor when the
    /// sensor is in fact perfect.
    var clean: String {
        // Int(inf) and Int(nan) are hard traps, and a benchmark that divides by
        // a zero elapsed time produces exactly those. Never let a formatter be
        // the thing that crashes the agent.
        guard isFinite else { return isNaN ? "not a number" : (self > 0 ? "∞" : "-∞") }
        if self == rounded() { return String(Int(self)) }
        let magnitude = Swift.abs(self)
        if magnitude < 0.001 { return String(format: "%.5f", self) }
        if magnitude < 0.1 { return String(format: "%.4f", self) }
        return String(format: "%.2f", self)
    }
}

// MARK: - Device facts

enum DeviceFacts {
    /// The raw hardware identifier, e.g. "iPhone18,2".
    ///
    /// `UIDevice.model` only says "iPhone", so the machine string is read from
    /// sysctl. On a simulator that reports the host Mac, so the environment
    /// variable takes precedence there.
    static var machine: String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return sim
        }
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }

    static var osBuild: String? {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("kern.osversion", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    static func sysctlInt(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
