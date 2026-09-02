import Foundation
import AVFoundation
import Accelerate

/// Plays a tone through the speaker and listens for it on the microphone.
///
/// This is the only way to test either transducer objectively from software: a
/// speaker can be commanded to play and report success while producing no
/// sound, and a microphone can be opened and return digital silence. Closing
/// the loop — emit a known frequency, record, and look for that exact frequency
/// in the spectrum — proves both ends physically work.
///
/// The detection is a Goertzel-style magnitude comparison rather than a peak
/// search: what matters is the energy at the tone frequency *relative to* the
/// rest of the band, so a noisy room fails to fool it and a quiet one doesn't
/// cause a false negative.
struct AudioLoopbackTest: AgentTest {
    /// Deliberately mid-band: high enough to be well clear of handling rumble
    /// and mains hum, low enough that the speaker reproduces it efficiently.
    private static let toneFrequency: Double = 1000
    private static let sampleRate: Double = 48000
    private static let duration: Double = 1.4

    var descriptor: AgentTestDescriptor {
        let status = AVAudioApplication.shared.recordPermission
        return AgentTestDescriptor(
            id: "audio.loopback", title: "Speaker & Microphone",
            section: "Audio",
            permission: .microphone,
            permissionGranted: status == .granted,
            estimatedSeconds: 12,
            unavailableReason: status == .denied
                ? "microphone access is denied — enable it in Settings › Privacy › Microphone"
                : nil
        )
    }

    func run(context: AgentTestContext) async throws -> AgentTestResult {
        if AVAudioApplication.shared.recordPermission == .undetermined {
            context.awaitingUser("Allow microphone access on the device to test the speaker and mics")
            _ = await AVAudioApplication.requestRecordPermission()
        }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            return result(.skipped, "Microphone access was not granted",
                          detail: "enable it in Settings › Privacy › Microphone and re-run")
        }

        let session = AVAudioSession.sharedInstance()
        var metrics: [AgentMetric] = []

