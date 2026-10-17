// Adapted from Parrot (https://github.com/humanitas-labs/parrot, 0eb4708), MIT License, Copyright (c) 2026 Humanitas Labs.
import Foundation

/// What one recording has captured so far. The audio thread appends to it;
/// `AudioCapture.stop()` reads it once. It holds no engine, so the rules
/// about what a stop returns are testable without hardware.
final class CaptureBuffer: @unchecked Sendable {
    /// Counts and timings for one recording. Never audio.
    struct Stats: Equatable {
        /// Tap callbacks that delivered converted audio.
        var buffers = 0
        /// Frames received at the input's own sample rate.
        var inputFrames = 0
        /// Buffers the converter failed on.
        var conversionFailures = 0
        /// Seconds from `start()` to the first buffer, or nil if none arrived.
        var firstBufferDelay: TimeInterval?
        /// Seconds from `start()` (the press) to the moment the first sample
        /// of the recording was captured, by the buffer's host timestamp:
        /// anything said before it is lost. Nil if no buffer arrived.
        var firstSampleDelay: TimeInterval?
        /// The same to the first sample that is not exactly zero. Some inputs
        /// deliver digital silence while they settle; that is lost too.
        var firstSoundDelay: TimeInterval?
        /// Buffers the input failed to deliver (a render error).
        var inputFailures = 0
    }

    private let lock = NSLock()
    private var samples: [Float] = []
    private var stats = Stats()
    private var routeChanged = false
    private var startedAt: UInt64 = 0
    private var isOpen = false
    private var closedBuffers = 0

    /// Clears everything for a new recording that started at `startedAt`
    /// (`HostClock` nanoseconds).
    func reset(startedAt: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        samples.removeAll(keepingCapacity: true)
        stats = Stats()
        routeChanged = false
        self.startedAt = startedAt
        isOpen = true
    }

    /// True while a recording is open. A buffer arriving outside one is
    /// counted and must be dropped: it means the input ran between presses.
    func admit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if !isOpen { closedBuffers += 1 }
        return isOpen
    }

    /// Buffers that arrived while no recording was open, over this buffer's
    /// lifetime. Zero unless an input ran between presses.
    var buffersWhileClosed: Int {
        lock.lock()
        defer { lock.unlock() }
        return closedBuffers
    }

    /// Counts a buffer the input failed to deliver and returns how many have failed in this recording.
    @discardableResult
    func recordInputFailure() -> Int {
        lock.lock()
        defer { lock.unlock() }
        stats.inputFailures += 1
        return stats.inputFailures
    }

    /// A copy of what has been captured from sample `offset` on, for the in-progress copy on disk.
    func samples(from offset: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        guard offset < samples.count else { return [] }
        return Array(samples[max(0, offset)...])
    }

    /// Copies only the newest bounded window under the same lock as the render callback.
    func previewSnapshot(maxSamples: Int) -> PreviewAudio {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen, maxSamples > 0 else { return PreviewAudio(samples: [], capturedSampleCount: 0) }
        return PreviewAudio(samples: Array(samples.suffix(maxSamples)), capturedSampleCount: samples.count)
    }

    /// Appends converted 16 kHz samples from one tap callback.
    func append(_ chunk: UnsafeBufferPointer<Float>, inputFrames: Int, at now: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if stats.firstBufferDelay == nil {
            stats.firstBufferDelay = HostClock.seconds(from: startedAt, to: now)
        }
        stats.buffers += 1
        stats.inputFrames += inputFrames
        samples.append(contentsOf: chunk)
    }

    /// Records when the first frame of an input buffer was captured, and
    /// the first non-zero frame if it has one (host nanoseconds). Only the
    /// first of each counts.
    func noteInput(firstFrameAt: UInt64, firstSoundAt: UInt64?) {
        lock.lock()
        defer { lock.unlock() }
        if stats.firstSampleDelay == nil {
            stats.firstSampleDelay = HostClock.seconds(from: startedAt, to: firstFrameAt)
        }
        if stats.firstSoundDelay == nil, let firstSoundAt {
            stats.firstSoundDelay = HostClock.seconds(from: startedAt, to: firstSoundAt)
        }
    }

    /// True until a non-zero sample has been noted, so the audio thread
    /// scans for one only while it matters.
    var awaitingSound: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stats.firstSoundDelay == nil
    }

    /// Appends the converter's tail after the last callback. Not counted as
    /// a buffer.
    func appendTail(_ chunk: UnsafeBufferPointer<Float>) {
        lock.lock()
        defer { lock.unlock() }
        samples.append(contentsOf: chunk)
    }

    func recordConversionFailure() {
        lock.lock()
        defer { lock.unlock() }
        stats.conversionFailures += 1
    }

    /// Called from the configuration-change notification. Only sets a flag;
    /// the engine is torn down in `stop()`, never inside the notification.
    /// True the first time it is set in a recording.
    @discardableResult
    func markRouteChanged() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let first = !routeChanged
        routeChanged = true
        return first
    }

    var currentStats: Stats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    /// Ends the recording and returns its samples. If the route changed at
    /// any point, the partial capture is discarded and this throws
    /// `CaptureError.routeChanged`, so it is never delivered as a success.
    /// Either way the buffer is empty afterwards.
    func finish() throws -> [Float] {
        let (captured, changed) = finishSalvaging()
        if changed { throw CaptureError.routeChanged }
        return captured
    }

    /// Ends the recording and returns its samples even if the route changed, with whether it did. For a stop that
    /// keeps a partial capture instead of throwing it away.
    func finishSalvaging() -> (samples: [Float], routeChanged: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let captured = samples
        let changed = routeChanged
        samples.removeAll(keepingCapacity: true)
        routeChanged = false
        isOpen = false
        return (captured, changed)
    }
}
