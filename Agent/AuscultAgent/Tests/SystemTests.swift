import Foundation
import UIKit
import Metal
import LocalAuthentication

// MARK: - Display

/// Reports the panel's real capabilities as the display pipeline sees them.
///
/// This is the configuration, not a panel inspection — dead pixels and
/// backlight uniformity need a human looking at the screen, which is what
/// `DeadPixelSweepTest` is for. What this establishes is that the pipeline
/// enumerates correctly and the panel runs at the refresh rate it should.
struct DisplayTest: AgentTest {
    var descriptor: AgentTestDescriptor {
        AgentTestDescriptor(id: "display.info", title: "Display Pipeline",
                            section: "Display", estimatedSeconds: 1)
    }

    @MainActor
    private func screen() -> UIScreen? {
        // UIScreen.main is deprecated; take the screen of the active scene.
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen
    }

    func run(context: AgentTestContext) async throws -> AgentTestResult {
        context.progress(0.3, "Reading display")
        guard let screen = await screen() else {
            return result(.unsupported, "No attached screen found")
        }

        let native = await screen.nativeBounds
        let scale = await screen.nativeScale
        let maxFPS = await screen.maximumFramesPerSecond
        let brightness = await screen.brightness

        var metrics: [AgentMetric] = [
            .reading("nativeResolution", "Native resolution",
                     "\(Int(native.width)) × \(Int(native.height))", unit: "px"),
            .number("scale", "Native scale", scale, unit: "×"),
            .graded("refresh", "Maximum refresh rate", Double(maxFPS), unit: "Hz",
                    warnAt: 59, failAt: 29, higherIsBetter: true,
                    note: maxFPS >= 120 ? "ProMotion" : nil,
                    expectation: "60 Hz, or 120 Hz on ProMotion panels"),
            .graded("brightness", "Backlight level", brightness * 100, unit: "%",
                    warnAt: 1, failAt: 0, higherIsBetter: true,
                    note: brightness == 0 ? "backlight reports fully off" : nil,
                    expectation: "above 0%"),
        ]

        let headroom = await MainActor.run { screen.potentialEDRHeadroom }
        metrics.append(.number("edrHeadroom", "Potential EDR headroom",
                               Double(headroom), unit: "×",
                               note: headroom > 1 ? "HDR capable" : "no HDR headroom reported"))

        metrics.append(.absent("panelIntegrity", "Dead pixels & uniformity",
                               why: "measured by the guided display sweep"))

        return result(rollup(metrics),
                      "\(Int(native.width))×\(Int(native.height)) at \(maxFPS) Hz",
                      metrics: metrics)
    }
}

// MARK: - CPU

/// Measures CPU throughput single- and multi-threaded.
///
/// The absolute numbers matter less than the ratio: a device whose multi-core
/// scaling has collapsed, or whose single-core score is far below its class, is
/// either thermally throttled or has a real problem. Reported as readings with
/// a scaling check rather than a pass/fail score, because a "slow" verdict
/// against a hardcoded table would be wrong the moment a new chip ships.
struct CPUTest: AgentTest {
    var descriptor: AgentTestDescriptor {
        AgentTestDescriptor(id: "compute.cpu", title: "CPU Throughput",
                            section: "Compute", estimatedSeconds: 6)
    }

    /// A dependent floating-point chain: dominated by latency rather than
    /// memory bandwidth, so it measures the core rather than the cache.
    ///
    /// The result *must* escape into `Blackhole`. Discarding it lets the
    /// optimiser delete the entire loop, and a loop that doesn't run completes
    /// in zero time — which is how a benchmark comes to report infinite
    /// throughput and then trap converting that to an integer.
    @inline(never)
    static func work(iterations: Int) -> Double {
        var acc = 1.000001
        for _ in 0..<iterations {
            acc = acc * 1.0000001 + 0.0000001
            acc = acc.squareRoot() * 1.0000002
        }
        Blackhole.consume(acc)
        return acc
    }

