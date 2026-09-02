import SwiftUI
import AuscultKit

@main
struct AuscultApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Auscult", id: "main") {
            RootView()
                .environment(model)
                .task {
                    await model.bootstrap()
                    // Dev hook: AUSCULT_AUTORUN=1 kicks off a run on the
                    // selected device at launch, so the report UI can be
                    // exercised without a human clicking the button.
                    if ProcessInfo.processInfo.environment["AUSCULT_AUTORUN"] == "1",
                       let d = model.selectedDevice {
                        model.runDiagnostics(on: d, force: false)
                    }
                }
                .frame(minWidth: 940, minHeight: 620)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Rescan for Devices") {
                    Task { await model.refresh() }
                }
                .keyboardShortcut("r")

                Button("Run Diagnostics") {
                    if let d = model.selectedDevice { model.runDiagnostics(on: d) }
                }
                .keyboardShortcut("d")
                .disabled(model.selectedDevice == nil || model.runState.isRunning)
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            DeviceSidebar()
                .navigationSplitViewColumnWidth(min: 260, ideal: 290, max: 360)
        } detail: {
            if let device = model.selectedDevice {
                DeviceDetailView(device: device)
            } else {
                EmptyStateView()
            }
        }
    }
}

struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: model.hasAnyTransport ? "iphone.slash" : "exclamationmark.triangle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)

            Text(model.hasAnyTransport ? "No device selected" : "No data paths available")
                .font(.title3.weight(.medium))

            Text(model.hasAnyTransport
                 ? "Connect an iPhone, iPad, or Apple TV over USB and choose it in the sidebar."
                 : "Install Xcode or Apple Configurator so Auscult has a way to reach devices.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            Button("Rescan") { Task { await model.refresh() } }
                .buttonStyle(.borderedProminent)
                .disabled(model.isDiscovering)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
