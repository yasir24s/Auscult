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

        // Physical lenses only. The virtual multi-camera devices (.builtInDualCamera
        // and friends) are compositions of lenses already in the list, so testing
        // them would double-count and slow the run for no extra coverage.
        let physical = discovery.devices.filter { device in
            switch device.deviceType {
            case .builtInWideAngleCamera, .builtInUltraWideCamera,
                 .builtInTelephotoCamera, .builtInTrueDepthCamera:
                true
            default:
                false
            }
        }

        guard !physical.isEmpty else {
            return result(.fail, "No cameras were discovered on this device",
                          detail: "a device of this type should report several")
        }

        var metrics: [AgentMetric] = [
            .number("count", "Cameras discovered", Double(physical.count)),
            .list("discovered", "Lenses", physical.map { Self.label(for: $0) }),
        ]

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
                "Capturing from \(Self.label(for: device))"
            )
            do {
                results.append((device, try await Self.captureStatistics(from: device), nil))
            } catch {
                results.append((device, nil, error.localizedDescription))
            }
        }

        let darkIndices = results.indices.filter { index in
            results[index].stats.map(Self.isDark) ?? false
        }

        if !darkIndices.isEmpty {
            let names = darkIndices.map { Self.label(for: results[$0].device) }
            context.awaitingUser(
                "Hold the device up so nothing covers the lenses, then confirm on screen"
            )
            let plural: String = names.count == 1 ? "camera" : "cameras"
            let joined: String = names.joined(separator: ", ")
            let message: String = "\(names.count) \(plural) saw only darkness (\(joined)).\n\n"
                + "Hold the device up, away from any surface, with the room lit — then tap Ready."
            let answer = await context.askUser(AgentServer.UserPrompt(
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
                        "Re-testing \(Self.label(for: results[index].device))"
                    )
                    if let retry = try? await Self.captureStatistics(from: results[index].device) {
                        results[index].stats = retry
                    }
                }
            }
        }

        var failures: [String] = []
        var inconclusive: [String] = []

        for entry in results {
            let name = Self.label(for: entry.device)
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
                metrics.append(.flag("\(id).alive", "\(name) — sensor producing an image",
                                     false, shouldBe: true, severityIfNot: .fail,
                                     note: "perfectly uniform frame with not even sensor "
                                         + "read noise — this is a dead sensor"))
                failures.append(name)
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
            summary = "Dead sensor on: \(failures.joined(separator: ", "))"
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
        /// Perfectly uniform — not even read noise. Only a dead sensor does this.
        case frozen
        /// Alive but with nothing to see: covered lens or an unlit room.
        case dark
    }

    /// Every image sensor produces a little read noise, so a *perfectly* flat
    /// frame is the signature of a frozen or dead sensor. A dark-but-noisy
    /// frame means the sensor is fine and the view is not — which is what a
    /// phone lying face-up on a desk produces, and must not be called a fault.
    static func classify(_ stats: FrameStatistics) -> Classification {
        if stats.standardDeviation <= 0.0001 { return .frozen }
        if stats.standardDeviation > 1.5 { return .live }
        return .dark
    }

    static func isDark(_ stats: FrameStatistics) -> Bool {
        classify(stats) == .dark
    }

    static func metricID(for device: AVCaptureDevice) -> String {
        "cam." + device.uniqueID.replacingOccurrences(of: ":", with: "-")
    }

    static func label(for device: AVCaptureDevice) -> String {
        let lens = switch device.deviceType {
        case .builtInUltraWideCamera: "Ultra-wide"
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

        // Discard the first frames: sensors start dark and auto-exposure needs a
        // moment, so an immediate grab would look like a failed camera.
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if let stats = collector.statistics { return stats }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
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
    private var _statistics: CameraTest.FrameStatistics?
    private var framesSeen = 0

    var statistics: CameraTest.FrameStatistics? { lock.withLock { _statistics } }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        lock.lock()
        framesSeen += 1
        // Let auto-exposure settle before believing what we see.
        let ready = framesSeen >= 8 && _statistics == nil
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

        lock.withLock {
            _statistics = CameraTest.FrameStatistics(
                mean: mean, standardDeviation: variance.squareRoot(),
                width: width, height: height
            )
        }
    }
}