    func run(context: AgentTestContext) async throws -> AgentTestResult {
        let cores = Int(DeviceFacts.sysctlInt("hw.physicalcpu") ?? 0)
        let logical = Int(DeviceFacts.sysctlInt("hw.logicalcpu") ?? 0)
        let iterations = 4_000_000

        context.progress(0.15, "Single-core pass")
        let singleStart = Date()
        _ = Self.work(iterations: iterations)
        let singleElapsed = Date().timeIntervalSince(singleStart)

        // A measurable elapsed time is a precondition, not an assumption: if
        // the workload were ever optimised out again, this reports honestly
        // instead of dividing by zero.
        guard singleElapsed > 0.001 else {
            return result(.error, "CPU workload completed implausibly fast",
                          detail: "single-core pass took \(singleElapsed)s — "
                                + "the benchmark loop is not executing")
        }
        let singleRate = Double(iterations) / singleElapsed / 1_000_000  // M-iter/s

        if Task.isCancelled { throw CancellationError() }
        context.progress(0.55, "Multi-core pass")

        let threads = max(cores, 1)
        let multiStart = Date()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<threads {
                group.addTask { _ = Self.work(iterations: iterations) }
            }
        }
        let multiElapsed = Date().timeIntervalSince(multiStart)
        let multiRate = multiElapsed > 0.001
            ? Double(iterations * threads) / multiElapsed / 1_000_000
            : 0

        context.progress(0.95, "Summarising")

        let scaling = singleRate > 0 ? multiRate / singleRate : 0
        var metrics: [AgentMetric] = [
            .number("cores", "Physical cores", Double(cores)),
            .number("logicalCores", "Logical cores", Double(logical)),
            .number("singleCore", "Single-core rate", singleRate, unit: "M iter/s"),
            .number("multiCore", "Multi-core rate", multiRate, unit: "M iter/s"),
        ]

        // Perfect scaling is unreachable (efficiency cores are slower), but
        // falling below ~1.5x on a multi-core device means work isn't spreading.
        if cores > 1 {
            metrics.append(.graded(
                "scaling", "Multi-core scaling", scaling, unit: "×",
                warnAt: 1.5, failAt: 1.05, higherIsBetter: true,
                note: "ratio of multi-core to single-core throughput",
                expectation: "well above 1× on a \(cores)-core device"
            ))
        }

        if let brand = sysctlString("machdep.cpu.brand_string") {
            metrics.append(.reading("brand", "CPU", brand))
        }

        return result(rollup(metrics),
                      "\(singleRate.clean) M iter/s single, \(multiRate.clean) multi",
                      metrics: metrics)
    }

    private func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }
}

// MARK: - GPU

/// Verifies the GPU enumerates and can actually execute work.
///
/// A compute kernel is compiled at runtime and dispatched over a large buffer.
/// That exercises the full path — driver, command queue, shader compiler, and
/// the hardware — rather than just asking Metal to describe itself.
struct GPUTest: AgentTest {
    var descriptor: AgentTestDescriptor {
        AgentTestDescriptor(id: "compute.gpu", title: "GPU Throughput",
                            section: "Compute", estimatedSeconds: 4,
                            unavailableReason: MTLCreateSystemDefaultDevice() == nil
                                ? "no Metal device is available" : nil)
    }

