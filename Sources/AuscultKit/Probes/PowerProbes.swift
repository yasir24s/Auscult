import Foundation

// MARK: - Power telemetry

/// Where the battery's energy is actually going.
///
/// The PMU maintains running accumulators alongside the instantaneous
/// registers, and their ratios are the most useful drain figures available from
/// a Mac: mean system load since boot, and — separately — mean draw during the
/// periods the device was actually on battery. The second is the number that
/// answers "why does my phone not last the day", because it excludes the time
/// spent plugged in.
///
/// Units are milliwatts. That isn't an assumption: the PMU also exposes
/// `SystemCurrentIn` and `SystemVoltageIn`, and their product matches
/// `SystemPowerIn` exactly, which pins the scale.
public struct PowerTelemetryProbe: Probe {
    public let id = "power.telemetry"
    public let title = "Power Draw"
    public let section = ReportSection.power
    public let requiredCapabilities: Set<Capability> = [.batteryGauge]
    public var applicableFamilies: Set<DeviceFamily> { [.iPhone, .iPad, .iPod, .appleWatch] }

    /// Typical whole-day average for a healthy iPhone is 500–900 mW. Sustained
    /// averages far above that are what "it drains fast" actually means.
    private static let warnDischargeMilliwatts = 1500.0
    private static let failDischargeMilliwatts = 2500.0

    public init() {}

    public func run(device: DeviceSnapshot, router: TransportRouter) async throws -> ProbeResult {
        let gauge = try await router.fetch(.batteryGauge, for: device)

        func value(_ key: String) -> Double? { gauge.search(forKey: key).double }

        /// An accumulator divided by its sample count. Both must be present and
        /// the count non-zero, or the figure is meaningless rather than zero.
        func mean(_ accumulator: String, _ count: String) -> Double? {
            guard let total = value(accumulator), let n = value(count), n > 0 else { return nil }
            return abs(total) / n
        }

        var metrics: [Metric] = []

        // --- The headline: draw while running on the battery ---------------
        let dischargeMean = mean("AccumulatedBatteryDischarge", "BatteryDischargeAccumulatorCount")
        if let dischargeMean {
            metrics.append(.graded(
                "meanDischarge", "Mean draw on battery", dischargeMean, unit: "mW",
                warnAt: Self.warnDischargeMilliwatts,
                failAt: Self.failDischargeMilliwatts,
                higherIsBetter: false,
                note: "averaged over every period since boot spent unplugged",
                expectation: "a healthy iPhone averages 500–900 mW across a day"
            ))

            // Turn power into the thing people actually care about: hours.
            if let design = value("NominalChargeCapacity") ?? value("DesignCapacity") {
                // Nominal cell voltage for a modern Li-ion pack.
                let watthours = design * 3.85 / 1000
                let hours = watthours / (dischargeMean / 1000)
                metrics.append(.graded(
                    "projectedRuntime", "Projected runtime at that draw", hours, unit: "h",
                    warnAt: 8, failAt: 5, higherIsBetter: true,
                    note: "\(watthours.oneDecimal) Wh pack ÷ mean draw",
                    expectation: "a full charge should cover a working day"
                ))
            }
        } else {
            metrics.append(.absent("meanDischarge", "Mean draw on battery",
                why: "the PMU has no discharge samples yet — this device has been "
                   + "on the charger since it last booted"))
        }

        // --- Overall and instantaneous -------------------------------------
        if let systemMean = mean("AccumulatedSystemLoad", "SystemLoadAccumulatorCount") {
            metrics.append(.reading("meanSystemLoad", "Mean system load since boot",
                .double(systemMean), unit: "mW",
                note: "includes time on the charger, so it sits above the on-battery figure"))
        }
        if let load = value("SystemLoad") {
            metrics.append(.reading("systemLoadNow", "System load right now",
                .double(load), unit: "mW",
                note: "a single instant — the sampled figures below are more reliable"))
        }
        if let effective = mean("AccumSystemEffectiveTotalLoad", "AccumSystemEffectiveTotalLoadCount") {
            metrics.append(.reading("meanEffectiveLoad", "Mean effective total load",
                .double(effective), unit: "mW"))
        }

        // --- Time on battery vs on charger ---------------------------------
        if let onBattery = value("BatteryDischargeAccumulatorCount"),
           let total = value("SystemLoadAccumulatorCount"), total > 0 {
            metrics.append(.reading("timeOnBattery", "Samples taken on battery",
                .double(onBattery / total * 100), unit: "%",
                note: "how much of this boot session was spent unplugged"))
        }

        // --- Charging efficiency -------------------------------------------
        if let inMean = mean("AccumulatedSystemPowerIn", "SystemPowerInAccumulatorCount") {
            metrics.append(.reading("meanPowerIn", "Mean power drawn from the charger",
                .double(inMean), unit: "mW"))
        }
        if let loss = value("AdapterEfficiencyLoss") {
            metrics.append(.reading("adapterLoss", "Adapter conversion loss",
                .double(loss), unit: "mW"))
        }
        if let errors = value("PowerTelemetryErrorCount") {
            metrics.append(.graded(
                "telemetryErrors", "Telemetry error count", errors,
                warnAt: 1, failAt: 50, higherIsBetter: false,
                note: errors > 0 ? "the PMU reported measurement faults" : nil,
                expectation: "should be 0"
            ))
        }

        // --- The PMU's own remaining-time estimate -------------------------
        if let remaining = value("TimeRemaining"), remaining > 0, remaining < 10000 {
            metrics.append(.reading("timeRemaining", "PMU time-remaining estimate",
                .double(remaining), unit: "min"))
        }
        if let empty = value("AvgTimeToEmpty"), empty > 0, empty < 10000 {
            metrics.append(.reading("avgTimeToEmpty", "Average time to empty",
                .double(empty), unit: "min"))
        }

        guard !metrics.isEmpty else {
            return result(.unsupported, "The PMU exposed no power telemetry")
        }

        let verdict = rollup(metrics)
        let summary: String
        if let dischargeMean {
            summary = "\(dischargeMean.zeroDecimal) mW average while on battery"
        } else {
            summary = "Power telemetry read; no on-battery samples yet"
        }
        return result(verdict, summary, metrics: metrics)
    }
}

