import Foundation
import AuscultKit
import AuscultProtocol

/// `auscult agent` — talk to the on-device agent directly.
///
/// Kept separate from `run` so the agent can be exercised one test at a time.
/// A guided test takes a minute of somebody's attention, and being able to
/// invoke exactly one is the difference between developing this comfortably and
/// sitting through the whole suite every time.
func runAgentCommand(
    session: DiagnosticSession, selector: String?, testID: String?, listOnly: Bool
) async {
    let (devices, _) = await session.devices()
    let wired = devices.filter { !$0.isSimulator && $0.link == .usb }

    let target: DeviceSnapshot?
    if let selector {
        target = devices.first {
            $0.udid?.caseInsensitiveCompare(selector) == .orderedSame
                || $0.displayName.lowercased().contains(selector.lowercased())
        }
    } else {
        target = wired.first
    }

    guard let device = target else {
        print("No wired device found. Connect one over USB.")
        return
    }
    print("Device: \(device.displayName) (\(device.osDescription))")

    print("Bringing the agent to the foreground…")
    let launched = await session.prepareAgent(on: device)
    print(launched ? "  launched" : "  could not launch it — open it by hand and keep it on screen")

    guard let identity = await session.agent.identity(for: device) else {
        let why = await session.agent.unavailableReason(for: device) ?? "no answer"
        print("\nAgent unreachable: \(why)")
        print("Check the app is installed and in the foreground on the device.")
        return
    }

    print("""

    Agent \(identity.agentVersion) (protocol v\(identity.protocolVersion))
      device  \(identity.deviceModel) — \(identity.deviceName)
      system  \(identity.osName) \(identity.osVersion)\(identity.osBuild.map { " (\($0))" } ?? "")
    """)

    if listOnly, testID == nil {
        print("\nTests (\(identity.tests.count)):")
        for t in identity.tests.sorted(by: { $0.section == $1.section ? $0.id < $1.id : $0.section < $1.section }) {
            var tags: [String] = []
            if t.requiresInteraction { tags.append("guided") }
            if let p = t.permission { tags.append("\(p.rawValue)\(t.permissionGranted ? "" : " NOT GRANTED")") }
            if let why = t.unavailableReason { tags.append("unavailable: \(why)") }
            let suffix = tags.isEmpty ? "" : "  [\(tags.joined(separator: ", "))]"
            print("  \(t.id.padding(toLength: 24, withPad: " ", startingAt: 0)) \(t.section.padding(toLength: 10, withPad: " ", startingAt: 0)) ~\(Int(t.estimatedSeconds))s\(suffix)")
        }
        print("\nRun one with:  auscult agent \(device.udid ?? "") --test <id>")
        await session.agent.disconnect(from: device)
        return
    }

    guard let testID else { return }
    guard identity.tests.contains(where: { $0.id == testID }) else {
        print("\nNo such test '\(testID)'. Run without --test to list them.")
        await session.agent.disconnect(from: device)
        return
    }

    print("\nRunning \(testID)…")
    do {
        let result = try await session.agent.runTest(testID, on: device) { progress in
            let bar = progress.awaitingUser ? "WAITING FOR YOU" : "\(Int(progress.fraction * 100))%"
            FileHandle.standardError.write(Data("  [\(bar)] \(progress.message)\n".utf8))
        }
        print("""

        \(result.verdict.rawValue.uppercased())  \(result.title)
        \(result.summary)
        """)
        for m in result.metrics {
            let metric = Metric(m)
            let mark = metric.verdict == .info ? " " : metric.verdict.symbol
            var line = "  \(mark) \(metric.label): \(metric.formattedValue)"
            if let n = metric.note { line += "  (\(n))" }
            print(line)
        }
        if let detail = result.detail { print("  detail: \(detail)") }
        print("  took \(String(format: "%.1fs", result.duration))")
    } catch {
        print("\nFAILED: \(error.localizedDescription)")
    }
    await session.agent.disconnect(from: device)
}
