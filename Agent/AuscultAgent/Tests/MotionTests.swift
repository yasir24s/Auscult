import Foundation
import CoreMotion

/// Shared sampling machinery for the inertial sensors.
///
/// Every one of these tests depends on knowing whether the device was actually
/// still while it ran. A gyroscope reading 2 rad/s is perfectly healthy if
/// someone was waving the phone around, and broken if it was flat on a desk —
/// so rest is measured, not assumed, and a moving device downgrades the verdict
/// to informational rather than failing good hardware.
enum MotionSampler {
    /// A shared manager: CoreMotion misbehaves if several instances start
    /// updates for the same sensor concurrently.
    static let manager = CMMotionManager()

    struct Stats {
        var mean: Double
        var standardDeviation: Double
        var minimum: Double
        var maximum: Double
        var count: Int
    }

    static func stats(_ values: [Double]) -> Stats {
        guard !values.isEmpty else {
            return Stats(mean: 0, standardDeviation: 0, minimum: 0, maximum: 0, count: 0)
        }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return Stats(
            mean: mean, standardDeviation: variance.squareRoot(),
            minimum: values.min()!, maximum: values.max()!, count: values.count
        )
    }

    /// Collect samples for `duration`, reporting progress as it goes.
    static func collect(
        duration: TimeInterval,
        interval: TimeInterval = 0.02,
        progress: ((Double, String) -> Void)? = nil,
        label: String = "Sampling",
        start: (CMMotionManager, OperationQueue, @escaping () -> Void) -> Void,
        stop: (CMMotionManager) -> Void
    ) async throws {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        manager.accelerometerUpdateInterval = interval
        manager.gyroUpdateInterval = interval
        manager.magnetometerUpdateInterval = interval
        manager.deviceMotionUpdateInterval = interval

        let started = Date()
        start(manager, queue) {}

        // Poll rather than sleep once, so progress moves and cancellation lands
        // promptly instead of after the whole sampling window.
        while Date().timeIntervalSince(started) < duration {
            if Task.isCancelled { stop(manager); throw CancellationError() }
            let elapsed = Date().timeIntervalSince(started)
            progress?(min(elapsed / duration, 1), label)
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        stop(manager)
    }

    /// Was the device essentially still during a set of acceleration samples?
    /// 0.02 g of jitter is comfortably above sensor noise and below the wobble
    /// of a hand-held device.
    static func wasAtRest(_ magnitudeStdDev: Double) -> Bool {
        magnitudeStdDev < 0.02
    }
}

// MARK: - Accelerometer

/// Verifies the accelerometer reads 1 g at rest and is actually alive.
///
/// Two independent faults are checked. A wrong magnitude means the sensor is
/// miscalibrated or a axis is dead. Zero variance means it is *stuck* — a
/// failed accelerometer very often keeps returning its last value, which looks
/// plausible until you notice it never changes.
struct AccelerometerTest: AgentTest {
    var descriptor: AgentTestDescriptor {
        AgentTestDescriptor(
            id: "motion.accelerometer", title: "Accelerometer",
            section: "Sensors", estimatedSeconds: 3,
            unavailableReason: MotionSampler.manager.isAccelerometerAvailable
                ? nil : "this device reports no accelerometer"
        )
    }

