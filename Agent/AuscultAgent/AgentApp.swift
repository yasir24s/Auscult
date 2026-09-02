import SwiftUI

@main
struct AuscultAgentApp: App {
    @State private var server = AgentServer()

    var body: some Scene {
        WindowGroup {
            AgentRootView()
                .environment(server)
                .environment(InteractionCoordinator.shared)
                .onAppear { server.start() }
                // The listener dies with the app's foreground state, so make it
                // obvious when the agent has stopped being reachable rather
                // than letting the host time out mysteriously.
                .statusBarHidden(InteractionCoordinator.shared.mode != .idle)
        }
    }
}
