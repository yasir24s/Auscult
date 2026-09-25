import Foundation

// MARK: - Battery health

/// Judges battery health from the figures Settings shows.
///
/// iOS gives apps no battery-health API — only charge level and charging
/// state — and the private channels Settings uses are off limits to an App
/// Store app. So the person reads Maximum Capacity (and, on iPhone 15 and
/// later, Cycle Count) from Settings, and this test does what Settings does
/// not: judges them against what Apple designs *this model's* battery to
/// reach, and explains the result in plain words. The Mac reads the same
/// battery directly over USB, and explains it with the same `BatteryGuide`.
struct BatteryHealthTest: AgentTest {
    var descriptor: AgentTestDescriptor {
        // On a Mac the model is the fake iPad macOS reports, so it would send
        // people to iPad Settings for a Mac battery.
        AgentTestDescriptor(id: "battery.health", title: "Battery Health",
                            section: "Power & Battery", requiresInteraction: true,
                            estimatedSeconds: 60,
                            unavailableReason: DeviceFacts.isiOSAppOnMac
                                ? "this is a Mac — its battery health is in System Settings › Battery"
                                : nil)
    }

    func run(context: AgentTestContext) async throws -> AgentTestResult {
        let model = DeviceFacts.marketingName
        let rating = BatteryGuide.rating(forModelName: model)

        context.progress(0.1, "Waiting for the figures from Settings")
        context.awaitingUser("Enter Maximum Capacity from "
            + "\(rating?.settingsPath ?? "Settings › Battery") on the device")

        let entry = await InteractionCoordinator.shared.runBatteryForm(
            BatteryForm(modelName: model ?? DeviceFacts.machine, rating: rating))
        try Task.checkCancellation()
        guard let entry else {
            return result(.skipped, "No battery figures entered")
        }

        let a = BatteryGuide.assess(capacity: Double(entry.capacity),
                                    cycles: entry.cycles, rating: rating)

        var metrics: [AgentMetric] = [
            AgentMetric(id: "capacity", label: "Maximum capacity", kind: .double,
                        raw: String(entry.capacity), unit: "%", verdict: a.verdict,
                        note: a.meaning, expectation: "80% or more is within Apple's design"),
            .reading("condition", "Condition", a.condition),
        ]
        if let cycles = entry.cycles {
            metrics.append(.number("cycles", "Cycle count", Double(cycles), note: a.cycles))
        }
        if let pace = a.paceShort {
            metrics.append(.reading("pace", "Wear pace", pace, note: a.pace))
        }
        if let rating {
            metrics.append(.reading("design", "Apple's design",
                                    "80% after \(rating.ratedCycles) cycles",
                                    note: "for \(model ?? "this model")"))
        }
        // Say where the figures came from: they were typed, not measured, and
        // the result should never pass for more than it is.
        metrics.append(.reading("source", "Figures from", "Settings, entered by hand",
                                note: "iOS doesn't let apps read battery health; Auscult for Mac "
                                    + "reads it directly over USB"))

        var summary = "\(entry.capacity)% — \(a.condition)"
        if let cycles = entry.cycles { summary += ", \(cycles) cycles" }
        if entry.cycles != nil, let pace = a.paceShort {
            // Lower-case only the first letter to fit mid-sentence: lowercasing
            // the whole phrase printed "apple's design".
            summary += ", " + pace.prefix(1).lowercased() + pace.dropFirst()
        }
        return result(rollup(metrics), summary, metrics: metrics)
    }
}
