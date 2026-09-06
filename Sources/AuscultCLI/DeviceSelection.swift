import Foundation
import AuscultKit

/// Picking the device a command should act on.
///
/// Centralised because getting it wrong is silent and I did it twice: with the
/// phone unplugged, "first candidate" selected an Apple TV for a battery drain
/// test, and later an iPad for an app-termination aimed at the iPhone. Both
/// produced confident output about the wrong hardware.
///
/// The rules, in order:
///  1. An explicit selector always wins.
///  2. Otherwise prefer a device that can actually serve what the command needs.
///  3. Prefer wired over wireless, for latency rather than capability.
///  4. Never silently choose a device that cannot answer the question.
enum DeviceSelection {
    /// - Parameters:
    ///   - requiring: a capability the chosen device must resolve, if any.
    ///   - batteryOnly: restrict to devices that have a battery.
    static func choose(
        from devices: [DeviceSnapshot],
        selector: String?,
        session: DiagnosticSession,
        requiring capability: Capability? = nil,
        batteryOnly: Bool = false
    ) async -> DeviceSnapshot? {
        let physical = devices.filter { !$0.isSimulator }

        if let selector {
            return physical.first {
                $0.udid?.caseInsensitiveCompare(selector) == .orderedSame
                    || $0.ecid?.caseInsensitiveCompare(selector) == .orderedSame
                    || $0.serialNumber?.caseInsensitiveCompare(selector) == .orderedSame
                    || $0.displayName.localizedCaseInsensitiveContains(selector)
            }
        }

        var candidates = batteryOnly ? physical.filter { $0.family.hasBattery } : physical

        // Rank rather than filter. A hard filter would make an Apple TV
        // unreachable for commands that legitimately apply to it, but leaving
        // the order arbitrary means a set-top box wins a command plainly aimed
        // at a phone — which is exactly what happened.
        func rank(_ device: DeviceSnapshot) -> (Int, Int, String) {
            (
                device.family.hasBattery ? 0 : 1,   // handhelds first
                device.link == .usb ? 0 : 1,        // then wired, for latency
                device.displayName                  // stable tiebreak
            )
        }
        candidates.sort { rank($0) < rank($1) }

        if let capability {
            for candidate in candidates
            where await session.router.has(capability, for: candidate) {
                return candidate
            }
            return nil
        }

        // No specific capability: take the first that resolves anything beyond
        // cached identity, so an absent device is not chosen over a present one.
        for candidate in candidates
        where await session.router.capabilities(for: candidate).count > 1 {
            return candidate
        }
        return candidates.first
    }

    /// Tell the operator which device was chosen when they didn't say.
    static func announce(_ device: DeviceSnapshot, selector: String?, total: Int) {
        guard selector == nil, total > 1 else { return }
        print("Using \(device.displayName). Pass a name or UDID to choose another.\n")
    }
}
