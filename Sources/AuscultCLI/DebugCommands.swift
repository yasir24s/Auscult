import Foundation
import AuscultKit

/// `auscult usbmux` — low-level check of the mux layer and pair records.
///
/// Kept as a first-class subcommand rather than a test fixture: when a probe
/// stops working after an OS update, the first question is always whether the
/// mux and the pair record are still good, and that needs to be answerable in
/// one command on a user's machine.
func runUsbmuxDiagnostic() async {
    do {
        let devices = try await UsbmuxDebug.listDevices()
        print("usbmuxd sees \(devices.count) device(s)\n")
        for d in devices {
            print("  \(d.serial)")
            print("    deviceID \(d.deviceID) · \(d.connectionType)")
            switch await UsbmuxDebug.pairRecordSummary(udid: d.serial) {
            case .success(let s): print("    pair record: \(s)")
            case .failure(let e): print("    pair record: unavailable — \(e.localizedDescription)")
            }
            print("")
        }
        if devices.isEmpty {
            print("  Nothing attached. Connect a device over USB and retry.")
        }
    } catch {
        print("usbmuxd unreachable: \(error.localizedDescription)")
    }
}
