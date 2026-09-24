import Foundation

// MARK: - Dead pixel sweep

/// Fills the display with each primary in turn and asks the person what they see.
///
/// This cannot be automated — there is no API that reports a stuck subpixel, and
/// the front camera can't see the screen. But it is also the single most
/// valuable display check, and a human eye on a flat primary is genuinely good
/// at it. The agent's job is to present the colours correctly (full brightness,
/// no status bar, no rounded-corner masking) and to record the answers
/// truthfully, including which colour failed.
struct DeadPixelSweepTest: AgentTest {
    var descriptor: AgentTestDescriptor {
        AgentTestDescriptor(
            id: "display.sweep", title: "Display Sweep (guided)",
            section: "Display", requiresInteraction: true,
            estimatedSeconds: 30
        )
    }

    func run(context: AgentTestContext) async throws -> AgentTestResult {
        let coordinator = InteractionCoordinator.shared
        var metrics: [AgentMetric] = []
        var failures: [String] = []
        var unanswered: [String] = []
        let sequence = SweepColour.allCases

        for (index, colour) in sequence.enumerated() {
            if Task.isCancelled {
                await MainActor.run { coordinator.hide() }
                throw CancellationError()
            }

            context.progress(
                Double(index) / Double(sequence.count),
                "Showing \(colour.rawValue)"
            )
            await MainActor.run {
                coordinator.showColour(colour, named: colour.rawValue)
            }
            // Let the panel settle before asking — on an OLED especially, the
            // first frame after a big luminance change is not representative.
            try? await Task.sleep(nanoseconds: 700_000_000)

            context.awaitingUser("Look at the device: is it \(colour.expectation)?")
            let answer = await context.askUser(UserPrompt(
                message: "Is the screen \(colour.expectation)?",
                confirmTitle: "Looks correct",
                rejectTitle: "I see a defect"
            ))

            switch answer {
            case .confirmed:
                metrics.append(.flag("sweep.\(colour.rawValue)",
                                     "\(colour.rawValue.capitalized) field", true,
                                     shouldBe: true))
            case .rejected:
                metrics.append(.flag("sweep.\(colour.rawValue)",
                                     "\(colour.rawValue.capitalized) field", false,
                                     shouldBe: true, severityIfNot: .fail,
                                     note: "the person inspecting reported a defect on \(colour.rawValue)"))
                failures.append(colour.rawValue)
            case .timedOut:
                // Nobody answered. That is missing coverage, not a defect.
                metrics.append(AgentMetric(
                    id: "sweep.\(colour.rawValue)",
                    label: "\(colour.rawValue.capitalized) field",
                    kind: .absent, raw: "", verdict: .skipped,
                    note: "nobody confirmed this colour field"
                ))
                unanswered.append(colour.rawValue)
                // No point showing the remaining colours to an empty room.
                await MainActor.run { coordinator.hide() }
                let summary = "Sweep abandoned — nobody was at the device to inspect \(colour.rawValue)"
                return result(rollup(metrics), summary, metrics: metrics)
            }
        }

        await MainActor.run { coordinator.hide() }
        context.progress(1, "Sweep complete")

        let verdict = rollup(metrics)
        let summary = failures.isEmpty
            ? "All \(sequence.count) colour fields reported clean"
            : "Defects reported on: \(failures.joined(separator: ", "))"
        _ = unanswered
        return result(verdict, summary, metrics: metrics)
    }
}

// MARK: - Touch digitizer

/// Maps the touch digitizer by asking the person to trace the whole screen.
///
/// A digitizer usually fails in a *region* — a dead strip along an edge, or a
/// patch where the glass was struck — so the screen is divided into cells and
/// every cell must register a touch. Cells that never report are named in the
/// result, which turns "the touchscreen is faulty" into "the top-right corner
/// is dead", the difference between a guess and a repair.
///
/// Maximum simultaneous touches is recorded at the same time, since it comes
/// free from the same gesture stream.
struct TouchGridTest: AgentTest {
    private static func describe(_ r: CGRect) -> String {
        "\(Int(r.width))×\(Int(r.height)) pt at (\(Int(r.minX)), \(Int(r.minY)))"
    }

    private static let rows = 8
    private static let columns = 5
    private static let timeout: TimeInterval = 60