        do {
            // playAndRecord with the speaker override: without the override iOS
            // routes to the receiver, which the mics barely hear.
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: [])
            try? session.overrideOutputAudioPort(.speaker)
        } catch {
            return result(.error, "Could not configure the audio session",
                          detail: error.localizedDescription)
        }
        defer { try? session.setActive(false, options: []) }

        // Report the routes iOS believes exist, which is useful on its own.
        let inputs = session.currentRoute.inputs.map { $0.portName }
        let outputs = session.currentRoute.outputs.map { $0.portName }
        metrics.append(.list("inputs", "Active input route", inputs))
        metrics.append(.list("outputs", "Active output route", outputs))
        if let available = session.availableInputs, !available.isEmpty {
            metrics.append(.list("availableInputs", "Available inputs",
                                 available.map { $0.portName }))
            // Each built-in mic appears as a data source on the built-in port.
            for port in available where port.portType == .builtInMic {
                if let sources = port.dataSources, !sources.isEmpty {
                    metrics.append(.list("micElements", "Built-in microphone elements",
                                         sources.map { $0.dataSourceName },
                                         note: "\(sources.count) physical microphones reported"))
                }
            }
        }

        context.progress(0.2, "Playing a 1 kHz tone and recording")

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        engine.connect(player, to: engine.mainMixerNode, format: nil)

        guard let tone = Self.makeTone(
            frequency: Self.toneFrequency,
            duration: Self.duration,
            format: outputFormat
        ) else {
            return result(.error, "Could not synthesise the test tone")
        }

        // Tap the input, not the output: we want what the microphone heard.
        let inputFormat = engine.inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            return result(.unsupported, "The input node reported no usable format",
                          detail: "no microphone is available in this route")
        }

        let recorder = SampleRecorder()
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            recorder.append(buffer)
        }

        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            return result(.error, "Could not start the audio engine",
                          detail: error.localizedDescription)
        }

        // A moment of silence first, to measure the room's noise floor. Without
        // it a loud environment is indistinguishable from a working speaker.
        try? await Task.sleep(nanoseconds: 400_000_000)
        let noiseFloor = recorder.rootMeanSquare()
        recorder.reset()

        player.scheduleBuffer(tone, at: nil, options: [], completionHandler: nil)
        player.play()

        context.progress(0.55, "Listening")
        try? await Task.sleep(nanoseconds: UInt64((Self.duration + 0.3) * 1_000_000_000))

        player.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        let recorded = recorder.samples()
        guard recorded.count > 2048 else {
            metrics.append(.flag("micCapturing", "Microphone delivered audio", false,
                                 shouldBe: true, severityIfNot: .fail,
                                 note: "only \(recorded.count) samples arrived"))
            return result(rollup(metrics), "The microphone delivered almost no audio",
                          metrics: metrics)
        }

        context.progress(0.85, "Analysing the spectrum")

        let level = Self.rootMeanSquare(recorded)
        let toneMagnitude = Self.goertzelMagnitude(
            recorded, frequency: Self.toneFrequency, sampleRate: inputFormat.sampleRate
        )
        // Two off-tone probes bracket the tone, giving a local baseline for the
        // band rather than comparing against total energy.
        let offToneMagnitude = (
            Self.goertzelMagnitude(recorded, frequency: 400, sampleRate: inputFormat.sampleRate)
            + Self.goertzelMagnitude(recorded, frequency: 2600, sampleRate: inputFormat.sampleRate)
        ) / 2

        let ratio = offToneMagnitude > 0 ? toneMagnitude / offToneMagnitude : 0
        let ratioDB = ratio > 0 ? 20 * log10(ratio) : -120

        metrics.append(.flag("micCapturing", "Microphone delivered audio",
                             recorded.count > 2048, shouldBe: true, severityIfNot: .fail))
        metrics.append(.number("noiseFloor", "Ambient noise floor",
                               20 * log10(max(noiseFloor, 1e-7)), unit: "dBFS"))
        metrics.append(.number("recordedLevel", "Recorded level during tone",
                               20 * log10(max(level, 1e-7)), unit: "dBFS"))

        // The verdict: was the emitted frequency actually heard?
        metrics.append(.graded(
            "toneDetected", "1 kHz tone recovered", ratioDB, unit: "dB",
            warnAt: 12, failAt: 6, higherIsBetter: true,
            note: "energy at 1 kHz versus neighbouring frequencies — "
                + "this passes only if the speaker produced sound and a microphone heard it",
            expectation: "above 12 dB when both work"
        ))

        // Distinguish the two failure modes, which need different repairs.
        if ratioDB < 6 {
            let micWorks = level > noiseFloor * 1.3 || level > 1e-4
            metrics.append(.flag("interpretation.micAlive", "Microphone appears alive", micWorks,
                                 note: micWorks
                                    ? "the microphone is recording, so the speaker is the suspect"
                                    : "the microphone recorded near-silence, so it is the suspect"))
        }

        let verdict = rollup(metrics)
        let summary = ratioDB >= 12
            ? "Tone recovered at \(ratioDB.clean) dB above the band — speaker and microphone both working"
            : "Tone not clearly recovered (\(ratioDB.clean) dB) — see the interpretation below"
        return result(verdict, summary, metrics: metrics)
    }

    // MARK: Signal helpers

    static func makeTone(
        frequency: Double, duration: Double, format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(duration * format.sampleRate)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channels = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = frames

        let step = 2 * Double.pi * frequency / format.sampleRate
        // Short fades stop the speaker clicking, which would smear the spectrum.
        let fade = Int(min(0.01 * format.sampleRate, Double(frames) / 4))
        for frame in 0..<Int(frames) {
            var amplitude = 0.6
            if frame < fade { amplitude *= Double(frame) / Double(fade) }
            if frame > Int(frames) - fade { amplitude *= Double(Int(frames) - frame) / Double(fade) }
            let value = Float(sin(step * Double(frame)) * amplitude)
            for channel in 0..<Int(format.channelCount) {
                channels[channel][frame] = value
            }
        }
        return buffer
    }

    static func rootMeanSquare(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var mean: Float = 0
        vDSP_measqv(samples, 1, &mean, vDSP_Length(samples.count))
        return Double(mean).squareRoot()
    }

    /// Magnitude of one frequency bin, by the Goertzel algorithm.
    ///
    /// Cheaper and more precise here than a full FFT: we know exactly which
    /// frequencies we care about, so there is no reason to compute the rest of
    /// the spectrum or to worry about the tone straddling two bins.
    static func goertzelMagnitude(
        _ samples: [Float], frequency: Double, sampleRate: Double
    ) -> Double {
        guard sampleRate > 0, !samples.isEmpty else { return 0 }
        let omega = 2 * Double.pi * frequency / sampleRate
        let coefficient = 2 * cos(omega)
        var s1 = 0.0, s2 = 0.0
        for sample in samples {
            let s0 = Double(sample) + coefficient * s1 - s2
            s2 = s1
            s1 = s0
        }
        let magnitudeSquared = s1 * s1 + s2 * s2 - coefficient * s1 * s2
        return (max(magnitudeSquared, 0)).squareRoot() / Double(samples.count)
    }
}

/// Thread-safe accumulator for tapped microphone buffers.
private final class SampleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [Float] = []

    func append(_ pcm: AVAudioPCMBuffer) {
        guard let data = pcm.floatChannelData else { return }
        let count = Int(pcm.frameLength)
        // First channel only: mixing would attenuate a tone that reaches one
        // microphone earlier than another.
        let channel = data[0]
        lock.withLock {
            buffer.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
        }
    }

    func samples() -> [Float] { lock.withLock { buffer } }
    func reset() { lock.withLock { buffer.removeAll(keepingCapacity: true) } }

    func rootMeanSquare() -> Double {
        AudioLoopbackTest.rootMeanSquare(samples())
    }
}