    func run(context: AgentTestContext) async throws -> AgentTestResult {
        var magnitudes: [Double] = []
        var xs: [Double] = [], ys: [Double] = [], zs: [Double] = []

        try await MotionSampler.collect(
            duration: 2.5, progress: context.progress, label: "Reading accelerometer",
            start: { m, q, _ in
                m.startAccelerometerUpdates(to: q) { data, _ in
                    guard let a = data?.acceleration else { return }
                    xs.append(a.x); ys.append(a.y); zs.append(a.z)
                    magnitudes.append((a.x * a.x + a.y * a.y + a.z * a.z).squareRoot())
                }
            },
            stop: { $0.stopAccelerometerUpdates() }
        )

        guard magnitudes.count > 10 else {
            return result(.fail, "Accelerometer produced \(magnitudes.count) samples in 2.5 s",
                          detail: "the sensor is not delivering data")
        }

        let mag = MotionSampler.stats(magnitudes)
        let atRest = MotionSampler.wasAtRest(mag.standardDeviation)
        var metrics: [AgentMetric] = []

        // At rest the only acceleration is gravity: exactly 1 g.
        metrics.append(.inRange(
            "gravity", "Measured gravity", mag.mean, expected: 0.96...1.04,
            tolerance: 0.06, unit: "g",
            note: atRest ? nil : "device was moving — magnitude is not meaningful"
        ))

        // A stuck sensor is the failure mode that looks healthy.
        metrics.append(.graded(
            "noise", "Sample noise", mag.standardDeviation, unit: "g",
            warnAt: 0.08, failAt: 0.25, higherIsBetter: false,
            note: mag.standardDeviation == 0
                ? "zero variance — the sensor is returning a frozen value"
                : nil,
            expectation: "below 0.08 g at rest"
        ))

        metrics.append(.flag("alive", "Sensor varying", mag.standardDeviation > 0,
                             shouldBe: true, severityIfNot: .fail))
        metrics.append(.number("rate", "Sample rate",
                               Double(mag.count) / 2.5, unit: "Hz"))
        metrics.append(.flag("atRest", "Device at rest", atRest))

        for (axis, values) in [("x", xs), ("y", ys), ("z", zs)] {
            let s = MotionSampler.stats(values)
            metrics.append(.number("axis.\(axis)", "Axis \(axis.uppercased()) mean",
                                   s.mean, unit: "g"))
        }

        // Every axis dead-flat while the others move means one channel is gone.
        let axisStdDevs = [xs, ys, zs].map { MotionSampler.stats($0).standardDeviation }
        if atRest == false, let quietest = axisStdDevs.min(), quietest == 0 {
            metrics.append(.flag("axisDead", "All three axes responding", false,
                                 shouldBe: true, severityIfNot: .fail,
                                 note: "one axis never changed while the device moved"))
        }

        let verdict = rollup(metrics)
        let summary = atRest
            ? "Reads \(mag.mean.clean) g at rest (expected 1.00 g)"
            : "Reads \(mag.mean.clean) g while moving — put the device down for a strict check"
        return result(verdict, summary, metrics: metrics)
    }
}

// MARK: - Gyroscope

/// Verifies the gyroscope's zero-rate bias.
///
/// A healthy gyro at rest reports very close to zero on all axes. Drift shows
/// up as a persistent non-zero rate, which is what makes a device's compass and
/// screen rotation misbehave.
struct GyroscopeTest: AgentTest {
    var descriptor: AgentTestDescriptor {
        AgentTestDescriptor(
            id: "motion.gyroscope", title: "Gyroscope",
            section: "Sensors", estimatedSeconds: 3,
            unavailableReason: MotionSampler.manager.isGyroAvailable
                ? nil : "this device reports no gyroscope"
        )
    }

    func run(context: AgentTestContext) async throws -> AgentTestResult {
        var magnitudes: [Double] = []
        var accelMagnitudes: [Double] = []

        try await MotionSampler.collect(
            duration: 2.5, progress: context.progress, label: "Reading gyroscope",
            start: { m, q, _ in
                m.startGyroUpdates(to: q) { data, _ in
                    guard let r = data?.rotationRate else { return }
                    magnitudes.append((r.x * r.x + r.y * r.y + r.z * r.z).squareRoot())
                }
                // Sampled alongside so we know whether "at rest" was true.
                m.startAccelerometerUpdates(to: q) { data, _ in
                    guard let a = data?.acceleration else { return }
                    accelMagnitudes.append((a.x * a.x + a.y * a.y + a.z * a.z).squareRoot())
                }
            },
            stop: { $0.stopGyroUpdates(); $0.stopAccelerometerUpdates() }
        )

        guard magnitudes.count > 10 else {
            return result(.fail, "Gyroscope produced \(magnitudes.count) samples in 2.5 s",
                          detail: "the sensor is not delivering data")
        }

        let rate = MotionSampler.stats(magnitudes)
        let atRest = MotionSampler.wasAtRest(
            MotionSampler.stats(accelMagnitudes).standardDeviation
        )
        var metrics: [AgentMetric] = []

        if atRest {
            // Rated zero-rate bias for these MEMS parts is well under 0.05 rad/s.
            metrics.append(.graded(
                "bias", "Zero-rate bias", rate.mean, unit: "rad/s",
                warnAt: 0.05, failAt: 0.20, higherIsBetter: false,
                expectation: "near 0 rad/s at rest"
            ))
        } else {
            metrics.append(AgentMetric(
                id: "bias", label: "Zero-rate bias", kind: .double,
                raw: String(rate.mean), unit: "rad/s", verdict: .skipped,
                note: "device was moving — bias can only be measured at rest"
            ))
        }

        metrics.append(.flag("alive", "Sensor varying", rate.standardDeviation > 0,
                             shouldBe: true, severityIfNot: .fail,
                             note: rate.standardDeviation == 0
                                ? "zero variance — the sensor is returning a frozen value" : nil))
        metrics.append(.number("peak", "Peak rate observed", rate.maximum, unit: "rad/s"))
        metrics.append(.number("rate", "Sample rate", Double(rate.count) / 2.5, unit: "Hz"))
        metrics.append(.flag("atRest", "Device at rest", atRest))

        let verdict = rollup(metrics)
        let summary = atRest
            ? "Bias \(rate.mean.clean) rad/s at rest"
            : "Device was moving — leave it still for a bias measurement"
        return result(verdict, summary, metrics: metrics)
    }
}

// MARK: - Magnetometer

/// Verifies the magnetometer sees a plausible magnetic field.
///
/// The tolerance here is deliberately wide. Earth's field is 25–65 µT, but the
/// raw reading includes the device's own hard-iron offset and whatever is on the
/// desk, so a narrow window would produce false failures. What actually
/// distinguishes a broken magnetometer is a reading of exactly zero, a frozen
/// value, or a magnitude far outside anything physical.
struct MagnetometerTest: AgentTest {
    var descriptor: AgentTestDescriptor {
        AgentTestDescriptor(
            id: "motion.magnetometer", title: "Magnetometer",
            section: "Sensors", estimatedSeconds: 3,
            unavailableReason: MotionSampler.manager.isMagnetometerAvailable
                ? nil : "this device reports no magnetometer"
        )
    }

