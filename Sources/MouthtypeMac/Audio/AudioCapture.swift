// Adapted from Parrot (https://github.com/humanitas-labs/parrot, 0eb4708), MIT License, Copyright (c) 2026 Humanitas Labs.
import AVFoundation
import Foundation

/// Captures microphone audio between `start` and `stop` and returns 16 kHz
/// mono Float32. The AUHAL unit is built by `prepare()` at launch but only
/// runs while recording, so there is no microphone indicator while idle.
///
/// An actor so `HALInput`'s blocking start and stop stay off the main thread.
/// The render callback never touches actor state: it works on the `CaptureBuffer`,
/// `ConverterCache` and `LevelMeter`, which are lock- or atomic-based and
/// reachable only through the closures built in `start`.
public actor AudioCapture {
    public static let targetSampleRate: Double = 16_000

    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: targetSampleRate,
        channels: 1,
        interleaved: false
    )!

    /// The input level in dBFS, safe to read from any thread (the overlay reads it at 60 Hz).
    public nonisolated var reading: LevelReading { meter.reading }

    private let meter = LevelMeter()
    private let input: any CaptureInputDriving
    private let resolveInput: @Sendable () throws -> CaptureInputSelection
    private let authorization: @Sendable () -> AVAuthorizationStatus
    private let requestPermission: @Sendable () -> Void
    private let converters = ConverterCache(targetFormat: AudioCapture.targetFormat)
    private let buffer = CaptureBuffer()
    private var recording = false
    private var device = InputDevice(sampleRate: 0, channels: 0)
    private var delivered = InputDevice(sampleRate: 0, channels: 0)
    private var startDelay: TimeInterval = 0
    private var interruption: (@Sendable () -> Void)?

    /// Failed input buffers in one recording before the input counts as lost.
    static let inputFailureLimit = 20

    public init() {
        input = HALInput(keepsPrepared: true)
        resolveInput = { try CaptureInputSelection.current() }
        authorization = { MicrophoneAccess.status }
        requestPermission = { Task { await MicrophoneAccess.requestIfUndetermined() } }
    }

    init(
        input: any CaptureInputDriving, resolveInput: @escaping @Sendable () throws -> CaptureInputSelection,
        authorization: @escaping @Sendable () -> AVAuthorizationStatus = { .authorized }
    ) {
        self.input = input
        self.resolveInput = resolveInput
        self.authorization = authorization
        requestPermission = {}
    }

    /// Called once from the input's own thread when a recording's input is lost: the device went away, the default
    /// input moved, or the input stopped delivering. Build the handler with `CaptureInterruption.hop`.
    public func setInterruptionHandler(_ handler: (@Sendable () -> Void)?) {
        interruption = handler
    }

    /// Builds the audio unit without starting it. Call at launch once microphone access is granted.
    @discardableResult public func prepare() throws -> Bool {
        guard !recording else { return false }
        if let error = MicrophoneAccess.captureError(for: authorization()) { throw error }
        let selected = try resolveInput()
        let device = selected.device
        try input.prepare(device: device, followsDefault: selected.followsDefault)
        Log.capture.info(
            "prepared \(InputDevice.name(of: device.id) ?? "unknown input", privacy: .public) \(device.sampleRate, format: .fixed(precision: 0), privacy: .public) Hz x \(device.channels, privacy: .public), not started"
        )
        return true
    }

    /// `keyDownAtNanos` is host nanoseconds (`HostClock.now()` units, which is what `CGEvent.timestamp` reports).
    /// Throws `CaptureError`; on a throw nothing is left running.
    public func start(keyDownAtNanos: UInt64) throws {
        guard !recording else { return }
        let startedAt = keyDownAtNanos

        if let error = MicrophoneAccess.captureError(for: authorization()) {
            // A press is the one moment the user is looking; ask again if the system never has.
            requestPermission()
            throw error
        }

        let selected = try resolveInput()
        let device = selected.device
        converters.resetAll()
        buffer.reset(startedAt: startedAt)
        meter.reset()
        let buffer = self.buffer
        let meter = self.meter
        let interrupted = interruption
        let failureLimit = Self.inputFailureLimit
        let sink = InputSink(
            deliver: Self.inputHandler(buffer: buffer, converters: converters, onLevel: { meter.update(samples: $0) }),
            routeChanged: { if buffer.markRouteChanged() { interrupted?() } },
            inputFailed: { if buffer.recordInputFailure() == failureLimit { interrupted?() } }
        )
        do {
            delivered = try input.start(device: device, followsDefault: selected.followsDefault, sink: sink)
        } catch {
            _ = try? buffer.finish()
            throw error
        }
        recording = true
        self.device = device
        startDelay = HostClock.seconds(from: startedAt, to: HostClock.now())
    }

    /// Stops recording and returns the captured samples. Throws `CaptureError.routeChanged` instead of returning a
    /// partial capture if the input route changed mid-recording, and `.notRecording` if nothing was started.
    /// With `salvaging` the partial capture is returned instead.
    public func stop(salvaging: Bool = false) throws -> CapturedAudio {
        guard recording else { throw CaptureError.notRecording }
        recording = false
        input.stop()
        meter.reset()

        // The input has stopped; flush what the resampler still holds.
        converters.drain { buffer.appendTail($0) }
        let stats = buffer.currentStats
        logStats(stats)
        let samples = salvaging ? buffer.finishSalvaging().samples : try buffer.finish()

        func ms(_ seconds: TimeInterval?) -> Double? { seconds.map { $0 * 1000 } }
        return CapturedAudio(
            samples: samples,
            sampleRate: Self.targetSampleRate,
            deviceUID: InputDevice.uid(of: device.id),
            deviceName: InputDevice.name(of: device.id),
            deviceTransport: InputDevice.transport(of: device.id),
            firstSampleMs: ms(stats.firstSampleDelay),
            firstNonzeroMs: ms(stats.firstSoundDelay),
            captureStartMs: startDelay * 1000,
            audioMs: Double(samples.count) * 1000 / Self.targetSampleRate
        )
    }

    /// What the recording in progress has captured from sample `offset` on. Empty when idle.
    public func partialSamples(from offset: Int) -> [Float] {
        recording ? buffer.samples(from: offset) : []
    }

    func previewSnapshot(maxSamples: Int) -> PreviewAudio {
        recording ? buffer.previewSnapshot(maxSamples: min(maxSamples, 128_000)) : PreviewAudio(samples: [], capturedSampleCount: 0)
    }

    /// Discards a recording in progress. Safe when idle.
    public func cancel() {
        if recording {
            recording = false
            input.stop()
            converters.drain { _ in }
            _ = try? buffer.finish()
        }
        meter.reset()
    }

    /// The body of an input callback: note when the buffer's first sample,
    /// and its first non-zero sample, were captured, then convert to 16 kHz
    /// and append. `firstFrame` and `now` are `HostClock` nanoseconds. A
    /// buffer outside a recording is counted and dropped.
    static func inputHandler(
        buffer: CaptureBuffer,
        converters: ConverterCache,
        onLevel: (@Sendable (UnsafeBufferPointer<Float>) -> Void)?
    ) -> @Sendable (_ pcm: AVAudioPCMBuffer, _ firstFrame: UInt64, _ now: UInt64) -> Void {
        return { pcm, firstFrame, now in
            guard buffer.admit() else { return }
            var firstSound: UInt64?
            if buffer.awaitingSound, pcm.format.sampleRate > 0, let frame = firstNonZeroFrame(pcm) {
                firstSound = firstFrame &+ UInt64(Double(frame) / pcm.format.sampleRate * 1_000_000_000)
            }
            buffer.noteInput(firstFrameAt: firstFrame, firstSoundAt: firstSound)
            let converted = converters.convert(pcm) { chunk in
                buffer.append(chunk, inputFrames: Int(pcm.frameLength), at: now)
                onLevel?(chunk)
            }
            if !converted { buffer.recordConversionFailure() }
        }
    }

    /// The first frame in which any channel is not exactly zero, or nil.
    static func firstNonZeroFrame(_ pcm: AVAudioPCMBuffer) -> Int? {
        guard let channels = pcm.floatChannelData else { return nil }
        let interleaved = pcm.format.isInterleaved
        let stride = pcm.stride
        var first: Int?
        for c in 0..<Int(pcm.format.channelCount) {
            let data = channels[interleaved ? 0 : c]
            let offset = interleaved ? c : 0
            var i = 0
            let limit = first ?? Int(pcm.frameLength)
            while i < limit {
                if data[i * stride + offset] != 0 {
                    first = i
                    break
                }
                i += 1
            }
        }
        return first
    }

    /// One line per recording: counts and timings, never audio.
    private func logStats(_ stats: CaptureBuffer.Stats) {
        func ms(_ delay: TimeInterval?) -> String { delay.map { String(format: "%.0f ms", $0 * 1000) } ?? "none" }
        var line = String(
            format: "input %.0f Hz x %u, delivered %.0f Hz x %u, start %.0f ms",
            device.sampleRate, device.channels, delivered.sampleRate, delivered.channels, startDelay * 1000
        )
        line += ", press to first sample \(ms(stats.firstSampleDelay)), first sound \(ms(stats.firstSoundDelay))"
        line += ", first buffer \(ms(stats.firstBufferDelay)), \(stats.buffers) buffers, \(stats.inputFrames) frames"
        if stats.conversionFailures > 0 { line += ", \(stats.conversionFailures) conversion failures" }
        if stats.inputFailures > 0 { line += ", \(stats.inputFailures) input failures" }
        Log.capture.info("\(line, privacy: .public)")
    }
}
