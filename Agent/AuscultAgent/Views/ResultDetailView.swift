import SwiftUI

/// One test: what it measured, and a button to run it again.
struct ResultDetailView: View {
    let testID: String
    @Environment(DiagnosticRunner.self) private var runner
    @Environment(InteractionCoordinator.self) private var coordinator

    private var descriptor: AgentTestDescriptor? { runner.descriptor(for: testID) }
    private var result: AgentTestResult? { runner.result(for: testID) }

    private var isRunningThis: Bool {
        if case .running(let id, _, _, _) = runner.state { id == testID } else { false }
    }

    var body: some View {
        List {
            // What it checks and how to prepare come BEFORE the run button, so
            // they are read before it is tapped rather than discovered after a
            // false failure.
            if let about = descriptor?.about {
                Section {
                    Text(about).font(.callout)
                }
            }
            if let prep = descriptor?.preparation {
                Section("Before you run") {
                    Label(prep, systemImage: "hand.point.right")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            if let descriptor {
                Section {
                    if isRunningThis {
                        runningRow
                    } else {
                        Button {
                            runner.run(testID: testID)
                        } label: {
                            Label(result == nil ? "Run test" : "Run again",
                                  systemImage: "play.circle.fill")
                        }
                        .disabled(!descriptor.isRunnable || runner.state.isRunning)
                    }

                    if let reason = descriptor.unavailableReason {
                        Label(reason, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if let alone = descriptor.runsAlone {
                        Label(alone, systemImage: "hand.raised")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    if let permission = descriptor.permission, !descriptor.permissionGranted {
                        Text("Asks for \(String(describing: permission)) permission the first time.")
                    }
                }
            }

            if let result {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: result.verdict.symbol)
                            .foregroundStyle(result.verdict.tint)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.verdict.label).font(.body.weight(.medium))
                            Text(result.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(String(format: "%.1fs", result.duration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                } header: {
                    Text("Verdict")
                } footer: {
                    NavigationLink("What does \(result.verdict.label.lowercased()) mean?") {
                        ResultsGuideView()
                    }
                    .font(.footnote)
                }

                if !result.metrics.isEmpty {
                    Section("Measurements") {
                        ForEach(result.metrics, id: \.id) { MetricRow(metric: $0) }
                    }
                }

                if let detail = result.detail, !detail.isEmpty {
                    Section("Detail") {
                        Text(detail).font(.callout.monospaced())
                    }
                }
            }
        }
        .navigationTitle(descriptor?.title ?? testID)
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let prompt = runner.userPrompt, coordinator.mode == .idle {
                PromptBar(prompt: prompt) { runner.answerPrompt($0) }
            }
        }
    }

    @ViewBuilder
    private var runningRow: some View {
        if case .running(_, _, let fraction, let message) = runner.state {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(message).font(.callout)
                    Spacer()
                    Button("Stop", role: .destructive) { runner.cancel() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                if fraction >= 0 {
                    ProgressView(value: min(max(fraction, 0), 1))
                } else {
                    ProgressView()
                }
            }
            .padding(.vertical, 2)
        }
    }
}

private struct MetricRow: View {
    let metric: AgentMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if metric.verdict != .info {
                    Image(systemName: metric.verdict.symbol)
                        .foregroundStyle(metric.verdict.tint)
                        .font(.caption)
                }
                Text(metric.label).font(.callout)
                Spacer()
                Text(value)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(metric.kind == .absent ? .tertiary : .primary)
                    .multilineTextAlignment(.trailing)
            }
            if let expectation = metric.expectation {
                Text("expected \(expectation)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let note = metric.note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
    }

    /// Render by kind. `list` is packed into one string with a unit separator
    /// on the wire, so it has to be split back out rather than printed raw.
    private var value: String {
        switch metric.kind {
        case .absent:
            return "—"
        case .list:
            let items = metric.raw.split(separator: "\u{1F}").map(String.init)
            return items.isEmpty ? "none" : items.joined(separator: ", ")
        case .bool:
            return metric.raw == "true" ? "yes" : "no"
        case .bytes:
            let bytes = Int64(metric.raw) ?? 0
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        case .double:
            let text = (Double(metric.raw)?.clean) ?? metric.raw
            return metric.unit.map { "\(text) \($0)" } ?? text
        case .int, .string:
            return metric.unit.map { "\(metric.raw) \($0)" } ?? metric.raw
        }
    }
}