    func run(context: AgentTestContext) async throws -> AgentTestResult {
        var magnitudes: [Double] = []
        var calibrated: [Double] = []
        var accuracies: [Int] = []

        try await MotionSampler.collect(
            duration: 2.5, progress: context.progress, label: "Reading magnetometer",
            start: { m, q, _ in
                m.startMagnetometerUpdates(to: q) { data, _ in
                    guard let f = data?.magneticField else { return }
                    magnitudes.append((f.x * f.x + f.y * f.y + f.z * f.z).squareRoot())
                }
                if m.isDeviceMotionAvailable {
                    // The calibrated magnetic field is only populated in a
                    // magnetically-referenced frame; xArbitraryZVertical leaves
                    // it at zero, which reads as a dead sensor.
                    m.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: q) { motion, _ in
                        guard let field = motion?.magneticField else { return }
                        let v = field.field
                        calibrated.append((v.x * v.x + v.y * v.y + v.z * v.z).squareRoot())
                        accuracies.append(Int(field.accuracy.rawValue))
                    }
                }
            },
            stop: { $0.stopMagnetometerUpdates(); $0.stopDeviceMotionUpdates() }
        )

        guard magnitudes.count > 5 else {
            return result(.fail, "Magnetometer produced \(magnitudes.count) samples in 2.5 s",
                          detail: "the sensor is not delivering data")
        }

        let raw = MotionSampler.stats(magnitudes)

        // The raw reading is reported, not graded. It includes the device's own
        // hard-iron offset plus anything ferrous nearby — a phone on a MacBook
        // or in a MagSafe case legitimately reads several hundred µT, so
        // grading it produces confident false failures. What actually indicates
        // a dead magnetometer is a frozen or zero reading.
        var metrics: [AgentMetric] = [
            .number("rawField", "Raw field strength", raw.mean, unit: "µT",
                    note: "includes the device's own magnets and nearby metal"),
            .flag("alive", "Sensor varying", raw.standardDeviation > 0,
                  shouldBe: true, severityIfNot: .fail,
                  note: raw.standardDeviation == 0
                    ? "zero variance — the sensor is returning a frozen value" : nil),
            .flag("nonZero", "Sensor reading non-zero", raw.mean > 1,
                  shouldBe: true, severityIfNot: .fail),
            .number("rate", "Sample rate", Double(raw.count) / 2.5, unit: "Hz"),
        ]

        // CMMagneticFieldCalibrationAccuracy: -1 uncalibrated, 0 low, 1 medium, 2 high.
        let bestAccuracy = accuracies.max() ?? -1
        let names = [-1: "uncalibrated", 0: "low", 1: "medium", 2: "high"]
        metrics.append(.reading("calibration", "Calibration quality",
                                names[bestAccuracy] ?? "unknown",
                                note: bestAccuracy < 0
                                    ? "move the device in a figure-eight to calibrate" : nil))

