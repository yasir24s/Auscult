import SwiftUI

/// What the results mean, in plain language.
///
/// Asked for by the first external tester, who found the verdicts clear enough
/// to use but not to trust: a warning gave no hint whether it meant a fault or
/// a badly placed phone. Most of what this page says is exactly that
/// distinction — setup versus hardware.
///
/// No NavigationStack of its own: it is pushed from a test's detail view and
/// presented as a sheet from the toolbar, and the sheet supplies one.
struct ResultsGuideView: View {
    @Environment(DiagnosticRunner.self) private var runner

    private static let verdicts: [(AgentVerdict, String)] = [
        (.pass, "Working as expected."),
        (.warn, "Worth a second look. Often caused by how the test was run rather than "
            + "the hardware — check the setup notes below and run it again before "
            + "assuming a fault."),
        (.fail, "Outside what a healthy device produces. Run it once more to rule out "
            + "setup; if it fails again, the hardware is the likely cause."),
        (.error, "The test itself couldn't finish. That's a software problem, not a "
            + "verdict on the hardware."),
        (.info, "A reading, not a grade — how much RAM the device has, say. There is "
            + "nothing to pass or fail."),
        (.unsupported, "This device doesn't have that hardware, so there's nothing to test."),
        (.skipped, "Couldn't be judged this time — usually a permission wasn't granted, "
            + "or something needed first wasn't in place, like the volume or a "
            + "calibrated compass."),
    ]

    /// Results that look like bugs and are not. Every entry here is a question
    /// a real tester asked.
    private static let oddities: [(String, String)] = [
        ("Thermal shows 96–99%, not 100%",
         "It's measured against the single fastest second of the run, which is always "
            + "a touch above a typical one. Anything from about 95% up means no throttling."),
        ("The magnetometer's raw field is in the hundreds",
         "The raw figure includes the device's own magnets — MagSafe especially. The "
            + "calibrated figure is the one that's graded, and it should sit around 25–65 µT."),
        ("Memory looks small",
         "That's RAM — working memory for open apps — not storage. 8–12 GB of RAM is "
            + "normal even on a phone with a terabyte of storage."),
        ("RAM shows two different numbers",
         "It's the same amount in two units. GiB counts in 1024s and GB in 1000s, so the "
            + "GB figure is always a little bigger."),
        ("The satellite receiver warns indoors",
         "Satellite signals don't travel well through buildings. Run it outdoors or at a "
            + "window before worrying."),
        ("Sensors fail when I hold the phone",
         "They measure the device at rest, and a hand is never truly still. Lay it flat "
            + "on a table and run them again."),
    ]

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
        List {
            Section {
                ForEach(Self.verdicts, id: \.0) { verdict, meaning in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: verdict.symbol)
                            .foregroundStyle(verdict.tint)
                            .font(.title3)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verdict.label).font(.body.weight(.semibold))
                            Text(meaning).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("What each result means")
            } footer: {
                Text("A warning is not a failure. Setup — how the device was held, "
                     + "lit, or placed — causes most of them.")
            }

            Section("Results that look wrong but aren't") {
                ForEach(Self.oddities, id: \.0) { question, answer in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(question).font(.body.weight(.medium))
                        Text(answer).font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }

            ForEach(sections, id: \.name) { section in
                Section(section.name) {
                    ForEach(section.tests) { test in
                        TestExplainer(test: test)
                    }
                }
            }
        }
        .navigationTitle("About Results")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One test's purpose and setup, as it appears in the guide.
private struct TestExplainer: View {
    let test: AgentTestDescriptor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(test.title).font(.body.weight(.medium))
                if test.requiresInteraction {
                    Text("needs you")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: .capsule)
                }
            }
            if let about = test.about {
                Text(about).font(.callout).foregroundStyle(.secondary)
            }
            if let prep = test.preparation {
                Label(prep, systemImage: "hand.point.right")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Shown before Run All: the setup the included tests need, each distinct
/// instruction once.
///
/// Exists because putting instructions on each test's detail page was not
/// enough — Run All never opens a detail page, and Run All is how people
/// actually use the app. The first tester's sensor failures happened exactly
/// that way.
struct RunAllChecklist: View {
    @Environment(DiagnosticRunner.self) private var runner
    @Environment(\.dismiss) private var dismiss
    @AppStorage("skipRunAllChecklist") private var skipChecklist = false

    /// Distinct preparation text, in catalogue order, with the tests needing it.
    /// Tests sharing an instruction share the exact string in `TestGuidance`,
    /// which is what lets them group here.
    private var steps: [(text: String, tests: [String])] {
        var order: [String] = []
        var byText: [String: [String]] = [:]
        for test in runner.runAllQueue {
            guard let prep = test.preparation else { continue }
            if byText[prep] == nil { order.append(prep) }
            byText[prep, default: []].append(test.title)
        }
        return order.map { ($0, byText[$0] ?? []) }
    }

    private var totalSeconds: Int {
        Int(runner.runAllQueue.reduce(0) { $0 + $1.estimatedSeconds })
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Run All works through \(runner.runAllQueue.count) tests unattended, "
                         + "in about \(max(totalSeconds / 60, 1)) minutes. "
                         + "A few need the device set up first, or they can fail on "
                         + "perfectly good hardware.")
                        .font(.callout)
                }

                Section("Before you start") {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(index + 1)")
                                .font(.callout.monospacedDigit().weight(.semibold))
                                .frame(width: 22, height: 22)
                                .background(.orange.opacity(0.18), in: .circle)
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(step.text).font(.callout)
                                Text(step.tests.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section {
                    Toggle("Don't show this before Run All", isOn: $skipChecklist)
                } footer: {
                    Text("The same notes are always on each test's page and under "
                         + "About Results.")
                }
            }
            .navigationTitle("Before You Run")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        dismiss()
                        runner.runAll()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
