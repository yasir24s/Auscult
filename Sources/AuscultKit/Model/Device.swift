import Foundation

/// How we can currently reach a device.
public enum LinkKind: String, Codable, Sendable, CaseIterable {
    case usb          // wired, usbmuxd / CoreDevice USB
    case localNetwork // Wi-Fi / paired network tunnel
    case sameMachine  // simulator
    case unknown
}

public enum PairingState: String, Codable, Sendable {
    case paired, unpaired, pairingRequested, unknown
}

/// The class of thing we're talking to. Diagnostics differ per family.
public enum DeviceFamily: String, Codable, Sendable {
    case iPhone, iPad, iPod, appleTV, appleWatch, appleVision, mac, unknown

    /// Simulators can never yield hardware truth — only software checks apply.
    public var isPhysicalCandidate: Bool { self != .unknown }
}

/// Immutable-ish identity + state snapshot of a target device.
///
/// Every field is optional on purpose. A new iOS beta may rename, move, or drop
/// any key in Apple's output; a missing field must degrade one metric, never
/// fail the whole run.
public struct DeviceSnapshot: Codable, Sendable, Identifiable, Hashable {
    // Identity
    public var id: String                 // stable key: udid, else ecid, else identifier
    public var coreDeviceIdentifier: String?
    public var udid: String?
    public var ecid: String?
    public var serialNumber: String?
    public var name: String?

    // Hardware
    public var family: DeviceFamily = .unknown
    public var productType: String?        // "iPhone18,2"
    public var marketingName: String?      // "iPhone 17 Pro Max"
    public var hardwareModel: String?      // board id, e.g. "D94AP"
    public var chipName: String?           // "arm64e"
    public var physicalCores: Int?
    public var logicalCores: Int?
    public var storageCapacityBytes: Int64?
    public var supportedBiometrics: [String] = []
    public var hasActionButton: Bool?
    public var isSimulator: Bool = false

    // Software
    public var osName: String?             // "iOS"
    public var osVersion: String?          // "27.0"
    public var osBuild: String?            // "24A5418b"
    public var osTrainProgram: String?
    public var releaseType: String?        // "Beta" / nil for public

    // Security / trust posture
    public var isProductionFused: Bool?
    public var developerModeEnabled: Bool?
    public var rootFileSystemIsWritable: Bool?
    public var hasInternalOSBuild: Bool?
    public var bootState: String?
    public var ddiServicesAvailable: Bool?

    // Link
    public var link: LinkKind = .unknown
    public var pairing: PairingState = .unknown
    public var tunnelState: String?
    public var lastSeen: Date?

    public init(id: String) { self.id = id }

    /// True when Apple itself flags this as a prerelease build, by any signal.
    /// Build letters after the train letter (e.g. `24A5418b`) mark seeds.
    public var isPrereleaseOS: Bool {
        if let r = releaseType?.lowercased(), r.contains("beta") || r.contains("seed") { return true }
        if hasInternalOSBuild == true { return true }
        guard let b = osBuild else { return false }
        // Seed builds carry a 4-digit-or-more revision, e.g. 24A5418b vs 24A348.
        let digits = b.drop { !$0.isNumber }.prefix { $0.isNumber }
        if let rev = b.dropFirst(digits.count).first, rev.isLetter {
            let tail = b.dropFirst(digits.count + 1).prefix { $0.isNumber }
            return tail.count >= 4
        }
        return false
    }

    public var displayName: String {
        name ?? marketingName ?? productType ?? id
    }

    public var osDescription: String {
        let v = [osName, osVersion].compactMap { $0 }.joined(separator: " ")
        guard let b = osBuild else { return v.isEmpty ? "unknown OS" : v }
        return v.isEmpty ? b : "\(v) (\(b))"
    }
}
