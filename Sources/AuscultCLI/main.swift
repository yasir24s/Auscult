import Foundation
import AuscultKit

// A deliberately small hand-rolled CLI: the tool needs to be runnable before
// the GUI exists, and every code path here is shared with the app.

let args = Array(CommandLine.arguments.dropFirst())
let stderrHandle = FileHandle.standardError

func emit(_ s: String) { print(s) }
func warn(_ s: String) { stderrHandle.write(Data("\(s)\n".utf8)) }

func usage() -> String {
    """
    auscult \(Auscult.version) — iOS device diagnostics

    USAGE
      auscult doctor                    Show which data paths this host has
      auscult agent [udid]              Connect to the on-device agent, list its tests
      auscult agent [udid] --test <id>  Run one on-device hardware test
      auscult usbmux                    Inspect the mux layer and pair records
      auscult pairtest <file>           Verify a pair record builds a TLS identity
      auscult relay [udid]              Trace the deep lockdown handshake step by step
      auscult ioreg --class X           Dump an IORegistry node (--name / --class / --udid)
      auscult list                      List every visible device
      auscult run [selector]            Run diagnostics (default: first physical device)
      auscult run [selector] --json     Emit the machine-readable report
      auscult run [selector] --csv      Emit one row per metric

    SELECTOR
      A UDID, ECID, serial number, or a case-insensitive fragment of the
      device name. Omit to pick the first connected physical device.

    OPTIONS
      --json            JSON to stdout
      --csv             CSV to stdout
      --out <path>      Write the report to a file instead of stdout
      --all             With `run`, diagnose every visible device
      --include-sims    Don't filter out simulators
      --guided          Include tests needing someone at the device
      --no-agent        Skip on-device hardware tests entirely
      --no-color        Disable ANSI colour
    """
}

func flag(_ name: String) -> Bool { args.contains(name) }
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return nil }
    return args[i + 1]
}

/// Positional arguments only — anything not a flag or a flag's value.
var positionals: [String] = []
do {
    let valueFlags: Set<String> = ["--out", "--udid", "--name", "--class", "--test"]
    var skipNext = false
    for a in args.dropFirst() {
        if skipNext { skipNext = false; continue }
        if a.hasPrefix("-") { if valueFlags.contains(a) { skipNext = true }; continue }
        positionals.append(a)
    }
}

let useColor = !flag("--no-color") && isatty(fileno(stdout)) == 1

func matches(_ device: DeviceSnapshot, _ selector: String) -> Bool {
    let s = selector.lowercased()
    for candidate in [device.udid, device.ecid, device.serialNumber, device.coreDeviceIdentifier] {
        if candidate?.lowercased() == s { return true }
    }
    return device.displayName.lowercased().contains(s)
        || (device.productType?.lowercased().contains(s) ?? false)
}

func write(_ text: String) throws {
    if let path = option("--out") {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        warn("Wrote \(path)")
    } else {
        emit(text)
    }
}

func render(_ report: DiagnosticReport) throws -> String {
    if flag("--json") { return String(lossyUTF8: try report.jsonData()) }
    if flag("--csv") { return report.csvReport() }
    return report.textReport(useColor: useColor && option("--out") == nil)
}

// MARK: - Commands

let session = DiagnosticSession()

