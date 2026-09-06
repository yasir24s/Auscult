import Foundation
import AuscultKit

/// `auscult quit <name>…` — terminate named third-party apps on the device.
///
/// Exists because force-quitting turned out to be a precision instrument, not a
/// blunt one. Closing everything made idle draw eight times worse — iOS has to
/// rebuild what it discarded — but terminating a single misbehaving app took a
/// device from 3,421 mW to 544 mW. The difference is whether you are removing a
/// process that is *working* or one that is merely resident.
///
/// Restricted to app bundles: a system daemon terminated by hand is either
/// restarted immediately or breaks something, and neither helps.
func runQuitCommand(session: DiagnosticSession, names: [String], xcrun: String = "/usr/bin/xcrun") async {
    guard !names.isEmpty else {
        print("usage: auscult quit <app name>…    e.g. auscult quit Twitter TikTok")
        return
    }

    let (devices, _) = await session.devices()
    guard let device = devices.first(where: { !$0.isSimulator && $0.family.hasBattery })
            ?? devices.first(where: { !$0.isSimulator }),
          let selector = device.devicectlSelector
    else {
        print("No device found.")
        return
    }
    print("Device: \(device.displayName)\n")

    guard let listing = try? await session.router.fetch(.processes, for: device) else {
        print("Could not read the process list. Is the device reachable?")
        return
    }
    var processes = listing.runningProcesses.array
    if processes.isEmpty { processes = listing.search(forKey: "runningProcesses").array }

    struct Target { let name: String; let pid: Int }
    var targets: [Target] = []

    for entry in processes {
        guard let path = entry.firstPresent("executable", "path", "name").string,
              // App bundles only. Terminating a system daemon by hand either
              // achieves nothing or breaks something.
              path.contains("/containers/Bundle/"),
              let pid = entry.firstPresent("processIdentifier", "pid").int
        else { continue }

        let raw = (path as NSString).lastPathComponent
        let name = raw.removingPercentEncoding ?? raw
        // Never terminate our own agent: it is the link the tests run over.
        guard !name.lowercased().contains("auscult") else { continue }

        if names.contains(where: { name.localizedCaseInsensitiveContains($0) }) {
            targets.append(Target(name: name, pid: Int(pid)))
        }
    }

    guard !targets.isEmpty else {
        print("None of \(names.joined(separator: ", ")) are running.")
        return
    }

    for target in targets {
        let result = try? await Shell.run(xcrun, [
            "devicectl", "device", "process", "terminate",
            "--device", selector, "--pid", String(target.pid),
        ], timeout: 45)
        let ok = result?.succeeded ?? false
        print("  \(ok ? "terminated" : "FAILED   ") \(target.name) (pid \(target.pid))")
    }

    // iOS may relaunch an app immediately if something still wants it awake —
    // which is itself the useful signal, so check rather than assume.
    print("\nChecking whether iOS brings them back…")
    try? await Task.sleep(nanoseconds: 12_000_000_000)

    guard let after = try? await session.router.fetchFresh(.processes, for: device) else { return }
    var stillRunning = after.runningProcesses.array
    if stillRunning.isEmpty { stillRunning = after.search(forKey: "runningProcesses").array }
    let liveNames = Set(stillRunning.compactMap { entry -> String? in
        guard let path = entry.firstPresent("executable", "path", "name").string else { return nil }
        let raw = (path as NSString).lastPathComponent
        return raw.removingPercentEncoding ?? raw
    })

    for target in targets {
        if liveNames.contains(target.name) {
            print("  \(target.name) was relaunched — something is still waking it. "
                  + "Turning off its Background App Refresh is what stops that.")
        } else {
            print("  \(target.name) stayed closed")
        }
    }
}
