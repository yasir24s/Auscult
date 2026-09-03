import Foundation

/// Battery condition.
///
/// Two very different data paths feed this probe. The gas gauge (via the
/// diagnostics relay) is the real thing: cycle count, raw maximum capacity, cell
/// voltage, manufacture date — the same registers Apple's own service tools
/// read. Configurator only offers the current charge level, which says nothing
/// about health. The probe uses whichever it has and is explicit about the
/// difference, because reporting "94%" without saying whether that's *charge* or
/// *health* is worse than reporting nothing.
public struct BatteryProbe: Probe {
    public let id = "battery"
    public let title = "Battery"
    public let section = ReportSection.power
    public let requiredCapabilities: Set<Capability> = []
    public var anyCapabilities: Set<Capability> { [.batteryGauge, .configuratorProperties] }
    public var applicableFamilies: Set<DeviceFamily> { [.iPhone, .iPad, .iPod, .appleWatch] }

    public init() {}

    public func run(device: DeviceSnapshot, router: TransportRouter) async throws -> ProbeResult {
        var metrics: [Metric] = []
        var haveGauge = false

        // --- Preferred path: the gas gauge itself ---------------------------
        let gauge = await router.tryFetch(.batteryGauge, for: device)
        if gauge.exists {
            haveGauge = true
            metrics.append(contentsOf: Self.gaugeMetrics(gauge, device: device))
        }

        // --- Supplementary path: Configurator ------------------------------
        let cfg = await router.tryFetch(
            .configuratorProperties(["batteryCurrentCapacity", "batteryIsCharging"]),
            for: device
        )
        if let charge = cfg.batteryCurrentCapacity.double {
            metrics.append(Metric(
                id: "charge", label: "Current charge",
                value: .double(charge), unit: "%", verdict: .info,
                note: "state of charge, not battery health"
            ))
        }
        if let charging = cfg.batteryIsCharging.bool {
            metrics.append(.reading("charging", "Charging", .bool(charging)))
        }

        if !haveGauge {
            metrics.append(.absent("health", "Battery health",
                why: "the gas gauge is only readable through the diagnostics relay — "
                   + "connect over USB so the lockdown transport can reach it"))
            metrics.append(.absent("cycles", "Cycle count",
                why: "requires diagnostics relay access over USB"))
        }

        guard !metrics.isEmpty else {
            return result(.unsupported, "No battery data available from any transport")
        }

        let verdict = rollup(metrics)
        let summary: String
        if case .double(let health)? = metrics.first(where: { $0.id == "health" })?.value {
            var parts = ["\(health.clean)% of original capacity"]
            if let cycles = metrics.first(where: { $0.id == "cycles" }) {
                parts.append("\(cycles.value.description) cycles")
            }
            summary = parts.joined(separator: ", ")
        } else if let cycles = metrics.first(where: { $0.id == "cycles" }) {
            // Cycle count without capacity figures: the thin gauge route.
            summary = "\(cycles.value.description) cycles — capacity figures unavailable"
        } else if let charge = metrics.first(where: { $0.id == "charge" })?.formattedValue {
            summary = "Charge \(charge) — health requires diagnostics relay access over USB"
        } else {
            summary = "Partial battery data only"
        }
        return result(verdict, summary, metrics: metrics)
    }

