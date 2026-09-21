import SwiftUI

struct AgentRootView: View {
    @Environment(DiagnosticRunner.self) private var runner
    @Environment(InteractionCoordinator.self) private var coordinator

    var body: some View {
        ZStack {
            // Classic tabItem rather than the iOS 18 `Tab` builder: the
            // deployment target is 17.0 and raising it purely for syntax would
            // drop devices this tool is most likely to be pointed at.
            TabView {
                DiagnosticsView()
                    .tabItem { Label("Diagnostics", systemImage: "waveform.path.ecg") }
                HostLinkView()
                    .tabItem { Label("Mac Link", systemImage: "cable.connector") }
            }

            // Guided tests take over the whole screen; they must sit above
            // everything, ignore safe areas, and hide the status bar so a flat
            // colour field really is flat.
            switch coordinator.mode {
            case .idle:
                EmptyView()
            case .solidColour(_, let colour):
                SweepOverlay(colour: colour)
            case .touchGrid(let grid):
                TouchGridOverlay(grid: grid)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: coordinator.mode)
    }
}

// MARK: - Shared verdict styling

extension AgentVerdict {
    var symbol: String {
        switch self {
        case .pass: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .fail: "xmark.circle.fill"
        case .error: "exclamationmark.octagon.fill"
        case .info: "info.circle"
        case .unsupported: "minus.circle"
        case .skipped: "circle.dashed"
        }
    }

    var tint: Color {
        switch self {
        case .pass: .green
        case .warn: .orange
        case .fail: .red
        case .error: .purple
        default: .secondary
        }
    }

    var label: String {
        switch self {
        case .pass: "Pass"
        case .warn: "Warning"
        case .fail: "Fail"
        case .error: "Error"
        case .info: "Info"
        case .unsupported: "Not supported"
        case .skipped: "Skipped"
        }
    }
}

// MARK: - Prompt bar

/// The yes/no bar used by guided tests when the screen isn't taken over.
struct PromptBar: View {
    let prompt: UserPrompt
    let answer: (Bool) -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text(prompt.message)
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                if let reject = prompt.rejectTitle {
                    Button(reject, role: .destructive) { answer(false) }
                        .buttonStyle(.bordered)
                }
                Button(prompt.confirmTitle) { answer(true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }
}

// MARK: - Sweep overlay

/// A flat colour field plus the inspection prompt.
private struct SweepOverlay: View {
    let colour: SweepColour
    @Environment(DiagnosticRunner.self) private var runner

    var body: some View {
        ZStack {
            colour.colour.ignoresSafeArea()

            if let prompt = runner.userPrompt {
                VStack {
                    Spacer()
                    VStack(spacing: 12) {
                        Text(prompt.message)
                            .font(.callout.weight(.semibold))
                            .multilineTextAlignment(.center)
                        HStack(spacing: 12) {
                            if let reject = prompt.rejectTitle {
                                Button(reject) { runner.answerPrompt(false) }
                                    .buttonStyle(.bordered)
                                    .tint(.red)
                            }
                            Button(prompt.confirmTitle) { runner.answerPrompt(true) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(18)
                    // Kept compact and translucent so it covers as little of the
                    // field as possible — the person needs to see the panel.
                    .background(.thinMaterial, in: .rect(cornerRadius: 16))
                    .padding(.bottom, 44)
                    .padding(.horizontal, 24)
                }
            }
        }
        .persistentSystemOverlays(.hidden)
    }
}
