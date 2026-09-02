import Foundation

/// Thin public window onto the mux internals, for the `usbmux` subcommand.
public enum UsbmuxDebug {
    public struct Device: Sendable {
        public let deviceID: Int
        public let serial: String
        public let connectionType: String
    }

    public static func listDevices() async throws -> [Device] {
        try await UsbmuxClient().listDevices().map {
            Device(deviceID: $0.deviceID, serial: $0.serialNumber, connectionType: $0.connectionType)
        }
    }

    public static func pairRecordSummary(udid: String) async -> Result<String, Error> {
        do {
            let record = try await UsbmuxClient().readPairRecord(udid: udid)
            var parts = [
                "HostID \(record.hostID.prefix(8))…",
                "host cert \(record.hostCertificatePEM.count) B",
                "host key \(record.hostPrivateKeyPEM.count) B",
                "device cert \(record.deviceCertificatePEM.count) B",
            ]
            if record.escrowBag != nil { parts.append("escrow bag present") }
            if let mac = record.wifiMACAddress { parts.append("wifi \(mac)") }
            return .success(parts.joined(separator: ", "))
        } catch {
            return .failure(error)
        }
    }
}