switch args.first {
case "doctor":
    emit("Host data paths\n")
    for (name, a) in await session.transportStatus() {
        let mark = a.isAvailable ? "✓" : "✗"
        var line = "  \(mark) \(name)"
        if let v = a.version { line += " — \(v)" }
        if let d = a.detail { line += " — \(d)" }
        emit(line)
    }
    let (devices, errors) = await session.devices()
    emit("\n  \(devices.count) device(s) visible")
    for e in errors { warn("  ! \(e)") }

case "list":
    let (devices, errors) = await session.devices()
    for e in errors { warn("! \(e)") }
    let shown = flag("--include-sims") ? devices : devices.filter { !$0.isSimulator }
    guard !shown.isEmpty else {
        warn("No devices visible. Connect a device over USB, or pass --include-sims.")
        exit(1)
    }
    for d in shown {
        let reach = d.isReachable ? "connected" : "offline"
        var tags = [d.link.rawValue, reach]
        if d.isSimulator { tags.append("simulator") }
        if d.isPrereleaseOS { tags.append("prerelease") }
        emit("\(d.displayName)")
        emit("    \(d.marketingName ?? d.productType ?? "?")  ·  \(d.osDescription)")
        emit("    \(tags.joined(separator: " · "))")
        if let u = d.udid { emit("    udid \(u)") }
        emit("")
    }

case "run":
    let (devices, errors) = await session.devices()
    for e in errors { warn("! \(e)") }

    /// Best-first: physical before simulator, connected before offline.
    func rank(_ d: DeviceSnapshot) -> Int {
        (d.isSimulator ? 2 : 0) + (d.isReachable ? 0 : 1)
    }

    var targets: [DeviceSnapshot]
    if let selector = positionals.first {
        let matched = devices.filter { matches($0, selector) }.sorted { rank($0) < rank($1) }
        guard !matched.isEmpty else {
            warn("No device matched '\(selector)'. Run `auscult list` to see what's visible.")
            exit(1)
        }
        // A name like "iPhone 17 Pro Max" matches both a real device and a
        // simulator; without --all, diagnose the most useful single match.
        targets = flag("--all") ? matched : [matched[0]]
        if !flag("--all") && matched.count > 1 {
            warn("note: '\(selector)' matched \(matched.count) devices; using \(targets[0].displayName)"
                 + (targets[0].isSimulator ? " (simulator)" : "") + ". Pass --all for every match.")
        }
    } else {
        let physical = devices.filter { !$0.isSimulator }
        if flag("--all") {
            targets = flag("--include-sims") ? devices : physical
        } else {
            // Prefer something actually connected over something merely known.
            guard let pick = physical.first(where: \.isReachable) ?? physical.first ?? devices.first else {
                warn("No devices visible.")
                exit(1)
            }
            targets = [pick]
        }
    }

    let quiet = flag("--json") || flag("--csv")
    if flag("--guided") && !quiet {
        // The automated tests run first and take a couple of minutes, so
        // without this the prompts arrive long after the operator has looked
        // away — and an unanswered guided test is wasted coverage.
        warn("""
        Guided tests are enabled: stay with the device. After the automated
        checks you will be asked to inspect five colour fields and trace the
        screen. Prompts appear on the device itself.
        """)
    }
    var rendered: [String] = []
    for device in targets {
        if !quiet { warn("Diagnosing \(device.displayName)…") }
        let report = await session.run(
            device,
            includeAgent: !flag("--no-agent"),
            includeInteractive: flag("--guided")
        ) { p in
            if !quiet { warn("  [\(p.completed)/\(p.total)] \(p.currentTitle)") }
        }
        rendered.append(try render(report))
    }
    try write(rendered.joined(separator: flag("--json") ? "\n" : "\n\n"))

case "agent":
    await runAgentCommand(
        session: session, selector: positionals.first,
        testID: option("--test"), listOnly: !flag("--test") && option("--test") == nil
    )

case "usbmux":
    await runUsbmuxDiagnostic()

case "ioreg":
    emit(await LockdownDebug.ioregistry(
        udid: option("--udid"),
        entryName: option("--name"),
        entryClass: option("--class")
    ))

case "relay":
    emit(await LockdownDebug.trace(udid: positionals.first))

case "pairtest":
    guard let path = positionals.first else {
        warn("usage: auscult pairtest <path to .mobiledevicepairing>")
        exit(2)
    }
    emit(HostIdentityDebug.testPairingFile(at: path))

case "--version", "-v", "version":
    emit(Auscult.version)

case nil, "help", "--help", "-h":
    emit(usage())

default:
    warn("Unknown command '\(args[0])'\n")
    emit(usage())
    exit(2)
}
