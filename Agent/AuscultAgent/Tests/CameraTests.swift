import Foundation
import AVFoundation
import CoreImage
import UIKit

/// Captures a frame from every camera and checks the sensor is actually alive.
///
/// Enumeration alone proves nothing — a camera with a failed sensor or a
/// shutter that never opens still appears in `AVCaptureDevice.DiscoverySession`.
/// So each lens gets a real capture, and the frame is examined: a dead sensor
/// returns a uniform image (all black, all white, or a single flat colour),
/// while a working one returns something with variance in it.
///
/// The luminance statistics are computed on the actual pixels rather than
/// trusting metadata, because metadata is what a broken camera lies about.
struct CameraTest: AgentTest {
    var descriptor: AgentTestDescriptor {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        return AgentTestDescriptor(
            id: "camera.capture", title: "Cameras",
            section: "Cameras",
            permission: .camera,
            permissionGranted: status == .authorized,
            estimatedSeconds: 20,
            unavailableReason: status == .denied || status == .restricted
                ? "camera access is denied — enable it in Settings › Privacy › Camera"
                : nil
        )
    }

    func run(context: AgentTestContext) async throws -> AgentTestResult {
        // Ask once, up front. iOS only ever shows this prompt once per install.
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            context.awaitingUser("Allow camera access on the device to test the cameras")
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            return result(.skipped, "Camera access was not granted",
                          detail: "enable it in Settings › Privacy › Camera and re-run")
        }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera, .builtInUltraWideCamera,
                .builtInTelephotoCamera, .builtInDualCamera,
                .builtInDualWideCamera, .builtInTripleCamera,
                .builtInTrueDepthCamera, .builtInLiDARDepthCamera,
            ],
            mediaType: .video, position: .unspecified
        )

        // One entry per physical sensor. Filtering by device type is not enough:
        // iOS exposes one sensor under several types. An iPad Air's single
        // Center Stage front camera appears as both a Wide and an Ultra Wide
        // device, and TrueDepth is the front camera again — so an iPad with two
        // cameras reported three, and an iPhone 17 Pro Max with four reported six.
        let (physical, merged) = Self.distinctSensors(discovery.devices)
        let names = Self.names(for: physical)
        func name(_ d: AVCaptureDevice) -> String { names[d.uniqueID] ?? d.localizedName }

        guard !physical.isEmpty else {
            return result(.fail, "No cameras were discovered on this device",
                          detail: "a device of this type should report several")
        }

        var metrics: [AgentMetric] = [
            .number("count", "Cameras discovered", Double(physical.count)),
            .list("discovered", "Cameras", physical.map(name)),
        ]
        if !merged.isEmpty {
            metrics.append(.list(
                "merged", "Listed twice by iOS", merged,
                note: "the same physical camera exposed under more than one name — each "
                    + "camera is tested once"))
        }

        // Two passes, deliberately.
        //
        // Prompting inside the capture loop blocks every remaining camera
        // behind one person's attention — and if they don't answer, the whole
        // test burns the timeout and then measures a scene that has moved on.
        // So: capture everything first, and only then, if anything looked dark,
        // ask once and re-test just those.
        var results: [(device: AVCaptureDevice, stats: FrameStatistics?, error: String?)] = []

        for (index, device) in physical.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            context.progress(
                Double(index) / Double(physical.count) * 0.5,
                "Capturing from \(name(device))"
            )
            do {
                results.append((device, try await Self.captureStatistics(from: device), nil))
            } catch {
                results.append((device, nil, error.localizedDescription))
            }
        }

        // Flat black is retried alongside ordinary darkness: a lens pressed
        // against a desk can return a perfectly uniform black frame, because
        // the image pipeline denoises and clamps black in total darkness. That
        // is indistinguishable from a dead sensor until the view is changed.
        let darkIndices = results.indices.filter { index in
            results[index].stats.map(Self.needsLight) ?? false
        }
        var retriedInLight: Set<Int> = []

        if !darkIndices.isEmpty {
            let darkNames = darkIndices.map { name(results[$0].device) }
            context.awaitingUser(
                "Hold the device up so nothing covers the lenses, then confirm on screen"
            )
            let plural: String = darkNames.count == 1 ? "camera" : "cameras"
            let joined: String = darkNames.joined(separator: ", ")
            let message: String = "\(darkNames.count) \(plural) saw only darkness (\(joined)).\n\n"
                + "Hold the device up, away from any surface, with the room lit — then tap Ready."
            let answer = await context.askUser(UserPrompt(
                message: message,
                confirmTitle: "Ready",
                rejectTitle: "Skip"
            ))

            if answer == .confirmed {
                // Let auto-exposure adapt to the new scene before re-measuring.
                try? await Task.sleep(nanoseconds: 900_000_000)
                for (offset, index) in darkIndices.enumerated() {
                    if Task.isCancelled { throw CancellationError() }
                    context.progress(
                        0.5 + Double(offset) / Double(darkIndices.count) * 0.45,
                        "Re-testing \(name(results[index].device))"
                    )
                    if let retry = try? await Self.captureStatistics(from: results[index].device) {
                        results[index].stats = retry
                        retriedInLight.insert(index)
                    }
                }
            }
        }

        var failures: [String] = []
        var inconclusive: [String] = []
        // A tap on Ready is a claim, not evidence. On an iPad the retry once
        // condemned the rear camera "in a lit room" while the front camera, in
        // the same pass, measured 0.12/255 — the room was dark. So a flat black
        // frame is only condemned if another camera saw real light in the retry.
        // A single-camera device has no possible witness; the tap has to do.
        let lightWitnessed = physical.count == 1 || results.enumerated().contains { i, r in
            retriedInLight.contains(i) && (r.stats.map { Self.classify($0) == .live } ?? false)
        }

        for (index, entry) in results.enumerated() {
            let name = name(entry.device)
            let id = Self.metricID(for: entry.device)

            guard let stats = entry.stats else {
                metrics.append(.flag("\(id).alive", "\(name) — capture", false,
                                     shouldBe: true, severityIfNot: .fail,
                                     note: entry.error ?? "no frames delivered"))
                failures.append(name)
                continue
            }

            switch Self.classify(stats) {
            case .live:
                metrics.append(.flag("\(id).alive", "\(name) — sensor producing an image",
                                     true, shouldBe: true))
            case .frozen:
                // Uniform but not black: no cover over a lens produces this.
                metrics.append(.flag("\(id).alive", "\(name) — sensor producing an image",
                                     false, shouldBe: true, severityIfNot: .fail,
                                     note: "a perfectly uniform, non-black frame — the image "
                                         + "pipeline is frozen, which no lens cover can cause"))
                failures.append(name)
            case .flatBlack where retriedInLight.contains(index) && lightWitnessed:
                // Still nothing after the person confirmed an uncovered lens in
                // a lit room — now, and only now, it is fair to call it dead.
                metrics.append(.flag("\(id).alive", "\(name) — sensor producing an image",
                                     false, shouldBe: true, severityIfNot: .fail,
                                     // Says what was observed, not more: the witness proves
                                     // the room was lit, not that the device was lifted.
                                     note: "still a perfectly black frame after the retry, while "
                                         + "another camera saw light — this sensor is not responding. "
                                         + "If the lens was resting on something, re-run holding the "
                                         + "device up"))
                failures.append(name)
            case .flatBlack:
                metrics.append(AgentMetric(
                    id: "\(id).alive", label: "\(name) — sensor producing an image",
                    kind: .bool, raw: "false", verdict: .skipped,
                    note: retriedInLight.contains(index)
                        ? "still saw nothing — but no camera saw real light in the retry either, "
                          + "so the room was too dark to tell a covered lens from a dead sensor. "
                          + "Try again somewhere brighter"
                        : "saw nothing at all — a covered lens or a dead sensor look the same "
                          + "in the dark; hold the device up in a lit room and re-run to tell which"
                ))
                inconclusive.append(name)
            case .dark:
                metrics.append(AgentMetric(
                    id: "\(id).alive", label: "\(name) — sensor producing an image",
                    kind: .bool, raw: "true", verdict: .skipped,
                    note: "sensor alive (read noise σ=\(stats.standardDeviation.clean)) but the "
                        + "view was dark — lens covered or room unlit, so not confirmed"
                ))
                inconclusive.append(name)
            }

            metrics.append(.number("\(id).luma", "\(name) — mean brightness",
                                   stats.mean, unit: "/255"))
            metrics.append(.number("\(id).variance", "\(name) — detail (σ)",
                                   stats.standardDeviation))
            metrics.append(.reading("\(id).resolution", "\(name) — capture size",
                                    "\(stats.width) × \(stats.height)", unit: "px"))
        }

        context.progress(1, "Done")
        let verdict = rollup(metrics)
        let confirmed = physical.count - failures.count - inconclusive.count
        let summary: String
        if !failures.isEmpty {
            summary = "Not responding: \(failures.joined(separator: ", "))"
        } else if !inconclusive.isEmpty {
            let darkCount: Int = inconclusive.count
            summary = "\(confirmed) of \(physical.count) confirmed live; "
                + "\(darkCount) saw only darkness (not a fault, just unverified)"
        } else {
            summary = "All \(physical.count) cameras returned a live image"
        }
        return result(verdict, summary, metrics: metrics)
    }

    /// How a captured frame should be interpreted.
    enum Classification {
        /// Real detail: the sensor and the optics both work.
        case live
        /// Perfectly uniform and not black. A stuck pipeline; no cover does this.
        case frozen
        /// Perfectly uniform black. A dead sensor — or a lens pressed flat
        /// against something, since darkness is denoised and clamped to black.
        case flatBlack
        /// Alive but with nothing to see: covered lens or an unlit room.
        case dark
    }

    /// Every image sensor produces a little read noise, so a *perfectly* flat
    /// frame is the signature of a frozen or dead sensor. A dark-but-noisy
    /// frame means the sensor is fine and the view is not — which is what a
    /// phone lying face-up on a desk produces, and must not be called a fault.
    static func classify(_ stats: FrameStatistics) -> Classification {
        if stats.standardDeviation <= 0.0001 {
            // Below 1/255 is black for this purpose; the iPad's covered rear
            // lens measured exactly 0 mean and 0 σ.
            return stats.mean < 1 ? .flatBlack : .frozen
        }
        if stats.standardDeviation > 1.5 { return .live }
        return .dark
    }

    /// Frames that say nothing until the device is held up in the light.
    static func needsLight(_ stats: FrameStatistics) -> Bool {
        let c = classify(stats)
        return c == .dark || c == .flatBlack
    }

    static func metricID(for device: AVCaptureDevice) -> String {
        "cam." + device.uniqueID.replacingOccurrences(of: ":", with: "-")
    }

    /// Physical sensors, each once, plus a description of what was merged.
    ///
    /// Virtual devices (Dual, Triple, TrueDepth, LiDAR) are compositions and go.
    /// Two remaining lenses on the same side are only *proven* to be separate
    /// sensors if some virtual device is built from both — iOS provides one for
    /// every side with more than one real camera, which is how an iPhone's
    /// Triple camera vouches for its three rear lenses. Nothing vouches for an
    /// iPad's front Wide and Ultra Wide, because they are one sensor.
    static func distinctSensors(_ all: [AVCaptureDevice]) -> ([AVCaptureDevice], [String]) {
        let virtuals = all.filter(\.isVirtualDevice)
        func provenDistinct(_ a: AVCaptureDevice, _ b: AVCaptureDevice) -> Bool {
            virtuals.contains { v in
                let ids = Set(v.constituentDevices.map(\.uniqueID))
                return ids.contains(a.uniqueID) && ids.contains(b.uniqueID)
            }
        }
        // Keep the native sensor over its derived views: an Ultra Wide front
        // camera's "Wide" entry is a crop of it, and TrueDepth wraps it.
        let preference: [AVCaptureDevice.DeviceType] = [
            .builtInUltraWideCamera, .builtInWideAngleCamera,
            .builtInTelephotoCamera, .builtInTrueDepthCamera,
        ]
        let candidates = all
            .filter { !$0.isVirtualDevice || $0.deviceType == .builtInTrueDepthCamera }
            .filter { preference.contains($0.deviceType) }
            .sorted { (preference.firstIndex(of: $0.deviceType) ?? 99)
                    < (preference.firstIndex(of: $1.deviceType) ?? 99) }

        var kept: [AVCaptureDevice] = []
        var merged: [String] = []
        for c in candidates {
            if let twin = kept.first(where: { $0.position == c.position && !provenDistinct($0, c) }) {
                merged.append("\(rawLabel(for: c)) = \(rawLabel(for: twin))")
            } else {
                kept.append(c)
            }
        }
        // Rear before front, then Wide, Ultra Wide, Telephoto — the order
        // people read a spec sheet in.
        let order: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera,
        ]
        kept.sort {
            if $0.position != $1.position { return $0.position == .back }
            return (order.firstIndex(of: $0.deviceType) ?? 99) < (order.firstIndex(of: $1.deviceType) ?? 99)
        }
        return (kept, merged)
    }

    /// Display names. A side with one camera is just "Rear camera" or "Front
    /// camera" — lens names only mean something where a side has several, and
    /// on an iPad they read as though it had cameras it does not.
    static func names(for sensors: [AVCaptureDevice]) -> [String: String] {
        var out: [String: String] = [:]
        for d in sensors {
            let alone = sensors.filter { $0.position == d.position }.count == 1
            out[d.uniqueID] = alone
                ? (d.position == .front ? "Front camera" : "Rear camera")
                : rawLabel(for: d)
        }
        return out
    }

    static func rawLabel(for device: AVCaptureDevice) -> String {
        let lens = switch device.deviceType {
        case .builtInUltraWideCamera: "Ultra Wide"
        case .builtInTelephotoCamera: "Telephoto"
        case .builtInWideAngleCamera: "Wide"
        case .builtInTrueDepthCamera: "TrueDepth"
        case .builtInLiDARDepthCamera: "LiDAR"
        default: device.localizedName
        }
        let side = switch device.position {
        case .front: "front"
        case .back: "rear"
        default: "unknown"
        }
        return "\(lens) (\(side))"
    }

    struct FrameStatistics {
        var mean: Double
        var standardDeviation: Double
        var width: Int
        var height: Int
    }

    /// Run a one-frame capture session and measure the luminance distribution.
    static func captureStatistics(from device: AVCaptureDevice) async throws -> FrameStatistics {
        let session = AVCaptureSession()
        session.sessionPreset = .photo

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        guard session.canAddOutput(output) else { throw CameraError.cannotAddOutput }
        session.addOutput(output)

        let collector = FrameCollector()
        let queue = DispatchQueue(label: "auscult.camera.capture")
        output.setSampleBufferDelegate(collector, queue: queue)

        session.startRunning()
        defer { session.stopRunning() }

        // Judge the camera on a window of frames, not one. It used to take the
        // 8th frame — about a quarter of a second in — and in dim light
        // auto-exposure is still ramping then, so a working camera could be
        // judged on a warm-up frame that was still black. Now: stop as soon as
        // any frame shows real detail, otherwise watch for up to 3 s and report
        // the most detailed frame seen. A dead sensor stays flat throughout.
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            // `try? await Task.sleep` returns at once when cancelled, so without
            // this check a cancelled run would spin here for six seconds.
            try Task.checkCancellation()
            let snap = collector.snapshot
            if snap.sawLive, let best = snap.best { return best }
            if let best = snap.best, let first = snap.firstMeasuredAt,
               Date().timeIntervalSince(first) >= 3 { return best }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        if let best = collector.snapshot.best { return best }
        throw CameraError.noFrames
    }

    enum CameraError: LocalizedError {
        case cannotAddInput, cannotAddOutput, noFrames

        var errorDescription: String? {
            switch self {
            case .cannotAddInput: "the capture session refused this camera as an input"
            case .cannotAddOutput: "the capture session refused a video output"
            case .noFrames: "the camera delivered no frames within 4 seconds"
            }
        }
    }
}

