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
        var failures: [String] = []

        for (index, device) in physical.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            let name = Self.label(for: device)
            context.progress(
                Double(index) / Double(physical.count), "Capturing from \(name)"
            )

            do {
                let stats = try await Self.captureStatistics(from: device)
                let id = "cam.\(device.uniqueID.replacingOccurrences(of: ":", with: "-"))"

                // A live sensor produces variance. A failed one produces a flat
                // field, whatever colour that field happens to be.
                let alive = stats.standardDeviation > 1.5
                metrics.append(.flag("\(id).alive", "\(name) — sensor producing an image", alive,
                                     shouldBe: true, severityIfNot: .fail,
                                     note: alive
                                        ? nil
                                        : "the frame is a flat field (σ=\(stats.standardDeviation.clean)), "
                                          + "which is what a dead sensor returns"))
                metrics.append(.number("\(id).luma", "\(name) — mean brightness",
                                       stats.mean, unit: "/255",
                                       note: stats.mean < 3
                                        ? "almost black — is the lens covered?"
                                        : (stats.mean > 250 ? "almost white — is it pointed at a light?" : nil)))
                metrics.append(.number("\(id).variance", "\(name) — detail (σ)",
                                       stats.standardDeviation))
                metrics.append(.reading("\(id).resolution", "\(name) — capture size",
                                        "\(stats.width) × \(stats.height)", unit: "px"))
                if !alive { failures.append(name) }
            } catch {
                metrics.append(.flag("cam.\(index).alive", "\(name) — capture", false,
                                     shouldBe: true, severityIfNot: .fail,
                                     note: error.localizedDescription))
                failures.append(name)
            }
        }

        context.progress(1, "Done")
        let verdict = rollup(metrics)
        let summary = failures.isEmpty
            ? "All \(physical.count) cameras returned a live image"
            : "No usable image from: \(failures.joined(separator: ", "))"
        return result(verdict, summary, metrics: metrics)
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