// MARK: - Live drain sampling

/// Measures current draw directly, by polling the gas gauge over time.
///
/// The accumulators above are usage-weighted history; this is a measurement of
/// right now, and it is unambiguous — signed current in milliamps multiplied by
/// cell voltage. It is the check to run when you want to know what the device
/// is doing *at this moment*, and the one to trust if the two disagree.
///
/// Reading it correctly requires knowing whether the device is on the charger,
/// so that is established first and reported rather than assumed.
public struct LiveDrainProbe: Probe {
    public let id = "power.livedrain"
    public let title = "Live Power Draw"
    public let section = ReportSection.power
    public let requiredCapabilities: Set<Capability> = [.batteryGauge]
    public var applicableFamilies: Set<DeviceFamily> { [.iPhone, .iPad, .iPod, .appleWatch] }

    private let sampleCount: Int
    private let interval: TimeInterval

    /// Idle power thresholds, in milliwatts, by device class.
    ///
    /// These cannot be one set of numbers. An Apple Watch runs its whole system
    /// on a ~1 Wh cell and idles in the tens of milliwatts; an iPad has ten
    /// times the battery and a much larger display controller. Grading a Watch
    /// against an iPhone's thresholds would call healthy hardware faulty.
    static func idleThresholds(for family: DeviceFamily) -> (warn: Double, fail: Double) {
        switch family {
        case .appleWatch: (120, 300)
        case .iPhone, .iPod: (600, 1200)
        case .iPad: (900, 1800)
        case .appleTV: (3000, 6000)   // mains powered; only a sanity bound
        default: (600, 1200)
        }
    }

