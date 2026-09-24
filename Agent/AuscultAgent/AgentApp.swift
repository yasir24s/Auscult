import SwiftUI

@main
struct AuscultAgentApp: App {
    /// The runner is the app. The server is an optional extra that lets a Mac
    /// drive it — the runner is built first and handed over, so nothing about
    /// running a test depends on the link existing.
    @State private var runner: DiagnosticRunner
    @State private var server: AgentServer

    init() {
        let runner = DiagnosticRunner()
        _runner = State(initialValue: runner)
        _server = State(initialValue: AgentServer(runner: runner))
    }

    var body: some Scene {
        WindowGroup {
            AgentRootView()
                .environment(runner)
                .environment(server)
                .environment(InteractionCoordinator.shared)
                // Start listening anyway: a host may attach at any point, and
                // the Diagnostics tab does not care either way.
                .onAppear { server.start() }
                .statusBarHidden(InteractionCoordinator.shared.mode.takesOverScreen)
        }
    }
}
