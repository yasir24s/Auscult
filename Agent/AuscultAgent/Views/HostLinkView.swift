import SwiftUI

/// The Mac link. Secondary now: everything here also works from the
/// Diagnostics tab with no host attached.
struct HostLinkView: View {
    @Environment(AgentServer.self) private var server
    @Environment(DiagnosticRunner.self) private var runner

    var body: some View {
        NavigationStack {
            List {
                Section("Host Link") {
                    StatusRow(state: server.state, runner: runner)
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
            .navigationTitle("Mac Link")
        }
    }
}

private struct StatusRow: View {
    let state: AgentServer.State
    let runner: DiagnosticRunner

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(colour).frame(width: 9, height: 9)
            Text(label)
            Spacer()
            if case .running(_, _, let fraction, _) = runner.state, fraction >= 0 {
                Text("\(Int(fraction * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var label: String {
        // A run in progress is worth showing here even when it was started
        // from the Diagnostics tab rather than by a host.
        if case .running(_, let title, _, let message) = runner.state {
            return "\(title) — \(message)"
        }
        switch state {
        case .idle: return "Stopped"
        case .listening: return "Waiting for the Mac"
        case .connected: return "Connected"
        case .failed(let why): return "Failed: \(why)"
        }
    }

    private var colour: Color {
        if runner.state.isRunning { return .blue }
        switch state {
        case .idle: return .gray
        case .listening: return .orange
        case .connected: return .green
        case .failed: return .red
        }
    }
}