    public init(sampleCount: Int = 12, interval: TimeInterval = 2.5) {
        self.sampleCount = sampleCount
        self.interval = interval
    }

    private struct Sample {
        var milliamps: Double
        var millivolts: Double
        var systemLoadMilliwatts: Double?
        var percent: Double?
        var externalConnected: Bool
        var isCharging: Bool
        /// Signed: positive into the battery, negative out of it.
        var batteryMilliwatts: Double { milliamps * millivolts / 1000 }
    }

    /// Panel luminance right now, in nits. Zero means the display is off.
    ///
    /// This is what makes the measurement trustworthy: the same 3 W means
    /// "entirely normal" with the screen on at high brightness and "something
    /// is badly wrong" with it off, and the operator's word for which it was is
    /// not good enough.
    private static func currentNits(
        device: DeviceSnapshot, router: TransportRouter
    ) async -> Double? {
        let backlight = await router.tryFetch(
            .ioRegistry(entryName: "AppleARMBacklight", plane: nil), for: device
        )
        return backlight.search(forKey: "CurrentNits").double
    }

    public func run(device: DeviceSnapshot, router: TransportRouter) async throws -> ProbeResult {
        var samples: [Sample] = []
        let nitsBefore = await Self.currentNits(device: device, router: router)

        // Establish whether the device is mid-maintenance before measuring.
        // A reboot triggers photo analysis, Spotlight indexing and iCloud sync,
        // which on a media-heavy device runs for hours at several watts — and a
        // reading taken then describes the rebuild, not the device.
        var maintenance: [String] = []
        var hoursSinceUpdate: Double?
        if let listing = try? await router.fetch(.crashLogIndex, for: device) {
            let index = DiagnosticReportIndex.parse(listing)
            maintenance = index.maintenanceInProgress()
            if let interval = index.timeSinceSoftwareUpdate(), interval < 48 * 3600 {
                hoursSinceUpdate = interval / 3600
            }
        }

        for index in 0..<sampleCount {
            if Task.isCancelled { throw CancellationError() }
            // Fresh each time: the cached response would repeat one reading.
            let gauge = try await router.fetchFresh(.batteryGauge, for: device)
            func value(_ key: String) -> Double? { gauge.search(forKey: key).double }

            if let mA = value("InstantAmperage") ?? value("Amperage"),
               let mV = value("Voltage") ?? value("AppleRawBatteryVoltage") {
                samples.append(Sample(
                    milliamps: mA,
                    millivolts: mV,
                    systemLoadMilliwatts: value("SystemLoad"),
                    percent: value("CurrentCapacity"),
                    externalConnected: (value("ExternalConnected")
                        ?? value("AppleRawExternalConnected") ?? 0) != 0,
                    isCharging: (value("IsCharging") ?? 0) != 0
                ))
            }
            if index < sampleCount - 1 {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }

        guard samples.count >= 3 else {
            return result(.unsupported,
                "Could only take \(samples.count) gauge samples",
                detail: "the device stopped answering mid-measurement")
        }

        let nitsAfter = await Self.currentNits(device: device, router: router)
        // Inside a full run the agent is foregrounded and other probes are
        // exercising the CPU, GPU and radios, which inflates this considerably.
        // Say so, and point at the command that measures properly.
        let duringDiagnosticRun = await router.has(.agentLink, for: device)
        // Screen off for the whole window is the only case where the strict
        // idle thresholds apply.
        let screenOff = (nitsBefore ?? 1) == 0 && (nitsAfter ?? 1) == 0

        let plugged = samples.filter(\.externalConnected).count > samples.count / 2
        // Active charging inflates SystemLoad substantially — the charging
        // circuitry's own consumption lands in the same figure. Measured on one
        // device: 4748 mW while charging versus 1380 mW with charging paused at
        // 95%, both with the display off. So the charging state decides whether
        // this reading can be taken at face value.
        let charging = samples.filter(\.isCharging).count > samples.count / 4
        var metrics: [Metric] = [
            .reading("sampled", "Samples taken",
                .string("\(samples.count) over \(Int(Double(samples.count) * interval))s")),
            .reading("onCharger", "On the charger", .bool(plugged)),
        ]
        if plugged {
            metrics.append(Metric(
                id: "chargingState", label: "Charging during measurement",
                value: .bool(charging),
                verdict: charging ? .warn : .pass,
                note: charging
                    ? "the charging circuit's own consumption is included below, inflating it — "
                      + "measure again near 100% when charging pauses, or unplugged"
                    : "charging is paused, so this is the device's own consumption"
            ))
        }
        if let hours = hoursSinceUpdate {
            metrics.append(Metric(
                id: "recentUpdate", label: "OS updated recently",
                value: .string(hours < 1
                    ? "\(Int(hours * 60)) minutes ago"
                    : "\(hours.oneDecimal) hours ago"),
                verdict: .warn,
                note: "an OS update forces a reboot and a full rebuild of Spotlight, "
                    + "photo analysis and iCloud state. Expect hours of elevated draw "
                    + "afterwards that says nothing about normal behaviour — allow a "
                    + "day before treating any figure as a baseline"
            ))
        }
        if !maintenance.isEmpty {
            metrics.append(Metric(
                id: "maintenance", label: "System maintenance running",
                value: .list(maintenance),
                verdict: .warn,
                note: "these rebuild indexes after a reboot or a large import and can "
                    + "run for hours on a media-heavy device. Idle draw is legitimately "
                    + "elevated while they work — re-measure once they finish"
            ))
        }
        if duringDiagnosticRun {
            metrics.append(.reading("measurementContext", "Measurement conditions",
                .string("taken during a diagnostic run"),
                note: "other tests were loading the device, so this reads high — "
                    + "use `auscult drain` with the agent closed for a clean figure"))
        }
        if let nits = nitsAfter {
            metrics.append(.reading("screenState", "Display during measurement",
                .string(screenOff ? "off" : "on (\(nits.zeroDecimal) nits)"),
                note: screenOff
                    ? "so the figures below are true idle consumption"
                    : "the display is included in the figures below and usually dominates them"))
        }

        // System load is measurable whether or not the charger is attached, so
        // it is the figure that always means something.
        // Any of these makes a reading unrepresentative of steady state.
        let disturbed = duringDiagnosticRun || charging
            || !maintenance.isEmpty || hoursSinceUpdate != nil
        let thresholds = Self.idleThresholds(for: device.family)

        let loads = samples.compactMap(\.systemLoadMilliwatts)
        if !loads.isEmpty {
            let meanLoad = loads.reduce(0, +) / Double(loads.count)
            // Two completely different yardsticks. With the panel lit, several
            // watts is expected and grading against an idle figure would flag
            // every healthy phone; with it dark, several watts is the finding.
            // While charging, this register carries charge power as well as
            // system consumption — a phone on a fast charger reported 26.8 W,
            // which is not a system load at all. Grading that produces a
            // confident FAIL about a number that measures something else, so
            // the reading is reported without a verdict instead.
            if charging {
                metrics.append(Metric(
                    id: "meanSystemLoad", label: "Mean system load (not gradeable)",
                    value: .double(meanLoad), unit: "mW", verdict: .unsupported,
                    note: "charging — this figure includes charge power and is not "
                        + "a measure of consumption. Unplug and re-run",
                    expectation: "measure unplugged, or at 100% when charging pauses"
                ))
            } else {
            metrics.append(.graded(
                "meanSystemLoad", "Mean system load", meanLoad, unit: "mW",
                // Strict thresholds only when the reading is clean: display
                // off, charging paused, and no diagnostic load.
                warnAt: screenOff
                    ? (disturbed ? thresholds.warn * 4 : thresholds.warn)
                    : thresholds.warn * 5,
                failAt: screenOff
                    ? (disturbed ? thresholds.fail * 4 : thresholds.fail)
                    : thresholds.fail * 4,
                higherIsBetter: false,
                note: screenOff
                    ? (charging
                        ? "display off, but charging inflates this — re-measure with charging paused"
                        : "display off and not charging, so this is what the device consumes doing nothing")
                    : "display on, so most of this is the panel",
                expectation: screenOff
                    ? "an idle \(device.family.rawValue) with the screen off should stay "
                      + "under \(thresholds.warn.zeroDecimal) mW"
                    : "several times the idle figure is normal with the screen on"
            ))
            }
            metrics.append(.reading("peakSystemLoad", "Peak system load",
                .double(loads.max() ?? 0), unit: "mW"))
            metrics.append(.reading("minSystemLoad", "Lowest system load",
                .double(loads.min() ?? 0), unit: "mW"))
        }

        let batteryPower = samples.map(\.batteryMilliwatts)
        let meanBattery = batteryPower.reduce(0, +) / Double(batteryPower.count)

        if plugged {
            metrics.append(.reading("chargeRate", "Mean charge rate",
                .double(meanBattery), unit: "mW",
                note: "unplug the device and re-run for a true discharge figure — "
                    + "the diagnostics relay works over Wi-Fi, so the cable is "
                    + "not required for the measurement"))
        } else {
            // Discharging: this is the real drain figure.
            let drain = abs(meanBattery)
            metrics.append(.graded(
                "drain", "Measured drain", drain, unit: "mW",
                warnAt: 1500, failAt: 2500, higherIsBetter: false,
                note: "cell current × cell voltage, averaged over the window",
                expectation: "idle with the screen off should be well under 400 mW"
            ))
            if let capacity = samples.compactMap(\.percent).last,
               capacity > 0, drain > 0 {
                // Percent per hour is the unit people reason in.
                let gauge = try? await router.fetch(.batteryGauge, for: device)
                let nominal = gauge?.search(forKey: "NominalChargeCapacity").double
                    ?? gauge?.search(forKey: "DesignCapacity").double
                if let nominal {
                    let packMilliwattHours = nominal * 3.85
                    let percentPerHour = drain / packMilliwattHours * 100
                    metrics.append(.graded(
                        "percentPerHour", "Projected discharge", percentPerHour, unit: "%/h",
                        warnAt: 10, failAt: 18, higherIsBetter: false,
                        note: "at the draw measured just now",
                        expectation: "idle should be 1–3 %/h"
                    ))
                }
            }
        }

        // A drifting cell voltage under constant load is itself a signal.
        let volts = samples.map(\.millivolts)
        metrics.append(.reading("cellVoltage", "Mean cell voltage",
            .double((volts.reduce(0, +) / Double(volts.count)) / 1000), unit: "V"))

        let verdict = rollup(metrics)
        let summary: String
        if plugged {
            let loadText = loads.isEmpty ? "" :
                " — system load \((loads.reduce(0, +) / Double(loads.count)).zeroDecimal) mW"
            summary = "On the charger\(loadText)"
        } else {
            summary = "Drawing \(abs(meanBattery).zeroDecimal) mW from the battery"
        }
        return result(verdict, summary, metrics: metrics)
    }
}

// MARK: - Power event history

/// Unexpected shutdowns, boot voltages, and charge limiting.
///
/// A cell that has aged badly usually announces itself here before the capacity
/// figure looks alarming: it can no longer hold voltage under peak load, so the
/// device browns out and reboots.
public struct PowerHistoryProbe: Probe {
    public let id = "power.history"
    public let title = "Power Event History"
    public let section = ReportSection.power
    public let requiredCapabilities: Set<Capability> = [.batteryGauge]
    public var applicableFamilies: Set<DeviceFamily> { [.iPhone, .iPad, .iPod, .appleWatch] }

