import Foundation
import CoreBluetooth
import CoreLocation
import UIKit

// MARK: - Bluetooth

/// Verifies the Bluetooth radio can power on and actually receive.
///
/// Powering on only proves the controller responds. Receiving advertisements
/// proves the antenna path works, which is the part that physically fails. In
/// any normal environment there are several BLE advertisers within range, so
/// hearing nothing at all is a meaningful signal — though it is reported as a
/// warning rather than a failure, because a shielded room is possible.
struct BluetoothScanTest: AgentTest {
    var descriptor: AgentTestDescriptor {
        let status = CBManager.authorization
        return AgentTestDescriptor(
            id: "radio.bluetooth", title: "Bluetooth Radio",
            section: "Radios",
            permission: .bluetooth,
            permissionGranted: status == .allowedAlways,
            estimatedSeconds: 12,
            unavailableReason: status == .denied || status == .restricted
                ? "Bluetooth access is denied — enable it in Settings › Privacy › Bluetooth"
                : nil
        )
    }

    func run(context: AgentTestContext) async throws -> AgentTestResult {
        context.progress(0.1, "Powering on the Bluetooth radio")
        let scanner = BluetoothScanner()
        let outcome = await scanner.scan(seconds: 8) { fraction, message in
            context.progress(0.1 + fraction * 0.85, message)
        }

        var metrics: [AgentMetric] = [
            .reading("state", "Controller state", outcome.stateDescription),
        ]

        switch outcome.state {
        case .poweredOn:
            metrics.append(.flag("poweredOn", "Radio powered on", true, shouldBe: true))
            // Anything at all proves the receive path; the count is context.
            metrics.append(.graded(
                "peripherals", "Advertisers heard", Double(outcome.peripheralCount),
                warnAt: 1, failAt: 0, higherIsBetter: true,
                note: outcome.peripheralCount == 0
                    ? "the radio powered on but heard nothing in 8 s — "
                      + "possible antenna fault, or genuinely nothing nearby"
                    : "proves the receive path works",
                expectation: "at least one in any normal environment"
            ))
            if let strongest = outcome.strongestRSSI {
                metrics.append(.number("strongestRSSI", "Strongest signal",
                                       Double(strongest), unit: "dBm",
                                       note: "closest advertiser heard"))
            }
            if !outcome.names.isEmpty {
                metrics.append(.list("names", "Named devices seen",
                                     Array(outcome.names.prefix(8))))
            }
        case .poweredOff:
            metrics.append(.flag("poweredOn", "Radio powered on", false,
                                 shouldBe: true, severityIfNot: .skipped,
                                 note: "Bluetooth is switched off — enable it and re-run"))
        case .unauthorized:
            return result(.skipped, "Bluetooth access was not granted",
                          detail: "enable it in Settings › Privacy › Bluetooth")
        case .unsupported:
            return result(.fail, "This device reports no Bluetooth support", metrics: metrics)
        default:
            metrics.append(.flag("poweredOn", "Radio powered on", false,
                                 shouldBe: true, severityIfNot: .warn,
                                 note: "the controller never reached a usable state"))
        }

        let verdict = rollup(metrics)
        let summary = outcome.state == .poweredOn
            ? "Radio on, \(outcome.peripheralCount) advertiser\(outcome.peripheralCount == 1 ? "" : "s") heard in 8 s"
            : "Radio state: \(outcome.stateDescription)"
        return result(verdict, summary, metrics: metrics)
    }
}

/// Drives `CBCentralManager` for a fixed window.
private final class BluetoothScanner: NSObject, CBCentralManagerDelegate {
    struct Outcome {
        var state: CBManagerState = .unknown
        var peripheralCount = 0
        var strongestRSSI: Int?
        var names: [String] = []

        var stateDescription: String {
            switch state {
            case .poweredOn: "powered on"
            case .poweredOff: "powered off"
            case .unauthorized: "unauthorised"
            case .unsupported: "unsupported"
            case .resetting: "resetting"
            default: "unknown"
            }
        }
    }

    private var manager: CBCentralManager?
    private var seen: Set<UUID> = []
    private var outcome = Outcome()
    private let lock = NSLock()