    /// Interpret an `AppleSmartBattery`-shaped tree.
    ///
    /// Every value is looked up by key search rather than by path, because the
    /// same field lives at different depths depending on release — capacity
    /// figures sit under `BatteryData` on current iOS but at the top level on
    /// older versions, and the charger moved into `ChargerData`. Searching by
    /// name finds them either way, so a reshuffle in a future seed costs
    /// nothing.
    static func gaugeMetrics(_ g: DynamicValue, device: DeviceSnapshot) -> [Metric] {
        var metrics: [Metric] = []

        func number(_ aliases: String...) -> Double? {
            for a in aliases {
                if let v = g.search(forKey: a).double { return v }
            }
            return nil
        }

        // --- Health -------------------------------------------------------
        let design = number("DesignCapacity")
            ?? BatteryReference.designCapacity(forProductType: device.productType).map(Double.init)
        let nominal = number("NominalChargeCapacity")
        let fullCharge = number("FullChargeCapacity")

        if let design, design > 0 {
            // NominalChargeCapacity is the conservative, unsmoothed measure and
            // the one that tracks real degradation. FullChargeCapacity runs a
            // few points higher; iOS's own "Maximum Capacity" is rounded again
            // on top of that. Report the strict figure and show the others so
            // the difference is visible rather than hidden.
            if let measured = nominal ?? fullCharge {
                let health = min(measured / design * 100, 100)
                metrics.append(.graded(
                    "health", "Battery health", health, unit: "%",
                    warnAt: 85, failAt: 79, higherIsBetter: true,
                    note: nominal != nil
                        ? "nominal charge capacity vs design"
                        : "full charge capacity vs design",
                    expectation: "Apple considers replacement below 80%"
                ))
            }
            metrics.append(.reading("designCapacity", "Design capacity",
                .int(Int64(design)), unit: "mAh"))
            if let fullCharge {
                metrics.append(.reading("fullChargeCapacity", "Full charge capacity",
                    .int(Int64(fullCharge)), unit: "mAh"))
            }
            if let nominal {
                metrics.append(.reading("nominalCapacity", "Nominal charge capacity",
                    .int(Int64(nominal)), unit: "mAh"))
            }
        }

        if let reported = number("MaxCapacity") {
            metrics.append(.reading("maxCapacityReported", "Maximum capacity (as iOS shows it)",
                .double(reported), unit: "%",
                note: "rounded by iOS; compare with the computed health above"))
        }

        // --- Wear ---------------------------------------------------------
        if let cycles = number("CycleCount") {
            // Apple rates recent iPhone cells at 80% capacity after 1000 cycles.
            metrics.append(.graded(
                "cycles", "Cycle count", cycles, unit: "cycles",
                warnAt: 800, failAt: 1000, higherIsBetter: false,
                expectation: "rated to 1000 cycles"
            ))
        }

        if let installed = g.search(forKey: "BatteryInstalled").bool {
            metrics.append(.expected("installed", "Battery detected", installed,
                shouldBe: true, severityIfNot: .fail,
                note: installed ? nil : "no pack reported on the bus"))
        }

        if let serial = g.search(forKey: "Serial").string
            ?? g.search(forKey: "BatterySerialNumber").string {
            metrics.append(.reading("batterySerial", "Battery serial", .string(serial)))
        }

        // --- Live electrical state ----------------------------------------
        if let mv = number("Voltage", "AppleRawBatteryVoltage") {
            // A healthy Li-ion cell sits between roughly 3.2 V and 4.5 V.
            let volts = mv / 1000
            metrics.append(.graded(
                "voltage", "Cell voltage", volts, unit: "V",
                warnAt: 3.4, failAt: 3.1, higherIsBetter: true,
                note: "varies with state of charge",
                expectation: "3.2–4.5 V in normal operation"
            ))
        }
        if let amps = number("InstantAmperage", "Amperage") {
            metrics.append(.reading("amperage", "Current flow",
                .double(amps), unit: "mA",
                note: amps >= 0 ? "into the battery" : "out of the battery"))
        }
        if let temp = number("Temperature", "VirtualTemperature",
                             "AverageBattVirtualTemp", "AverageBattSkinTemp") {
            // Reported in centi-degrees on some generations, whole °C on others.
            let celsius = temp > 200 ? temp / 100 : temp
            metrics.append(.graded(
                "temperature", "Cell temperature", celsius, unit: "°C",
                warnAt: 38, failAt: 45, higherIsBetter: false,
                expectation: "under 38 °C in normal use"
            ))
        }

        // --- Faults -------------------------------------------------------
        if let disconnects = number("BatteryCellDisconnectCount") {
            metrics.append(.graded(
                "cellDisconnects", "Cell disconnect events", disconnects,
                warnAt: 1, failAt: 5, higherIsBetter: false,
                note: disconnects > 0 ? "the pack has dropped off the bus" : nil,
                expectation: "should be 0"
            ))
        }
        // An unexpected power-off is the classic symptom of a cell that can no
        // longer hold up under peak load.
        if let upo = number("ShutDownUpoReboot") {
            metrics.append(.graded(
                "unexpectedShutdowns", "Unexpected power-off reboots", upo,
                warnAt: 1, failAt: 3, higherIsBetter: false,
                // Only explain the failure mode when it has actually occurred;
                // attaching it to a zero reads as though it had.
                note: upo > 0 ? "the cell could not sustain peak load" : nil,
                expectation: "should be 0"
            ))
        }

        // --- Charging -----------------------------------------------------
        if let watts = number("Watts") {
            var note = "negotiated adapter power"
            if let desc = g.search(forKey: "Description").string { note = desc }
            metrics.append(.reading("adapterWatts", "Adapter power",
                .double(watts), unit: "W", note: note))
        }
        if let thermalLimited = number("TimeChargingThermallyLimited") {
            metrics.append(.graded(
                "chargeThermalLimit", "Charging thermally limited", thermalLimited,
                unit: "s", warnAt: 1, failAt: 600, higherIsBetter: false,
                note: thermalLimited > 0
                    ? "charge rate was reduced because of heat" : nil,
                expectation: "should be 0 on a cool device"
            ))
        }
        if let slow = number("SlowChargingReason"), slow != 0 {
            metrics.append(Metric(
                id: "slowCharging", label: "Slow-charging reason",
                value: .int(Int64(slow)), verdict: .info,
                note: "device is limiting charge rate (PMU reason code)"
            ))
        }

        return metrics
    }
}

