// Adapted from Parrot (https://github.com/humanitas-labs/parrot, 0eb4708), MIT License, Copyright (c) 2026 Humanitas Labs.
import AVFoundation
import Foundation

/// Converts tap buffers to the capture's target format, keeping one
/// `AVAudioConverter` and one output buffer per input format.
///
/// The tap is installed with `format: nil`, so the first buffer is the first
/// time the real input format is known. Building the converter then, and
/// reusing it for every later buffer in that format, keeps allocation out of
/// the realtime callback after the first buffer.
final class ConverterCache: @unchecked Sendable {
    private final class Entry {
        let format: AVAudioFormat
        let converter: AVAudioConverter
        var output: AVAudioPCMBuffer

        init(format: AVAudioFormat, converter: AVAudioConverter, output: AVAudioPCMBuffer) {
            self.format = format
            self.converter = converter
            self.output = output
        }
    }

    let targetFormat: AVAudioFormat
    private let lock = NSLock()
    private var entries: [Entry] = []

    init(targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
    }

    /// Converters built so far, one per distinct input format.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Clears each converter's internal state (resampler history), so a new
    /// recording does not start with the tail of the previous one.
    func resetAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.forEach { $0.converter.reset() }
    }

    /// Converts `input` and passes the result to `body`. The pointer is only
    /// valid inside `body`. Returns false if no converter could be built for
    /// the input format or the conversion failed.
    ///
    /// When `input` is in a different format from the previous buffer, the
    /// converter that was active is flushed to `tail` first and reset, so its
    /// held audio lands ahead of the new format's and nothing stale is left
    /// in it for a later return to that format.
    @discardableResult
    func convert(
        _ input: AVAudioPCMBuffer,
        tail: (UnsafeBufferPointer<Float>) -> Void,
        _ body: (UnsafeBufferPointer<Float>) -> Void
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard input.format.sampleRate > 0 else { return false }
        if let active = entries.last, active.format != input.format { flush(active, tail) }
        guard let entry = entry(for: input.format) else { return false }

        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let needed = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        if entry.output.frameCapacity < needed {
            guard let bigger = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: needed) else { return false }
            entry.output = bigger
        }
        let output = entry.output
        output.frameLength = 0

        var consumed = false
        var error: NSError?
        let status = entry.converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, let channels = output.floatChannelData else { return false }
        body(UnsafeBufferPointer(start: channels[0], count: Int(output.frameLength)))
        return true
    }

    /// `convert` with a format change's tail passed to `body` as well.
    @discardableResult
    func convert(_ input: AVAudioPCMBuffer, _ body: (UnsafeBufferPointer<Float>) -> Void) -> Bool {
        convert(input, tail: body, body)
    }

    /// Flushes the audio the active converter still holds and passes it to
    /// `body`, possibly in several pieces. The resampler works in blocks, so
    /// without this the last ~85 ms of a recording (the end of the last word)
    /// never comes out. Call once the tap has stopped.
    func drain(_ body: (UnsafeBufferPointer<Float>) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries.last else { return }
        flush(entry, body)
    }

    /// Ends `entry`'s stream, passes what it still held to `body`, and resets
    /// it so its next buffer starts clean. Caller holds the lock.
    private func flush(_ entry: Entry, _ body: (UnsafeBufferPointer<Float>) -> Void) {
        defer { entry.converter.reset() }
        let output = entry.output
        for _ in 0..<16 {
            output.frameLength = 0
            var error: NSError?
            let status = entry.converter.convert(to: output, error: &error) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            guard status != .error, let channels = output.floatChannelData else { return }
            if output.frameLength > 0 {
                body(UnsafeBufferPointer(start: channels[0], count: Int(output.frameLength)))
            }
            guard status == .haveData else { return }
        }
    }

    /// The entry for `format`, built on first use. Caller holds the lock.
    private func entry(for format: AVAudioFormat) -> Entry? {
        if let last = entries.last, last.format == format { return last }
        if let index = entries.firstIndex(where: { $0.format == format }) {
            let hit = entries.remove(at: index)
            hit.converter.reset()
            entries.append(hit)
            return hit
        }
        guard let converter = AVAudioConverter(from: format, to: targetFormat),
            let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096)
        else { return nil }
        let entry = Entry(format: format, converter: converter, output: output)
        entries.append(entry)
        return entry
    }
}