    func scan(
        seconds: TimeInterval, progress: @escaping (Double, String) -> Void
    ) async -> Outcome {
        manager = CBCentralManager(delegate: self, queue: DispatchQueue(label: "auscult.bt"))

        // Wait for the controller to settle before scanning; state starts
        // .unknown and only becomes meaningful after the first callback.
        let settleDeadline = Date().addingTimeInterval(3)
        while Date() < settleDeadline {
            if lock.withLock({ outcome.state }) != .unknown { break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        if lock.withLock({ outcome.state }) == .poweredOn {
            manager?.scanForPeripherals(withServices: nil, options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: false
            ])
            let start = Date()
            while Date().timeIntervalSince(start) < seconds {
                let elapsed = Date().timeIntervalSince(start)
                let count = lock.withLock { outcome.peripheralCount }
                progress(elapsed / seconds, "Scanning — \(count) heard")
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            manager?.stopScan()
        }

        let result = lock.withLock { outcome }
        manager = nil
        return result
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        lock.withLock { outcome.state = central.state }
    }

    func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        lock.withLock {
            guard seen.insert(peripheral.identifier).inserted else { return }
            outcome.peripheralCount = seen.count
            let rssi = RSSI.intValue
            // 127 is CoreBluetooth's "not available" sentinel, not a signal.
            if rssi != 127, outcome.strongestRSSI.map({ rssi > $0 }) ?? true {
                outcome.strongestRSSI = rssi
            }
            if let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String {
                outcome.names.append(name)
            }
        }
    }
}

// MARK: - Location

/// Measures how long the GNSS receiver takes to produce a usable fix.
///
/// Time to first fix is the figure that exposes a degraded antenna: a healthy
/// receiver with a warm almanac fixes in seconds, while a failing one either
/// takes minutes or never converges below a useful accuracy. Reported alongside
/// the accuracy achieved, because a fast fix at 3 km accuracy is not a fix.
struct LocationFixTest: AgentTest {
    var descriptor: AgentTestDescriptor {
        let status = CLLocationManager().authorizationStatus
        let granted = status == .authorizedWhenInUse || status == .authorizedAlways
        return AgentTestDescriptor(
            id: "radio.location", title: "GNSS Receiver",
            section: "Radios",
            permission: .location,
            permissionGranted: granted,
            estimatedSeconds: 35,
            unavailableReason: status == .denied || status == .restricted
                ? "location access is denied — enable it in Settings › Privacy › Location Services"
                : (CLLocationManager.locationServicesEnabled()
                    ? nil : "Location Services are switched off device-wide")
        )
    }

    func run(context: AgentTestContext) async throws -> AgentTestResult {
        let locator = LocationFixer()

        if locator.needsAuthorization {
            context.awaitingUser("Allow location access on the device to test the GNSS receiver")
            await locator.requestAuthorization()
        }
        guard locator.isAuthorized else {
            return result(.skipped, "Location access was not granted",
                          detail: "enable it in Settings › Privacy › Location Services and re-run")
        }

        context.progress(0.1, "Waiting for a position fix")
        let outcome = await locator.awaitFix(timeout: 30) { fraction, message in
            context.progress(0.1 + fraction * 0.85, message)
        }

        var metrics: [AgentMetric] = []

        guard let fix = outcome.best else {
            metrics.append(.flag("fixAcquired", "Fix acquired", false,
                                 shouldBe: true, severityIfNot: .fail,
                                 note: "no position in 30 s — indoors this is common, "
                                     + "but outdoors it points at the GNSS antenna"))
            if let error = outcome.errorDescription {
                metrics.append(.reading("error", "Reported error", error))
            }
            return result(rollup(metrics), "No fix within 30 seconds", metrics: metrics)
        }

        metrics.append(.flag("fixAcquired", "Fix acquired", true, shouldBe: true))
        metrics.append(.graded(
            "timeToFix", "Time to first fix", outcome.secondsToFix, unit: "s",
            warnAt: 15, failAt: 28, higherIsBetter: false,
            note: "from a cold start this is legitimately slower",
            expectation: "under 15 s with a warm almanac"
        ))
        metrics.append(.graded(
            "accuracy", "Horizontal accuracy", fix.horizontalAccuracy, unit: "m",
            warnAt: 65, failAt: 300, higherIsBetter: false,
            note: fix.horizontalAccuracy > 100
                ? "this coarse a figure usually means Wi-Fi positioning, not GNSS"
                : nil,
            expectation: "under 20 m outdoors with a clear sky"
        ))
        if fix.verticalAccuracy > 0 {
            metrics.append(.number("altitude", "Altitude", fix.altitude, unit: "m",
                                   note: "±\(fix.verticalAccuracy.clean) m"))
        }
        metrics.append(.number("updates", "Position updates received",
                               Double(outcome.updateCount)))
        // Deliberately not reporting latitude and longitude: a diagnostic report
        // gets pasted into tickets, and the device's location is not a fault
        // symptom. Accuracy is what matters here.
        metrics.append(.reading("privacy", "Coordinates",
                                "withheld from the report by design"))

        let verdict = rollup(metrics)
        return result(verdict,
                      "Fix in \(outcome.secondsToFix.clean) s at ±\(fix.horizontalAccuracy.clean) m",
                      metrics: metrics)
    }
}

private final class LocationFixer: NSObject, CLLocationManagerDelegate {
    struct Outcome {
        var best: CLLocation?
        var secondsToFix: Double = 0
        var updateCount = 0
        var errorDescription: String?
    }

    private let manager = CLLocationManager()
    private let lock = NSLock()
    private var outcome = Outcome()
    private var started = Date()
    private var authorizationContinuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    var isAuthorized: Bool {
        let status = manager.authorizationStatus
        return status == .authorizedWhenInUse || status == .authorizedAlways
    }

    var needsAuthorization: Bool { manager.authorizationStatus == .notDetermined }

