import Foundation
import Security

/// Turns a pair record's PEM certificate and private key into a `SecIdentity`
/// usable as a TLS client credential.
///
/// There is no public API to build a `SecIdentity` from a loose cert/key pair —
/// `SecIdentityCreateWithCertificate` insists the private key already live in a
/// keychain. So we create a throwaway keychain in a temp directory, import the
/// pair into it, take the identity, and delete the keychain. Nothing touches the
/// user's login keychain, and nothing survives the process.
enum HostIdentity {

    /// A live identity plus the scratch keychain backing it. The identity stops
    /// working once the keychain is deleted, so ownership is bundled together.
    final class Handle {
        let identity: SecIdentity
        private let keychain: SecKeychain?
        private let path: String

        init(identity: SecIdentity, keychain: SecKeychain?, path: String) {
            self.identity = identity
            self.keychain = keychain
            self.path = path
        }

        deinit {
            if let keychain { SecKeychainDelete(keychain) }
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    static func make(from record: PairRecord) throws -> Handle {
        // SecItemImport reads a PEM *sequence*, so concatenating the cert and
        // key lets one import produce a matched pair in the keychain.
        var pem = Data()
        pem.append(record.hostCertificatePEM)
        if pem.last != 0x0A { pem.append(0x0A) }
        pem.append(record.hostPrivateKeyPEM)

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("auscult-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keychainPath = dir.appendingPathComponent("pairing.keychain").path

        // A random password we never store: the keychain lives and dies here.
        let password = UUID().uuidString
        var keychain: SecKeychain?
        var status = SecKeychainCreate(keychainPath, UInt32(password.utf8.count), password, false, nil, &keychain)
        guard status == errSecSuccess, let keychain else {
            throw IdentityError.keychain("could not create scratch keychain", status)
        }

        // Let anything in this process use the imported key without prompting.
        var access: SecAccess?
        SecAccessCreate("Auscult" as CFString, nil, &access)

        var params = SecItemImportExportKeyParameters()
        params.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
        params.flags = SecKeyImportExportFlags(rawValue: 0)
        // accessRef is an unmanaged +1 reference; SecItemImport consumes it.
        if let access { params.accessRef = Unmanaged.passRetained(access) }

        var format = SecExternalFormat.formatPEMSequence
        var itemType = SecExternalItemType.itemTypeAggregate
        var imported: CFArray?

        status = SecItemImport(
            pem as CFData, nil, &format, &itemType,
            SecItemImportExportFlags(rawValue: 0), &params, keychain, &imported
        )
        guard status == errSecSuccess else {
            SecKeychainDelete(keychain)
            try? FileManager.default.removeItem(at: dir)
            throw IdentityError.keychain("could not import host credentials", status)
        }

        let items = (imported as? [AnyObject]) ?? []

        // The import may hand back an identity directly; if not, find the
        // certificate and pair it with the key now sitting in the keychain.
        for item in items {
            if CFGetTypeID(item) == SecIdentityGetTypeID() {
                return Handle(identity: item as! SecIdentity, keychain: keychain, path: dir.path)
            }
        }
        for item in items where CFGetTypeID(item) == SecCertificateGetTypeID() {
            var identity: SecIdentity?
            let s = SecIdentityCreateWithCertificate(keychain, (item as! SecCertificate), &identity)
            if s == errSecSuccess, let identity {
                return Handle(identity: identity, keychain: keychain, path: dir.path)
            }
        }

        SecKeychainDelete(keychain)
        try? FileManager.default.removeItem(at: dir)
        throw IdentityError.noIdentity(itemCount: items.count)
    }

    /// Parse a PEM certificate into a `SecCertificate`, for pinning the device.
    static func certificate(fromPEM pem: Data) -> SecCertificate? {
        guard let der = derBody(fromPEM: pem) else { return nil }
        return SecCertificateCreateWithData(nil, der as CFData)
    }

    /// Strip the armour from the first PEM block and base64-decode it.
    static func derBody(fromPEM pem: Data) -> Data? {
        guard let text = String(data: pem, encoding: .utf8) else { return nil }
        var base64 = ""
        var inside = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("-----BEGIN") { inside = true; continue }
            if line.hasPrefix("-----END") { break }
            if inside { base64 += line.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return Data(base64Encoded: base64)
    }

    enum IdentityError: LocalizedError {
        case keychain(String, OSStatus)
        case noIdentity(itemCount: Int)

        var errorDescription: String? {
            switch self {
            case .keychain(let what, let status):
                let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
                return "\(what): \(detail)"
            case .noIdentity(let n):
                return "host credentials imported (\(n) items) but no usable TLS identity resulted"
            }
        }
    }
}