/// Collects frames and computes luminance statistics off the main thread.
private final class FrameCollector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let lock = NSLock()
    private var best: CameraTest.FrameStatistics?
    private var sawLive = false
    private var firstMeasuredAt: Date?
    private var framesSeen = 0

    var snapshot: (best: CameraTest.FrameStatistics?, sawLive: Bool, firstMeasuredAt: Date?) {
        lock.withLock { (best, sawLive, firstMeasuredAt) }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        lock.lock()
        framesSeen += 1
        // Skip the warm-up frames, then measure every other frame until one
        // shows real detail — halving the work keeps the capture queue free.
        let ready = framesSeen >= 8 && framesSeen % 2 == 0 && !sawLive
        lock.unlock()
        guard ready, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }

        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixels)
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        // Sample a grid rather than every pixel: a few thousand points settle
        // the mean and variance, and a full 12-megapixel pass would stall the
        // capture queue.
        var sum = 0.0, sumSquares = 0.0, n = 0.0
        let step = max(1, min(width, height) / 48)
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let offset = y * bytesPerRow + x * 4
                // BGRA, weighted to approximate perceived luminance.
                let b = Double(bytes[offset]), g = Double(bytes[offset + 1]), r = Double(bytes[offset + 2])
                let luma = 0.0722 * b + 0.7152 * g + 0.2126 * r
                sum += luma
                sumSquares += luma * luma
                n += 1
            }
        }
        guard n > 0 else { return }
        let mean = sum / n
        let variance = max(sumSquares / n - mean * mean, 0)

        let stats = CameraTest.FrameStatistics(
            mean: mean, standardDeviation: variance.squareRoot(),
            width: width, height: height
        )
        lock.withLock {
            if firstMeasuredAt == nil { firstMeasuredAt = Date() }
            if best == nil || stats.standardDeviation > best!.standardDeviation { best = stats }
            if CameraTest.classify(stats) == .live { sawLive = true }
        }
    }
}
