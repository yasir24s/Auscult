import Foundation

/// A unit of data a probe asks for, independent of how it's obtained.
///
/// Probes speak only in requests; they never know whether the answer came from
/// `devicectl`, `cfgutil`, a lockdown service, or the on-device agent. That
/// indirection is what lets a transport be swapped or repaired without touching
/// a single probe.
public enum TransportRequest: Sendable, Hashable {
    /// Full identity/software/state property tree.
    case deviceDetails
    /// Display geometry and refresh characteristics.
    case displays
    /// Running process list.
    case processes
    /// Installed app inventory.
    case apps
    /// Developer disk image service listing.
    case ddiServices
    /// Named Configurator properties.
    case configuratorProperties([String])
    /// IORegistry subtree by entry name and/or plane.
    case ioRegistry(entryName: String?, plane: String?)
    /// MobileGestalt keys.
    case mobileGestalt(keys: [String])
    /// Battery gas-gauge dictionary.
    case batteryGauge
    /// NAND lifetime statistics.
    case nandStatistics
    /// Wi-Fi radio diagnostics.
    case wifiDiagnostics
    /// Listing of crash/panic log filenames.
    case crashLogIndex
    /// Contents of one crash/panic log.
    case crashLog(name: String)
    /// Storage totals.
    case storageTotals

    public var requiredCapability: Capability {
        switch self {
        case .deviceDetails: .deviceIdentity
        case .displays: .displayInfo
        case .processes: .processList
        case .apps: .appInventory
        case .ddiServices: .ddiServices
        case .configuratorProperties: .configuratorProperties
        case .ioRegistry: .ioRegistry
        case .mobileGestalt: .mobileGestalt
        case .batteryGauge: .batteryGauge
        case .nandStatistics: .nandStats
        case .wifiDiagnostics: .wifiDiag
        case .crashLogIndex, .crashLog: .crashLogs
        case .storageTotals: .fileConduit
        }
    }
}

public enum TransportError: LocalizedError {
    case unavailable(String)
    case unsupportedRequest(TransportRequest, transport: String)
    case noTransport(Capability)
    case deviceUnreachable(String)
    case malformedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let t): "\(t) is not available on this host"
        case .unsupportedRequest(_, let t): "\(t) cannot serve that request"
        case .noTransport(let c): "No available transport provides '\(c.rawValue)'"
        case .deviceUnreachable(let d): "Device \(d) is not reachable"
        case .malformedResponse(let d): "Unexpected response shape: \(d)"
        }
    }
}

/// One way of talking to iOS devices.
public protocol DeviceTransport: Sendable {
    /// Stable machine identifier, used in report provenance.
    var identifier: String { get }
    /// Human label for the UI.
    var displayName: String { get }
    /// Lower runs first when several transports can serve the same capability.
    var priority: Int { get }

    /// Is the underlying tooling present and functional on this host?
    func probeAvailability() async -> TransportAvailability

    /// Devices this transport can see. May be empty.
    func discover() async throws -> [DeviceSnapshot]

    /// What this transport can actually do for *this* device, right now.
    func capabilities(for device: DeviceSnapshot) async -> Set<Capability>

    /// Serve a request. Throw `.unsupportedRequest` if out of scope.
    func fetch(_ request: TransportRequest, for device: DeviceSnapshot) async throws -> DynamicValue
}

public struct TransportAvailability: Sendable {
    public var isAvailable: Bool
    public var version: String?
    public var detail: String?

    public init(isAvailable: Bool, version: String? = nil, detail: String? = nil) {
        self.isAvailable = isAvailable; self.version = version; self.detail = detail
    }

    public static func no(_ reason: String) -> Self { .init(isAvailable: false, detail: reason) }
    public static func yes(_ version: String? = nil) -> Self { .init(isAvailable: true, version: version) }
}
