import Foundation
import AuscultKit

/// Helpers shared by the selection pass and the termination pass.
enum QuitSupport {
    struct Target { let name: String; let pid: Int }

    static func processList(from listing: DynamicValue) -> [DynamicValue] {
        var processes = listing.runningProcesses.array
        if processes.isEmpty { processes = listing.search(forKey: "runningProcesses").array }
        return processes
    }

    /// App-bundle processes whose name matches any of `names`.
    static func matches(_ names: [String], in processes: [DynamicValue]) -> [Target] {
        var targets: [Target] = []
        for entry in processes {
            guard let path = entry.firstPresent("executable", "path", "name").string,
                  // App bundles only. Terminating a system daemon by hand
                  // either achieves nothing or breaks something.
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
        return targets
    }
}

private typealias Self_ = QuitSupport

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
func runQuitCommand(
    session: DiagnosticSession, names: [String],
    deviceSelector: String? = nil, xcrun: String = "/usr/bin/xcrun"
) async {
    guard !names.isEmpty else {
        print("usage: auscult quit <app name>…    e.g. auscult quit Twitter TikTok")
        return
    }

    let (devices, _) = await session.devices()

    // Find the device the named apps are actually running on.
    //
    // Ranking by device class is not enough here: with a phone and a tablet
    // both idle on Wi-Fi the tiebreak is arbitrary, and "quit Twitter" picked
    // whichever sorted first rather than the one running Twitter. The command
    // names a process, so the process decides.
    var chosen: (device: DeviceSnapshot, processes: [DynamicValue])?
    var checked: [String] = []

    if let deviceSelector {
        guard let device = await DeviceSelection.choose(
            from: devices, selector: deviceSelector, session: session
        ) else {
            print("No device matched '\(deviceSelector)'.")
            return
        }
        let listing = await session.router.tryFetch(.processes, for: device)
        chosen = (device, QuitSupport.processList(from: listing))
    } else {
        for candidate in devices.filter({ !$0.isSimulator })
            .sorted(by: { ($0.family.hasBattery ? 0 : 1) < ($1.family.hasBattery ? 0 : 1) }) {
            guard await session.router.has(.processList, for: candidate) else { continue }
            let listing = await session.router.tryFetch(.processes, for: candidate)
            let processes = QuitSupport.processList(from: listing)
            if QuitSupport.matches(names, in: processes).isEmpty == false {
                chosen = (candidate, processes)
                break
            }
            checked.append(candidate.displayName)
            // Remember the first readable device, in case nothing matches.
            if chosen == nil { chosen = (candidate, processes) }
        }

        // Nothing matched anywhere: say that, rather than naming one device
        // arbitrarily and implying the others were not looked at.
        if let chosen, QuitSupport.matches(names, in: chosen.processes).isEmpty {
            print("""
            \(names.joined(separator: ", ")) not running on any reachable device.
            Checked: \(checked.joined(separator: ", ")).
            """)
            return
        }
    }

    guard let (device, processes) = chosen, let selector = device.devicectlSelector else {
        print("No device with a readable process list. Unlock it and check it is reachable.")
        return
    }
    print("Device: \(device.displayName)\n")

    let targets = QuitSupport.matches(names, in: processes)

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
