import SwiftUI

/// Standalone diagnostics: the whole catalogue, runnable with no Mac attached.
struct DiagnosticsView: View {
    @Environment(DiagnosticRunner.self) private var runner
    @Environment(InteractionCoordinator.self) private var coordinator
    @AppStorage("skipRunAllChecklist") private var skipChecklist = false
    @State private var showChecklist = false
    @State private var showGuide = false

    /// Catalogue grouped by section, in first-appearance order rather than
    /// alphabetically — the registry lists sensors before benchmarks on
    /// purpose, and sorting would scatter that.
    private var sections: [(name: String, tests: [AgentTestDescriptor])] {
        var order: [String] = []
        var byName: [String: [AgentTestDescriptor]] = [:]
        for test in runner.catalogue {
            if byName[test.section] == nil { order.append(test.section) }
            byName[test.section, default: []].append(test)
        }
        return order.map { ($0, byName[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                summarySection

                ForEach(sections, id: \.name) { section in
                    Section(section.name) {
                        ForEach(section.tests) { test in
                            NavigationLink {
                                ResultDetailView(testID: test.id)
                            } label: {
                                TestRow(test: test, result: runner.result(for: test.id))
                            }
                            .disabled(!test.isRunnable)
                        }
                    }
                }
            }
            .navigationTitle("Diagnostics")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if runner.state.isRunning {
                        Button("Stop", role: .destructive) { runner.cancel() }
                    } else {
                        Button("Run All") {
                            if skipChecklist { runner.runAll() } else { showChecklist = true }
                        }
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { showGuide = true } label: {
                        Label("About Results", systemImage: "questionmark.circle")
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Clear Results") { runner.clearResults() }
                        .disabled(runner.results.isEmpty)
                }
            }
            .sheet(isPresented: $showChecklist) { RunAllChecklist() }
            .sheet(isPresented: $showGuide) {
                NavigationStack {
                    ResultsGuideView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showGuide = false }
                            }
                        }
                }
            }
            .overlay(alignment: .bottom) {
                if let prompt = runner.userPrompt, coordinator.mode == .idle {
                    PromptBar(prompt: prompt) { runner.answerPrompt($0) }
                }
            }
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        if DeviceFacts.isiOSAppOnMac {
            Section {
                Label {
                    Text("You're running the iPhone and iPad app on a Mac. macOS presents it "
                         + "as an iPad for compatibility, so these tests measure this Mac, not a "
                         + "phone — and some can't run here. To diagnose an iPhone or iPad, run "
                         + "the app on that device, or connect it to Auscult for Mac.")
                        .font(.callout)
                } icon: {
                    Image(systemName: "laptopcomputer").foregroundStyle(.orange)
                }
            }
        }
        Section {
            if case .running(_, let title, let fraction, let message) = runner.state {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(title).font(.body.weight(.medium))
                        Spacer()
                        if runner.sweepRemaining > 0 {
                            Text("\(runner.sweepRemaining) left")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    // A negative fraction is the "still working" heartbeat, which
                    // carries no real progress — show it as indeterminate rather
                    // than snapping the bar back to zero.
                    if fraction >= 0 {
                        ProgressView(value: min(max(fraction, 0), 1))
                    } else {
                        ProgressView()
                    }
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            } else if runner.results.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No tests run yet")
                        .font(.body.weight(.medium))
                    Text("Run All covers everything that works unattended, and tells "
                         + "you how to set the device up first. Tests marked \"needs you\" "
                         + "run one at a time — each says why on its page. Tap ? for what "
                         + "the results mean.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            } else {
                let t = runner.tally
                HStack(spacing: 14) {
                    TallyPip(count: t.pass, verdict: .pass)
                    TallyPip(count: t.warn, verdict: .warn)
                    TallyPip(count: t.fail, verdict: .fail)
                    // Without this the pips silently omit ungraded results and
                    // read as though they should sum to the run count but do
                    // not — 13 + 2 + 0 next to "16 run".
                    TallyPip(count: t.other, verdict: .info)
                    Spacer()
                    Text("\(runner.results.count) run")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(DeviceFacts.displayName)
        } footer: {
            // No model code here. Even small, "iPhone14,5" under the name was
            // still read as "iPhone 14.5" by a tester on an iPhone 13. It lives,
            // labelled, on the Mac Link tab for anyone comparing hardware.
            Text("\(DeviceFacts.osName) \(UIDevice.current.systemVersion)"
                 + (DeviceFacts.osBuild.map { " (\($0))" } ?? "")
                 + " · Agent \(AgentInfo.version)")
        }
    }
}

private struct TallyPip: View {
    let count: Int
    let verdict: AgentVerdict

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: verdict.symbol).foregroundStyle(verdict.tint)
            Text("\(count)").font(.body.monospacedDigit().weight(.medium))
        }
        .opacity(count == 0 ? 0.35 : 1)
    }
}

private struct TestRow: View {
    let test: AgentTestDescriptor
    let result: AgentTestResult?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: result?.verdict.symbol ?? "circle.dotted")
                .foregroundStyle(result?.verdict.tint ?? Color.secondary.opacity(0.35))
                .font(.body)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(test.title)
                    .foregroundStyle(test.isRunnable ? .primary : .secondary)
                if let reason = test.unavailableReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                } else if let result {
                    Text(result.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if test.requiresInteraction {
                    Text("needs you · ~\(Int(test.estimatedSeconds))s")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("~\(Int(test.estimatedSeconds))s")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
