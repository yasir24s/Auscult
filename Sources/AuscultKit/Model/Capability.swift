import Foundation

/// A named ability a transport can offer and a probe can require.
///
/// This is the core of Auscult's version-independence. Nothing in the codebase
/// branches on an iOS version number; instead transports *probe* for what they
/// can actually do against the device in front of them and advertise the result.
/// A new beta that moves a service breaks one capability, not the app.
public struct Capability: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public init(_ value: String) { self.rawValue = value }
}

public extension Capability {
    // --- Host-side, Apple-native (CoreDevice / devicectl) -------------------
    /// Enumerate devices and read identity/software/state properties.
    static let deviceIdentity: Capability   = "device.identity"
    /// Display geometry and refresh info.
    static let displayInfo: Capability      = "device.displays"
    /// Running process list.
    static let processList: Capability      = "device.processes"
    /// Installed application inventory.
    static let appInventory: Capability     = "device.apps"
    /// Screenshot capture.
    static let screenCapture: Capability    = "device.capture"
    /// Trigger and retrieve a full sysdiagnose archive.
    static let sysdiagnose: Capability      = "device.sysdiagnose"
    /// Developer disk image service availability.
    static let ddiServices: Capability      = "device.ddi"

    // --- Host-side, Configurator (cfgutil) ----------------------------------
    /// Per-category disk usage, IMEI/ICCID, MAC addresses, battery capacity.
    static let configuratorProperties: Capability = "cfgutil.properties"

    // --- Host-side, deep lockdown / RemoteXPC services ----------------------
    /// Raw IORegistry traversal. Where battery gas-gauge truth lives.
    static let ioRegistry: Capability       = "lockdown.ioregistry"
    /// MobileGestalt key queries.
    static let mobileGestalt: Capability    = "lockdown.gestalt"
    /// Battery gas gauge (cycle count, raw capacity, cell voltages).
    static let batteryGauge: Capability     = "diag.battery"
    /// NAND lifetime / wear statistics.
    static let nandStats: Capability        = "diag.nand"
    /// Wi-Fi radio diagnostics.
    static let wifiDiag: Capability         = "diag.wifi"
    /// Kernel panic and crash log retrieval.
    static let crashLogs: Capability        = "lockdown.crashlogs"
    /// Live syslog stream.
    static let syslog: Capability           = "lockdown.syslog"
    /// Storage totals via AFC.
    static let fileConduit: Capability      = "lockdown.afc"

    // --- On-device agent ----------------------------------------------------
    /// The Auscult agent is installed and reachable.
    static let agentLink: Capability        = "agent.link"
    /// Motion sensor suite (accel, gyro, magnetometer, barometer).
    static let agentMotion: Capability      = "agent.motion"
    /// Camera enumeration and per-lens capture.
    static let agentCameras: Capability     = "agent.cameras"
    /// Speaker output and microphone capture loopback.
    static let agentAudio: Capability       = "agent.audio"
    /// Full-screen display sweep and touch digitizer grid.
    static let agentDisplay: Capability     = "agent.display"
    /// Haptic engine exercise.
    static let agentHaptics: Capability     = "agent.haptics"
    /// GNSS fix acquisition.
    static let agentLocation: Capability    = "agent.location"
    /// Biometric enrolment and sensor presence.
    static let agentBiometrics: Capability  = "agent.biometrics"
    /// Sustained-load thermal and throttle curve.
    static let agentThermal: Capability     = "agent.thermal"
    /// Radio scan counts (BT / Wi-Fi).
    static let agentRadios: Capability      = "agent.radios"
}
