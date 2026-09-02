import Foundation
import AuscultKit

/// `auscult drain` — a controlled battery drain measurement.
///
/// The ordinary probe reports whatever the device happens to be doing, which is
/// nearly useless for answering "why doesn't my phone last the day": a phone
/// with the screen on at full brightness legitimately draws several watts. A
/// meaningful number needs controlled conditions, so this command states them,
/// waits for the operator to establish them, and only then measures.
func runDrainCommand(
    session: DiagnosticSession, selector: String?, seconds: Double, waitSeconds: Double
) async {
    let (devices, _) = await session.devices()
    let candidates = devices.filter { !$0.isSimulator }
    let target = selector.flatMap { sel in
        candidates.first {
            $0.udid?.caseInsensitiveCompare(sel) == .orderedSame
                || $0.displayName.lowercased().contains(sel.lowercased())
        }
    } ?? candidates.first { $0.link == .usb } ?? candidates.first

    guard let device = target else {
        print("No device found. Connect one over USB.")
        return
    }

    print("""
    Controlled drain measurement — \(device.displayName)

    For the number to mean anything the device has to be idle:

      1. Close the Auscult Agent if it is open (it holds the screen awake
         while a test is running).
      2. Lock the device so the screen turns off.
      3. Leave the USB cable connected — the measurement needs it.

    While the cable is attached the device is charging, so what gets measured
    is system load: the power the device consumes, independent of the battery.
    That is the figure that answers the drain question, and charging does not
    distort it.
    """)

    if waitSeconds > 0 {
        // A countdown rather than a Return prompt: the operator needs both
        // hands on the device, and stdin is often not a terminal anyway.
        print("Starting in \(Int(waitSeconds))s — lock the device now.")
        let start = Date()
        while Date().timeIntervalSince(start) < waitSeconds {
            let left = Int(waitSeconds - Date().timeIntervalSince(start))
            FileHandle.standardError.write(Data("\r  \(left)s… ".utf8))
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        FileHandle.standardError.write(Data("\r            \r".utf8))
    } else {
        print("Press Return once the screen is off.")
        _ = readLine()
    }

    // Warn before spending a minute measuring something that won't mean much.
    if let listing = try? await session.router.fetch(.crashLogIndex, for: device) {
        let busy = DiagnosticReportIndex.parse(listing).maintenanceInProgress()
        if !busy.isEmpty {
            print("""

            NOTE: system maintenance is running — \(busy.joined(separator: ", ")).
            These rebuild photo analysis, Spotlight and iCloud state after a reboot
            or a large import, and can run for hours on a device with a lot of media.
            Idle draw is legitimately high while they work, so this measurement will
            read the rebuild rather than the device's normal behaviour. For a true
            baseline, re-run once they have finished.
            """)
        }
    }

    print("Measuring for \(Int(seconds))s — do not touch the device…")

    let probe = LiveDrainProbe(
        sampleCount: max(Int(seconds / 2.5), 4), interval: 2.5
    )
    do {
        let result = try await probe.run(device: device, router: session.router)
        print("\n\(result.verdict.rawValue.uppercased())  \(result.summary)\n")
        for m in result.metrics {
            let mark = m.verdict == .info ? " " : m.verdict.symbol
            var line = "  \(mark) \(m.label): \(m.formattedValue)"
            if let n = m.note { line += "  (\(n))" }
            print(line)
        }

        // Interpretation, because a bare milliwatt figure means nothing to most
        // people looking at it.
        if let load = result.metrics.first(where: { $0.id == "meanSystemLoad" }),
           case .double(let mW) = load.value {
            print("\n\(interpretation(forIdleMilliwatts: mW))")
        }
    } catch {
        print("\nFailed: \(error.localizedDescription)")
    }
}

/// Translate an idle system load into plain language and a next step.
private func interpretation(forIdleMilliwatts mW: Double) -> String {
    switch mW {
    case ..<400:
        """
        That is normal. An idle iPhone with the screen off sits in this range,
        so the hardware is not the problem — if the battery still disappears
        during the day, the cause is something running while you use it.
        """
    case 400..<900:
        """
        Slightly elevated but not alarming. Something is waking the device
        periodically — push mail, a fitness app, or location updates.
        """
    case 900..<2000:
        """
        Clearly elevated. An idle device should not draw this much. Something is
        running continuously in the background. Check Settings › Battery for
        which app leads 'Background Activity', and look at Background App
        Refresh and any app with 'Always' location access.
        """
    default:
        """
        Very high for an idle device — this is consistent with a real drain
        problem rather than normal use. A process is running flat out.

        Before concluding that, though: have you just force-quit a lot of apps?
        Doing so makes this figure far worse, not better. Measured on one
        device, closing 31 apps took idle draw from 682 mW to 5,720 mW, and it
        took over ten minutes to come back down — iOS has to rebuild everything
        it discarded. A suspended app costs nothing; relaunching it costs a lot.

        If nothing was force-quit, the next step is `auscult energy` for
        per-process attribution.
        """
    }
}