/// Design capacities for models where the gauge doesn't report one.
///
/// Some devices return a zero or absent `DesignCapacity`, which would make the
/// health calculation divide by nothing. This table is a fallback only, and
/// deliberately small: a missing entry costs one metric, and the gauge's own
/// value always wins.
public enum BatteryReference {
    /// productType → design capacity in mAh
    static let table: [String: Int] = [
        // iPhone 15 family
        "iPhone15,4": 3349, "iPhone15,5": 4383, "iPhone16,1": 3274, "iPhone16,2": 4441,
        // iPhone 16 family
        "iPhone17,3": 3561, "iPhone17,4": 4006, "iPhone17,1": 3582, "iPhone17,2": 4685,
        "iPhone17,5": 4006,
        // iPhone 17 family
        "iPhone18,3": 3692, "iPhone18,1": 3988, "iPhone18,2": 4823,
        // iPhone 14 family
        "iPhone14,7": 3279, "iPhone14,8": 4325, "iPhone15,2": 3200, "iPhone15,3": 4323,
        // iPhone 13 / SE
        "iPhone14,5": 3227, "iPhone14,2": 3095, "iPhone14,3": 4352, "iPhone14,4": 2406,
        "iPhone14,6": 2018,

        // Apple Watch. Two orders of magnitude smaller than a phone, which is
        // why every threshold that touches these has to be family-aware.
        "Watch6,14": 282, "Watch6,15": 308,      // Series 9 41 / 45 mm
        "Watch6,16": 282, "Watch6,17": 308,
        "Watch7,1": 327, "Watch7,2": 355,        // Series 10 42 / 46 mm
        "Watch7,3": 327, "Watch7,4": 355,
        "Watch6,18": 564,                        // Ultra 2
        "Watch7,5": 564,
        "Watch6,10": 245, "Watch6,11": 296,      // SE 2 40 / 44 mm
    ]

    public static func designCapacity(forProductType type: String?) -> Int? {
        guard let type else { return nil }
        return table[type]
    }
}