    var descriptor: AgentTestDescriptor {
        AgentTestDescriptor(
            id: "display.touch", title: "Touch Digitizer (guided)",
            section: "Display", requiresInteraction: true,
            estimatedSeconds: Self.timeout
        )
    }

    func run(context: AgentTestContext) async throws -> AgentTestResult {
        context.progress(0.05, "Waiting for the screen to be traced")
        context.awaitingUser(
            "Drag a finger over every square on the device's screen "
            + "(\(Self.rows * Self.columns) cells, \(Int(Self.timeout))s)"
        )

        let grid = await InteractionCoordinator.shared.runTouchGrid(
            rows: Self.rows, columns: Self.columns, timeout: Self.timeout
        )

        guard grid.total > 0 else {
            return result(.skipped, "The touch grid was dismissed before it ran")
        }

        var metrics: [AgentMetric] = [
            .graded("coverage", "Digitizer coverage", grid.coverage, unit: "%",
                    warnAt: 99.9, failAt: 95, higherIsBetter: true,
                    note: "every cell must register at least one touch",
                    expectation: "100%"),
            .number("cells", "Cells tested", Double(grid.total)),
            .number("rawEvents", "Raw touch events seen", Double(grid.rawEvents),
                    note: grid.rawEvents == 0
                        ? "the capture view received no touches at all — this points at "
                          + "the agent's own layout, not the digitizer"
                        : nil),
        ]

        // Self-check: were touches mapped against the frame the grid was drawn
        // in? If not, the coverage figure above is measuring the wrong squares.
        // Graded .error, not .fail — a mismatch is a fault in this app, never
        // in the digitizer, and the verdict has to say so.
        var mappingAligned = true
        if let drawn = grid.drawnFrame, let touch = grid.touchFrame {
            let aligned = abs(drawn.minX - touch.minX) <= 1 && abs(drawn.minY - touch.minY) <= 1
                && abs(drawn.width - touch.width) <= 1 && abs(drawn.height - touch.height) <= 1
            metrics.append(.flag(
                "mapping", "Touches mapped to the drawn grid", aligned,
                shouldBe: true, severityIfNot: .error,
                note: aligned
                    ? "the touch surface and the drawn grid are the same rectangle"
                    : "touch surface \(Self.describe(touch)) but grid drawn at \(Self.describe(drawn)) — "
                      + "touches are credited to the wrong square; a fault in this app, not the digitizer"))
            mappingAligned = aligned
            metrics.append(.reading("drawnFrame", "Grid drawn at", Self.describe(drawn)))
            metrics.append(.reading("touchFrame", "Touches mapped over", Self.describe(touch)))
        }

        if !grid.missed.isEmpty {
            // Naming the cells is the whole point — it localises the fault.
            metrics.append(.list("missed", "Cells with no touch", grid.missed,
                                 note: "rows count from the top, columns from the left"))
        }

        if grid.maxSimultaneousTouches > 0 {
            // iOS reports up to 5 concurrent touches on iPhone and 11 on iPad,
            // but this only counts what was actually offered. Tracing with one
            // finger legitimately yields 1, so it is stated as an observation
            // rather than a capability — otherwise "1" reads as broken
            // multitouch on a perfectly good panel.
            let n = grid.maxSimultaneousTouches
            metrics.append(.number(
                "multitouch", "Most fingers seen at once", Double(n),
                note: n >= 2
                    ? "multiple simultaneous touches tracked correctly"
                    : "only one finger was used, so multitouch was not exercised"
            ))
        }

        let verdict = rollup(metrics)
        // Distinguish a dead digitizer from a test that never received input.
        if grid.rawEvents == 0 {
            return result(.skipped,
                "No touches reached the test — nothing was traced, or the overlay did not accept input",
                metrics: metrics)
        }
        // A misaligned mapping outranks coverage in the summary: coverage was
        // measured against the wrong squares, so "all cells responded" beside
        // an ERROR verdict would be a verdict contradicting its own summary.
        let summary = !mappingAligned
            ? "Touches were mapped to the wrong squares, so coverage can't be trusted — a fault in this app, not the digitizer"
            : grid.isComplete
                ? "All \(grid.total) cells responded"
                : "\(grid.missed.count) of \(grid.total) cells never registered a touch"
        return result(verdict, summary, metrics: metrics)
    }
}