        // Only grade against Earth's field once iOS says the fit is usable;
        // before that the calibrated vector is meaningless.
        let usable = calibrated.filter { $0 > 0 }
        var calibratedMean: Double?
        if bestAccuracy >= 0, !usable.isEmpty {
            let cal = MotionSampler.stats(usable)
            calibratedMean = cal.mean
            // A reading well outside Earth's field almost always means a
            // magnet nearby rather than a broken sensor, and saying so is the
            // difference between a useful warning and a false alarm.
            let disturbed = cal.mean < 20 || raw.mean > 200
            metrics.append(.inRange("calibratedField", "Calibrated field strength",
                                    cal.mean, expected: 20...75, tolerance: 25, unit: "µT",
                                    note: disturbed
                                        ? "Earth's field is 25–65 µT — a MagSafe case, stand, "
                                          + "or a laptop underneath will distort this; "
                                          + "move the device clear and re-run"
                                        : "Earth's field is 25–65 µT"))
        } else {
            metrics.append(AgentMetric(
                id: "calibratedField", label: "Calibrated field strength",
                kind: .absent, raw: "", verdict: .skipped,
                note: "the magnetometer is not calibrated yet — "
                    + "move the device in a figure-eight and re-run"
            ))
        }

        let verdict = rollup(metrics)
        // Lead with the number that is actually graded. The raw figure includes
        // the device's own magnets — on a MagSafe phone it routinely reads ten
        // times Earth's field — so putting it first makes a perfectly healthy
        // sensor look broken. And say "quality" out loud: "calibration high"
        // sitting next to a µT value parses as another magnitude rather than as
        // the best of four accuracy levels, which is the opposite of reassuring.
        let quality = names[bestAccuracy] ?? "unknown"
        let summary = if let calibratedMean {
            "Calibrated field \(calibratedMean.clean) µT · calibration quality \(quality)"
        } else {
            // Say what passed before what is missing. The sensor genuinely did
            // pass every check that can be made without a calibration fit, so
            // leading with "not calibrated" reads as a fault next to a green
            // tick — the same contradiction the audio test had.
            "Sensor responding, but uncalibrated — move the device in a figure-eight for a field reading"
        }
        return result(verdict, summary, metrics: metrics)
    }
}

// MARK: - Barometer

/// Verifies the barometric pressure sensor.
///
/// Sea-level pressure is about 101 kPa and falls with altitude; anything from
/// 80 to 110 kPa is plausible on land. A dead barometer reports zero or refuses
/// to start.
struct BarometerTest: AgentTest {
    var descriptor: AgentTestDescriptor {
        AgentTestDescriptor(
            id: "motion.barometer", title: "Barometer",
            section: "Sensors", permission: .motion,
            permissionGranted: CMAltimeter.authorizationStatus() == .authorized,
            estimatedSeconds: 4,
            unavailableReason: CMAltimeter.isRelativeAltitudeAvailable()
                ? nil : "this device has no barometer"
        )
    }

    func run(context: AgentTestContext) async throws -> AgentTestResult {
        let altimeter = CMAltimeter()
        context.progress(0.1, "Reading barometer")

        var pressures: [Double] = []
        let queue = OperationQueue()
        altimeter.startRelativeAltitudeUpdates(to: queue) { data, _ in
            // kPa
            guard let p = data?.pressure.doubleValue else { return }
            pressures.append(p)
        }

        let deadline = Date().addingTimeInterval(3.5)
        while Date() < deadline, pressures.count < 3 {
            if Task.isCancelled {
                altimeter.stopRelativeAltitudeUpdates()
                throw CancellationError()
            }
            context.progress(
                min(Date().timeIntervalSince(deadline.addingTimeInterval(-3.5)) / 3.5, 1),
                "Reading barometer"
            )
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        altimeter.stopRelativeAltitudeUpdates()

        guard !pressures.isEmpty else {
            let status = CMAltimeter.authorizationStatus()
            if status == .denied || status == .restricted {
                return result(.skipped, "Motion & Fitness access is denied",
                              detail: "grant it in Settings › Privacy › Motion & Fitness")
            }
            return result(.fail, "Barometer produced no readings in 3.5 s",
                          detail: "the sensor is not delivering data")
        }

        let stats = MotionSampler.stats(pressures)
        let metrics: [AgentMetric] = [
            .inRange("pressure", "Ambient pressure", stats.mean,
                     expected: 80...110, tolerance: 15, unit: "kPa",
                     note: "sea level is about 101 kPa"),
            .number("samples", "Samples", Double(stats.count)),
        ]
        return result(rollup(metrics), "\(stats.mean.clean) kPa", metrics: metrics)
    }
}
