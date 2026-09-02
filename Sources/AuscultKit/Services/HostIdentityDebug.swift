import Foundation
import Security

/// Public probe for the TLS identity path, exposed for `auscult pairtest`.
public enum HostIdentityDebug {
    /// Load a `.mobiledevicepairing` plist from disk and try to build a TLS
    /// identity from it. Lets the trickiest step be verified without a device.
    public static func testPairingFile(at path: String) -> String {
        guard let data = FileManager.default.contents(atPath: path) else {
            return "cannot read \(path)"
        }
        let plist = DynamicValue.parsePlist(data)
        guard let record = PairRecord(plist) else {
            return "file is not a usable pair record (missing certificates or HostID)"
        }
        var lines = [
            "pair record parsed",
            "  HostID        \(record.hostID)",
            "  SystemBUID    \(record.systemBUID)",
            "  host cert     \(record.hostCertificatePEM.count) bytes",
            "  host key      \(record.hostPrivateKeyPEM.count) bytes",
            "  device cert   \(record.deviceCertificatePEM.count) bytes",
        ]
        if let mac = record.wifiMACAddress { lines.append("  wifi MAC      \(mac)") }

        if let cert = HostIdentity.certificate(fromPEM: record.hostCertificatePEM) {
            let subject = SecCertificateCopySubjectSummary(cert) as String? ?? "(no subject)"
            lines.append("  cert subject  \(subject)")
        } else {
            lines.append("  cert subject  FAILED to parse host certificate")
        }

        do {
            let handle = try HostIdentity.make(from: record)
            var certRef: SecCertificate?
            SecIdentityCopyCertificate(handle.identity, &certRef)
            var keyRef: SecKey?
            SecIdentityCopyPrivateKey(handle.identity, &keyRef)
            let bits = keyRef.map { SecKeyGetBlockSize($0) * 8 } ?? 0
            lines.append("  TLS identity  built OK (private key \(bits)-bit, cert \(certRef != nil ? "attached" : "missing"))")
        } catch {
            lines.append("  TLS identity  FAILED — \(error.localizedDescription)")
        }
        return lines.joined(separator: "\n")
    }
}
