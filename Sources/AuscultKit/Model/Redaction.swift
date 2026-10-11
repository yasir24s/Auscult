import Foundation

/// Identifiers Auscult reads but should not show in full.
///
/// Serials, UDID, ECID, IMEI, ICCID, phone number and MAC addresses each name
/// one device, SIM or person, and Auscult reports get pasted into forums and
/// sale listings. A short tail stays visible so a reading can still be checked
/// against Settings › General › About, the SIM tray or the label on the cell.
public enum Redaction {
    /// Raw keys whose values identify a device, SIM or person. `Serial` is the
    /// battery's key on AppleSmartBattery today and `BatterySerialNumber` its
    /// older name; the rest are the lockdown and IORegistry spellings of the
    /// device identifiers.
    static let identifierKeys: Set<String> = [
        "Serial", "BatterySerialNumber", "SerialNumber", "IOPlatformSerialNumber",
        "UniqueDeviceID", "UDID", "UniqueChipID", "ECID", "IOPlatformUUID",
        "InternationalMobileEquipmentIdentity", "InternationalMobileEquipmentIdentity2",
        "IMEI", "IMEI2", "MobileEquipmentIdentifier", "MEID",
        "IntegratedCircuitCardIdentity", "ICCID", "ICCID2",
        "PhoneNumber", "phoneNumber", "phoneNumber2",
        "WiFiAddress", "wifiAddress", "BluetoothAddress", "bluetoothAddress",
        "EthernetAddress", "ethernetAddress", "HostID", "SystemBUID",
    ]

    /// The note shown beside a masked value.
    public static let note = "hidden except the last 4 characters"

    /// Mask all but the last four characters.
    public static func identifier(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let shown = 4
        // Too short to keep a tail without giving most of it away.
        guard trimmed.count > shown * 2 else { return "••••" }
        return String(repeating: "•", count: trimmed.count - shown) + trimmed.suffix(shown)
    }

    /// Mask a MAC address down to its last two octets, keeping the shape so it
    /// still reads as an address.
    public static func mac(_ value: String) -> String {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return identifier(value) }
        return (Array(repeating: "••", count: 4) + parts.suffix(2).map(String.init))
            .joined(separator: ":")
    }

    /// Mask a raw value by the key it was stored under; other keys pass through.
    public static func value(_ value: String, forKey key: String) -> String {
        guard identifierKeys.contains(key) else { return value }
        return key.lowercased().hasSuffix("address") ? mac(value) : identifier(value)
    }

    /// Whether `selector` is the visible tail of a masked identifier, so a
    /// value copied from masked output can still pick a device.
    public static func matchesTail(_ selector: String, of value: String?) -> Bool {
        guard let value, selector.count >= 4, !selector.contains("•") else { return false }
        return value.lowercased().hasSuffix(selector.lowercased())
    }
}

public extension DeviceSnapshot {
    /// The copy a report keeps. Reports are written to disk and shared, so the
    /// device block hides the same identifiers the metrics do; the live
    /// snapshot keeps the real values because the transports need them.
    var redactedForReport: DeviceSnapshot {
        var d = self
        d.id = Redaction.identifier(id)
        d.udid = udid.map(Redaction.identifier)
        d.ecid = ecid.map(Redaction.identifier)
        d.serialNumber = serialNumber.map(Redaction.identifier)
        d.coreDeviceIdentifier = coreDeviceIdentifier.map(Redaction.identifier)
        return d
    }
}