    func requestAuthorization() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            authorizationContinuation = c
            manager.requestWhenInUseAuthorization()
            // Don't hang forever if the prompt is dismissed without an answer.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                self.resumeAuthorization()
            }
        }
    }

    private func resumeAuthorization() {
        lock.lock()
        let continuation = authorizationContinuation
        authorizationContinuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func awaitFix(
        timeout: TimeInterval, progress: @escaping (Double, String) -> Void
    ) async -> Outcome {
        started = Date()
        manager.startUpdatingLocation()
        defer { manager.stopUpdatingLocation() }

        while Date().timeIntervalSince(started) < timeout {
            let snapshot = lock.withLock { outcome }
            // A fix accurate to 20 m is good enough to stop early; waiting for
            // better wastes half a minute of the operator's time.
            if let best = snapshot.best, best.horizontalAccuracy <= 20 { break }
            let elapsed = Date().timeIntervalSince(started)
            let status = snapshot.best.map { "±\($0.horizontalAccuracy.clean) m" } ?? "no fix yet"
            progress(elapsed / timeout, "Acquiring — \(status)")
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return lock.withLock { outcome }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus != .notDetermined { resumeAuthorization() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        lock.withLock {
            for location in locations where location.horizontalAccuracy > 0 {
                outcome.updateCount += 1
                if outcome.best == nil {
                    outcome.secondsToFix = Date().timeIntervalSince(started)
                }
                if let best = outcome.best {
                    if location.horizontalAccuracy < best.horizontalAccuracy {
                        outcome.best = location
                    }
                } else {
                    outcome.best = location
                }
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        lock.withLock { outcome.errorDescription = error.localizedDescription }
    }
}

// MARK: - Power context

/// The device-side settings that determine how fast the battery goes down.
///
/// The Mac can measure how much power is being consumed but not *why*. These
/// are the on-device factors that dominate it — screen brightness above all,
/// then Low Power Mode and thermal state — and they are exactly what someone
/// investigating a drain complaint needs to see next to the wattage.
struct PowerContextTest: AgentTest {
    var descriptor: AgentTestDescriptor {
        AgentTestDescriptor(id: "power.context", title: "Power Context",
                            section: "Power & Battery", estimatedSeconds: 2)
    }

    func run(context: AgentTestContext) async throws -> AgentTestResult {
        context.progress(0.4, "Reading power settings")

        let (brightness, batteryLevel, batteryState) = await MainActor.run {
            UIDevice.current.isBatteryMonitoringEnabled = true
            let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen
            return (
                Double(screen?.brightness ?? -1),
                Double(UIDevice.current.batteryLevel),
                UIDevice.current.batteryState
            )
        }

        var metrics: [AgentMetric] = []

        if brightness >= 0 {
            // The display is the single largest consumer on a modern phone; at
            // full brightness a large OLED alone can exceed 2 W.
            metrics.append(.graded(
                "brightness", "Screen brightness", brightness * 100, unit: "%",
                warnAt: 70, failAt: 95, higherIsBetter: false,
                note: "the display is usually the largest single consumer; "
                    + "above 70% it dominates everything else",
                expectation: "under 70% for all-day battery"
            ))
        }

        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        metrics.append(.flag("lowPowerMode", "Low Power Mode", lowPower,
                             note: lowPower
                                ? "active — the device is already throttling to save power"
                                : "off"))

        let thermal = ProcessInfo.processInfo.thermalState
        let thermalName = switch thermal {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
        metrics.append(AgentMetric(
            id: "thermalState", label: "Thermal state", kind: .string, raw: thermalName,
            verdict: thermal == .nominal || thermal == .fair ? .pass : .warn,
            note: thermal == .nominal || thermal == .fair
                ? nil
                : "a hot device burns more power and throttles"
        ))

        if batteryLevel >= 0 {
            metrics.append(.number("batteryLevel", "Battery level",
                                   batteryLevel * 100, unit: "%"))
        }
        let stateName = switch batteryState {
        case .charging: "charging"
        case .full: "full"
        case .unplugged: "on battery"
        default: "unknown"
        }
        metrics.append(.reading("batteryState", "Charging state", stateName))

        // Background App Refresh being on device-wide is the usual explanation
        // for a phone that drains while apparently doing nothing.
        let refreshStatus = await MainActor.run { UIApplication.shared.backgroundRefreshStatus }
        let refreshName = switch refreshStatus {
        case .available: "enabled"
        case .denied: "disabled"
        case .restricted: "restricted"
        @unknown default: "unknown"
        }
        metrics.append(AgentMetric(
            id: "backgroundRefresh", label: "Background App Refresh",
            kind: .string, raw: refreshName, verdict: .info,
            note: refreshStatus == .available
                ? "enabled device-wide — the usual cause of drain while idle. "
                  + "Settings › General › Background App Refresh lists the apps using it"
                : nil
        ))

        let verdict = rollup(metrics)
        var parts: [String] = []
        if brightness >= 0 { parts.append("brightness \((brightness * 100).clean)%") }
        parts.append(lowPower ? "Low Power Mode on" : "thermal \(thermalName)")
        return result(verdict, parts.joined(separator: ", "), metrics: metrics)
    }
}
