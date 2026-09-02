import SwiftUI

struct AgentRootView: View {
    @Environment(AgentServer.self) private var server
    @Environment(InteractionCoordinator.self) private var coordinator

    var body: some View {
        ZStack {
            main
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

    private var main: some View {
        NavigationStack {
            List {
                Section("Host Link") {
                    StatusRow(state: server.state)
                    LabeledContent("Port", value: "\(AgentProtocol.port)")
                    LabeledContent("Protocol", value: "v\(AgentProtocol.version)")
                    Text("Connect over USB from Auscult on your Mac. Keep this app in the "
                         + "foreground — iOS closes the connection when it is backgrounded.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("This Device") {
                    LabeledContent("Model", value: DeviceFacts.machine)
                    LabeledContent("System", value: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
                    if let build = DeviceFacts.osBuild {
                        LabeledContent("Build", value: build)
                    }
                    LabeledContent("Agent", value: AgentInfo.version)
                }

                if !server.lastResults.isEmpty {
                    Section("Results") {
                        ForEach(server.lastResults, id: \.testID) { r in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(symbol(r.verdict))
                                        .foregroundStyle(tint(r.verdict))
                                        .font(.headline)
                                    Text(r.title).font(.body.weight(.medium))
                                }
                                Text(r.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Activity") {
                    if server.log.isEmpty {
                        Text("Nothing yet").foregroundStyle(.secondary)
                    }
                    ForEach(server.log.reversed()) { entry in
                        HStack(alignment: .top, spacing: 6) {
                            Text(entry.at, format: .dateTime.hour().minute().second())
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                            Text(entry.text)
                                .font(.caption)
                                .foregroundStyle(entry.isError ? .red : .primary)
                        }
                    }
                }
            }
            .navigationTitle("Auscult Agent")
            .overlay(alignment: .bottom) {
                if let prompt = server.userPrompt, coordinator.mode == .idle {
                    PromptBar(prompt: prompt) { server.answerPrompt($0) }
                }
            }
        }
    }

    private func symbol(_ v: AgentVerdict) -> String {
        switch v {
        case .pass: "✓"; case .warn: "!"; case .fail: "✗"; case .error: "⚠"
        case .info: "·"; case .unsupported: "–"; case .skipped: "◦"
        }
    }

    private func tint(_ v: AgentVerdict) -> Color {
        switch v {
        case .pass: .green; case .warn: .orange; case .fail: .red
        case .error: .purple; default: .secondary
        }
    }
}

private struct StatusRow: View {
    let state: AgentServer.State

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(colour).frame(width: 9, height: 9)
            Text(label)
            Spacer()
            if case .running(_, let fraction, _) = state {
                Text("\(Int(fraction * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var label: String {
        switch state {
        case .idle: "Stopped"
        case .listening: "Waiting for the Mac"
        case .connected: "Connected"
        case .running(let test, _, let message): "\(test) — \(message)"
        case .failed(let why): "Failed: \(why)"
        }
    }

    private var colour: Color {
        switch state {
        case .idle: .gray
        case .listening: .orange
        case .connected: .green
        case .running: .blue
        case .failed: .red
        }
    }
}

/// The yes/no bar used by guided tests when the screen isn't taken over.
private struct PromptBar: View {
    let prompt: AgentServer.UserPrompt
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
    @Environment(AgentServer.self) private var server

    var body: some View {
        ZStack {
            colour.colour.ignoresSafeArea()

            if let prompt = server.userPrompt {
                VStack {
                    Spacer()
                    VStack(spacing: 12) {
                        Text(prompt.message)
                            .font(.callout.weight(.semibold))
                            .multilineTextAlignment(.center)
                        HStack(spacing: 12) {
                            if let reject = prompt.rejectTitle {
                                Button(reject) { server.answerPrompt(false) }
                                    .buttonStyle(.bordered)
                                    .tint(.red)
                            }
                            Button(prompt.confirmTitle) { server.answerPrompt(true) }
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