    private static let kernel = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void saxpy(device float *out [[buffer(0)]],
                      const device float *in [[buffer(1)]],
                      uint i [[thread_position_in_grid]]) {
        float v = in[i];
        // Enough arithmetic per element that we measure compute, not bandwidth.
        for (int k = 0; k < 64; ++k) { v = fma(v, 1.0000001f, 0.0000001f); }
        out[i] = v;
    }
    """

    func run(context: AgentTestContext) async throws -> AgentTestResult {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return result(.fail, "Metal reported no GPU on this device")
        }
        context.progress(0.2, "Compiling kernel")

        var metrics: [AgentMetric] = [
            .reading("name", "GPU", device.name),
            .bytes("workingSet", "Recommended working set",
                   Int64(device.recommendedMaxWorkingSetSize)),
            .flag("unifiedMemory", "Unified memory", device.hasUnifiedMemory),
        ]

        // Highest supported family tells us the real capability level.
        let families: [(String, MTLGPUFamily)] = [
            ("Apple 9", .apple9), ("Apple 8", .apple8), ("Apple 7", .apple7),
            ("Apple 6", .apple6), ("Apple 5", .apple5),
        ]
        if let best = families.first(where: { device.supportsFamily($0.1) }) {
            metrics.append(.reading("family", "GPU family", best.0))
        }

        do {
            let library = try await device.makeLibrary(source: Self.kernel, options: nil)
            guard let function = library.makeFunction(name: "saxpy"),
                  let queue = device.makeCommandQueue()
            else {
                metrics.append(.flag("execute", "Kernel dispatch", false,
                                     shouldBe: true, severityIfNot: .fail,
                                     note: "could not build a pipeline"))
                return result(rollup(metrics), "GPU enumerated but no work could be dispatched",
                              metrics: metrics)
            }
            let pipeline = try await device.makeComputePipelineState(function: function)

            let count = 4 << 20   // 4 M floats = 16 MB
            let byteCount = count * MemoryLayout<Float>.stride
            guard let input = device.makeBuffer(length: byteCount, options: .storageModeShared),
                  let output = device.makeBuffer(length: byteCount, options: .storageModeShared)
            else {
                return result(.fail, "Could not allocate GPU buffers", metrics: metrics)
            }
            input.contents().initializeMemory(as: Float.self, repeating: 1.0, count: count)

            context.progress(0.6, "Dispatching compute")
            let start = Date()
            let passes = 8
            for _ in 0..<passes {
                guard let buffer = queue.makeCommandBuffer(),
                      let encoder = buffer.makeComputeCommandEncoder() else { break }
                encoder.setComputePipelineState(pipeline)
                encoder.setBuffer(output, offset: 0, index: 0)
                encoder.setBuffer(input, offset: 0, index: 1)
                let width = pipeline.maxTotalThreadsPerThreadgroup
                encoder.dispatchThreads(
                    MTLSize(width: count, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
                )
                encoder.endEncoding()
                buffer.commit()
                buffer.waitUntilCompleted()
                if Task.isCancelled { throw CancellationError() }
            }
            let elapsed = Date().timeIntervalSince(start)

            // 64 fma per element, 2 flops each.
            let gflops = Double(count * passes * 64 * 2) / elapsed / 1e9
            metrics.append(.flag("execute", "Kernel dispatch", true, shouldBe: true))
            metrics.append(.number("throughput", "Compute throughput", gflops, unit: "GFLOPS"))

            // Confirm the GPU produced the arithmetic we asked for, not zeros —
            // a dispatch can "succeed" and write nothing.
            let produced = output.contents().load(as: Float.self)
            metrics.append(.flag("correctness", "Result plausible",
                                 produced > 1.0 && produced < 1.1,
                                 shouldBe: true, severityIfNot: .fail,
                                 note: "first output element = \(produced)"))

            return result(rollup(metrics),
                          "\(device.name), \(gflops.clean) GFLOPS", metrics: metrics)
        } catch {
            metrics.append(.flag("execute", "Kernel dispatch", false,
                                 shouldBe: true, severityIfNot: .fail,
                                 note: error.localizedDescription))
            return result(rollup(metrics), "GPU enumerated but the kernel failed to build",
                          metrics: metrics, detail: error.localizedDescription)
        }
    }
}

// MARK: - Thermal

/// Puts the device under sustained load and watches it throttle.
///
/// This is one of the few tests that can distinguish "slow because it's hot" —
/// normal, expected behaviour — from "slow always", which points at degraded
/// silicon or a failed thermal path. Throughput is sampled every second and the
/// last second is compared against the first.
struct ThermalTest: AgentTest {
    var descriptor: AgentTestDescriptor {
        AgentTestDescriptor(id: "thermal.sustained", title: "Thermal & Throttling",
                            section: "Thermal", estimatedSeconds: 16)
    }

    private static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    func run(context: AgentTestContext) async throws -> AgentTestResult {
        let before = ProcessInfo.processInfo.thermalState
        var observed: Set<String> = [Self.describe(before)]
        var perSecond: [Double] = []

        let duration = 14.0
        let cores = max(Int(DeviceFacts.sysctlInt("hw.physicalcpu") ?? 2), 2)
        let started = Date()

        while Date().timeIntervalSince(started) < duration {
            if Task.isCancelled { throw CancellationError() }
            let sliceStart = Date()
            var iterations = 0

            // One second of all-core load, counting completed batches.
            await withTaskGroup(of: Int.self) { group in
                for _ in 0..<cores {
                    group.addTask {
                        var done = 0
                        let deadline = sliceStart.addingTimeInterval(1.0)
                        while Date() < deadline {
                            _ = CPUTest.work(iterations: 200_000)
                            done += 1
                        }
                        return done
                    }
                }
                for await n in group { iterations += n }
            }

            perSecond.append(Double(iterations))
            observed.insert(Self.describe(ProcessInfo.processInfo.thermalState))
            let elapsed = Date().timeIntervalSince(started)
            context.progress(min(elapsed / duration, 1),
                             "Sustained load — \(Self.describe(ProcessInfo.processInfo.thermalState))")
        }

        let after = ProcessInfo.processInfo.thermalState
        guard perSecond.count >= 4 else {
            return result(.unsupported, "Not enough load samples to judge throttling")
        }

        let first = perSecond.prefix(2).reduce(0, +) / 2
        let last = perSecond.suffix(2).reduce(0, +) / 2
        let retained = first > 0 ? last / first * 100 : 0

        var metrics: [AgentMetric] = [
            .reading("stateBefore", "Thermal state before", Self.describe(before)),
            .reading("stateAfter", "Thermal state after", Self.describe(after)),
            .list("statesObserved", "States observed", observed.sorted()),
            // Some throttling under 14 s of all-core load is entirely normal;
            // losing more than half of throughput is not.
            .graded("retained", "Throughput retained", retained, unit: "%",
                    warnAt: 70, failAt: 45, higherIsBetter: true,
                    note: "last two seconds vs first two",
                    expectation: "above 70% after 14 s of load"),
            .number("peakRate", "Peak batches/s", perSecond.max() ?? 0),
        ]

        if after == .critical {
            metrics.append(.flag("critical", "Reached critical thermal state", true,
                                 shouldBe: false, severityIfNot: .fail,
                                 note: "the device shut down work to protect itself"))
        }

        let verdict = rollup(metrics)
        return result(verdict,
                      "Retained \(retained.clean)% of throughput; ended \(Self.describe(after))",
                      metrics: metrics)
    }
}

/// Somewhere for benchmark results to go so the compiler cannot prove the work
/// is dead and delete it.
enum Blackhole {
    nonisolated(unsafe) static var value: Double = 0
    /// Volatile-ish accumulate. Reading `value` afterwards keeps the store live.
    @inline(never)
    static func consume(_ x: Double) { value += x }
}

// MARK: - Storage

/// Measures real write and read throughput, plus actual free space.
struct StorageThroughputTest: AgentTest {
    var descriptor: AgentTestDescriptor {
        AgentTestDescriptor(id: "storage.throughput", title: "Storage Throughput",
                            section: "Storage", estimatedSeconds: 6)
    }

    func run(context: AgentTestContext) async throws -> AgentTestResult {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
        let url = dir.appendingPathComponent("auscult-io-\(UUID().uuidString).bin")
        // Large enough to get past the write cache, small enough to be polite
        // on a nearly-full device.
        let size = 64 * 1024 * 1024
        var metrics: [AgentMetric] = []

        if let values = try? dir.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]) {
            if let total = values.volumeTotalCapacity {
                metrics.append(.bytes("total", "Volume capacity", Int64(total)))
            }
            if let free = values.volumeAvailableCapacityForImportantUsage {
                metrics.append(.bytes("free", "Available space", Int64(free)))
                if let total = values.volumeTotalCapacity, total > 0 {
                    metrics.append(.graded(
                        "freePercent", "Free space",
                        Double(free) / Double(total) * 100, unit: "%",
                        warnAt: 10, failAt: 4, higherIsBetter: true,
                        expectation: "keep above 10%"
                    ))
                }
                guard free > Int64(size) * 3 else {
                    metrics.append(.absent("throughput", "Throughput",
                                           why: "not enough free space to run the I/O test safely"))
                    return result(rollup(metrics),
                                  "Skipped the I/O test — insufficient free space",
                                  metrics: metrics)
                }
            }
        }

        defer { try? fm.removeItem(at: url) }

        context.progress(0.25, "Writing 64 MB")
        var payload = Data(count: size)
        payload.withUnsafeMutableBytes { buf in
            // Incompressible-ish, so filesystem compression can't flatter us.
            var seed: UInt64 = 0x2545F4914F6CDD1D
            let words = buf.bindMemory(to: UInt64.self)
            for i in 0..<words.count {
                seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                words[i] = seed
            }
        }

        // Same discipline as the read: bypass the cache and force the data all
        // the way down with fsync, otherwise this times a memcpy into the
        // buffer cache and calls it flash write throughput.
        guard fm.createFile(atPath: url.path, contents: nil) else {
            return result(.fail, "Could not create a file to test with", metrics: metrics)
        }
        let writeHandle: FileHandle
        do {
            writeHandle = try FileHandle(forWritingTo: url)
        } catch {
            return result(.fail, "Could not open storage for writing", metrics: metrics,
                          detail: error.localizedDescription)
        }
        _ = fcntl(writeHandle.fileDescriptor, F_NOCACHE, 1)

        let writeStart = Date()
        do {
            var offset = 0
            let chunk = 4 * 1024 * 1024
            while offset < size {
                let end = min(offset + chunk, size)
                try writeHandle.write(contentsOf: payload[offset..<end])
                offset = end
                if Task.isCancelled { throw CancellationError() }
            }
            // Not optional: without this the timer stops before the flash does.
            guard fsync(writeHandle.fileDescriptor) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            try writeHandle.close()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try? writeHandle.close()
            return result(.fail, "Could not write to storage", metrics: metrics,
                          detail: error.localizedDescription)
        }
        let writeSeconds = Date().timeIntervalSince(writeStart)
        let writeMBs = writeSeconds > 0 ? Double(size) / writeSeconds / 1_048_576 : 0

        if Task.isCancelled { throw CancellationError() }
        context.progress(0.7, "Reading back")

        // `Data(contentsOf:options:.uncached)` still reads through the unified
        // buffer cache, which for a file written moments ago reports memory
        // bandwidth — the first version of this test claimed 7.7 GB/s. Setting
        // F_NOCACHE on the descriptor is what actually bypasses the cache and
        // measures the flash.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)
        _ = fcntl(handle.fileDescriptor, F_RDAHEAD, 0)

        let readStart = Date()
        var readBack = Data(capacity: size)
        while readBack.count < size {
            guard let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty
            else { break }
            readBack.append(chunk)
            if Task.isCancelled { throw CancellationError() }
        }
        let readSeconds = Date().timeIntervalSince(readStart)
        let readMBs = readSeconds > 0 ? Double(readBack.count) / readSeconds / 1_048_576 : 0

        metrics.append(.number("writeSpeed", "Sequential write", writeMBs, unit: "MB/s",
                               note: "cache-bypassed and fsynced to flash"))
        metrics.append(.number("readSpeed", "Sequential read", readMBs, unit: "MB/s",
                               note: "cache-bypassed, so this is the flash itself"))
        metrics.append(.flag("integrity", "Data read back intact",
                             readBack.count == size && readBack == payload,
                             shouldBe: true, severityIfNot: .fail,
                             note: "64 MB written and compared byte for byte"))

        return result(rollup(metrics),
                      "Write \(writeMBs.clean) MB/s, read \(readMBs.clean) MB/s",
                      metrics: metrics)
    }
}

// MARK: - Memory

/// Reports installed and available memory.
struct MemoryTest: AgentTest {
    var descriptor: AgentTestDescriptor {
        AgentTestDescriptor(id: "memory.info", title: "Memory",
                            section: "Compute", estimatedSeconds: 1)
    }

    func run(context: AgentTestContext) async throws -> AgentTestResult {
        context.progress(0.5, "Reading memory")
        let physical = Int64(ProcessInfo.processInfo.physicalMemory)
        // What this process may still allocate before jetsam kills it.
        let availableToApp = Int64(os_proc_available_memory())

        var metrics: [AgentMetric] = [
            .number("physicalGiB", "Installed memory",
                    Double(physical) / 1_073_741_824, unit: "GiB"),
            .bytes("physical", "Installed memory (bytes)", physical),
            .number("processors", "Active processors",
                    Double(ProcessInfo.processInfo.activeProcessorCount)),
        ]
        if availableToApp > 0 {
            metrics.append(.bytes("appAvailable", "Available to this app", availableToApp,
                                  note: "headroom before the app is jetsammed"))
        }
        if let pageSize = DeviceFacts.sysctlInt("hw.pagesize") {
            metrics.append(.number("pageSize", "Page size", Double(pageSize), unit: "bytes"))
        }

        // Report RAM in binary units in both places. Mixing `.memory` in the
        // summary with the metric's decimal rendering made one device look like
        // it had both 11.42 GB and 12.26 GB of memory.
        let gib = Double(physical) / 1_073_741_824
        return result(.info, "\(gib.clean) GiB installed", metrics: metrics)
    }
}

// MARK: - Biometrics

/// Reports which biometric hardware exists and whether it is enrolled.
///
/// Queried, not exercised: actually invoking Face ID would put a system prompt
/// in front of the person for no diagnostic gain. What matters is that the
/// sensor enumerates — a failed Face ID module reports `biometryNotAvailable`.
struct BiometricsTest: AgentTest {
    var descriptor: AgentTestDescriptor {
        AgentTestDescriptor(id: "biometrics.info", title: "Biometric Sensor",
                            section: "Sensors", estimatedSeconds: 1)
    }

    func run(context: AgentTestContext) async throws -> AgentTestResult {
        context.progress(0.5, "Querying biometrics")
        let ctx = LAContext()
        var error: NSError?
        let canEvaluate = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)

        let type: String = switch ctx.biometryType {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        case .none: "none"
        @unknown default: "unknown"
        }

        var metrics: [AgentMetric] = [
            .reading("type", "Biometry type", type),
        ]

        // Not enrolled is a user choice; not *available* is a hardware signal.
        if let error, let code = LAError.Code(rawValue: error.code) {
            switch code {
            case .biometryNotEnrolled:
                metrics.append(.flag("present", "Sensor present", true, shouldBe: true))
                metrics.append(.flag("enrolled", "Enrolled", false,
                                     note: "no face or fingerprint registered — not a fault"))
            case .biometryNotAvailable:
                metrics.append(.flag("present", "Sensor present", false,
                                     shouldBe: true, severityIfNot: .fail,
                                     note: "the biometric sensor is not responding"))
            case .biometryLockout:
                metrics.append(.flag("present", "Sensor present", true, shouldBe: true))
                metrics.append(.flag("lockedOut", "Locked out", true,
                                     note: "too many failed attempts; a passcode unlock clears it"))
            default:
                metrics.append(.reading("status", "Status", error.localizedDescription))
            }
        } else if canEvaluate {
            metrics.append(.flag("present", "Sensor present", true, shouldBe: true))
            metrics.append(.flag("enrolled", "Enrolled", true, shouldBe: true))
        }

        let verdict = rollup(metrics)
        return result(verdict, canEvaluate ? "\(type) available and enrolled" : "\(type)",
                      metrics: metrics)
    }
}