    public init() {}

    public func run(device: DeviceSnapshot, router: TransportRouter) async throws -> ProbeResult {
        let gauge = try await router.fetch(.batteryGauge, for: device)
        func value(_ key: String) -> Double? { gauge.search(forKey: key).double }

        var metrics: [Metric] = []

        if let upo = value("ShutDownUpoReboot") {
            metrics.append(.graded(
                "upoReboots", "Unexpected power-off reboots", upo,
                warnAt: 1, failAt: 3, higherIsBetter: false,
                note: upo > 0
                    ? "the cell could not sustain peak load and the device browned out"
                    : nil,
                expectation: "should be 0"
            ))
        }
        if let stamp = value("ShutDownTimestamp"), stamp > 1_000_000_000 {
            let when = Date(timeIntervalSince1970: stamp)
            metrics.append(.reading("lastShutdown", "Last recorded shutdown",
                .string(when.formatted(date: .abbreviated, time: .shortened))))
        }
        if let bootVoltage = value("BootVoltage") {
            // Booting below ~3.4 V means the pack was nearly flat or is weak.
            metrics.append(.graded(
                "bootVoltage", "Voltage at last boot", bootVoltage / 1000, unit: "V",
                warnAt: 3.5, failAt: 3.3, higherIsBetter: true,
                expectation: "above 3.5 V on a healthy pack"
            ))
        }
        if let precharge = value("PrechargeCount") {
            metrics.append(.reading("prechargeCount", "Precharge cycles",
                .double(precharge),
                note: "times the pack was too flat to charge normally"))
        }
        if let thermal = value("TimeChargingThermallyLimited") {
            metrics.append(.graded(
                "chargeThermalLimit", "Charging thermally limited", thermal, unit: "s",
                warnAt: 1, failAt: 600, higherIsBetter: false,
                note: thermal > 0 ? "charge rate was reduced because of heat" : nil,
                expectation: "0 on a cool device"
            ))
        }
        // AverageBattSkinTemp lives only in the stored boot/charge record
        // (DeadBatteryBootData › GeneralPayload), not in any live register, and
        // reads 0 when nothing was recorded. It was graded as a live reading —
        // "✓ Average pack skin temperature: 0°C". Now: a non-zero value is shown
        // as last recorded and never graded; zero is unavailable.
        if let skin = value("AverageBattSkinTemp") {
            if skin > 0 {
                var m = Metric.reading("skinTemp", "Average pack skin temperature (last recorded)",
                                       .double(skin), unit: "°C")
                m.note = "from the battery's stored boot/charge record, not a live sensor — iOS 27 "
                    + "and iPadOS 27 expose no live battery temperature over USB"
                metrics.append(m)
            } else {
                metrics.append(.absent("skinTemp", "Average pack skin temperature",
                    why: "the battery's stored record holds no temperature (0 means no data)"))
            }
        }
        if let disconnects = value("BatteryCellDisconnectCount") {
            metrics.append(.graded(
                "cellDisconnects", "Cell disconnect events", disconnects,
                warnAt: 1, failAt: 5, higherIsBetter: false,
                note: disconnects > 0 ? "the pack has dropped off the bus" : nil,
                expectation: "should be 0"
            ))
        }

        guard !metrics.isEmpty else {
            return result(.unsupported, "The PMU exposed no power event history")
        }

        let verdict = rollup(metrics)
        let summary = switch verdict {
        case .fail: "Power faults recorded — see below"
        case .warn: "Minor power events recorded"
        default: "No adverse power events recorded"
        }
        return result(verdict, summary, metrics: metrics)
    }
}

extension Double {
    var zeroDecimal: String { String(format: "%.0f", self) }
    var oneDecimal: String { String(format: "%.1f", self) }
}
