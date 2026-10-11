import Foundation

/// Identifiers Auscult reads but should not show in full.
///
/// A device serial and a battery serial each name one physical unit and travel
/// with it when it is sold or sent for repair, and Auscult reports get pasted
/// into forums and listings. The last four characters stay so a reading can
/// still be checked against Settings › General › About or the label on the cell.
public enum Redaction {
    /// IORegistry keys that hold a serial. `Serial` is the battery's key on
    /// AppleSmartBattery today and `BatterySerialNumber` its older name; the
    /// other two carry the device serial.
    static let serialKeys: Set<String> = [
        "Serial", "BatterySerialNumber", "SerialNumber", "IOPlatformSerialNumber",
    ]

    public static func serial(_ serial: String) -> String {
        let trimmed = serial.trimmingCharacters(in: .whitespaces)
        let shown = 4
        // Too short to keep a tail without giving most of it away.
        guard trimmed.count > shown * 2 else { return "••••" }
        return String(repeating: "•", count: trimmed.count - shown) + trimmed.suffix(shown)
    }

    /// Whether a raw registry key names a device or battery serial.
    public static func isSerialKey(_ key: String) -> Bool {
        serialKeys.contains(key)
    }
}
