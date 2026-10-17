import Foundation
import Testing
@testable import MouthtypeMac

@Suite struct PreviewAudioSnapshotTests {
    @Test func rollingSnapshotIsBoundedWithoutConsumingFinalAudio() throws {
        let buffer = CaptureBuffer()
        buffer.reset(startedAt: 0)
        let full = (0..<200_000).map(Float.init)
        full.withUnsafeBufferPointer { buffer.append($0, inputFrames: full.count, at: 0) }
        let snapshot = buffer.previewSnapshot(maxSamples: 128_000)
        #expect(snapshot.capturedSampleCount == full.count)
        let isExpectedWindow = snapshot.samples == Array(full.suffix(128_000))
        #expect(isExpectedWindow)
        let finalIsIntact = try buffer.finish() == full
        #expect(finalIsIntact)
        #expect(buffer.previewSnapshot(maxSamples: 128_000).samples.isEmpty)
    }

    @Test func closedOrInvalidWindowProducesNoAudio() {
        let buffer = CaptureBuffer()
        #expect(buffer.previewSnapshot(maxSamples: 16).samples.isEmpty)
        buffer.reset(startedAt: 0)
        [Float](repeating: 0.1, count: 32).withUnsafeBufferPointer { buffer.append($0, inputFrames: 32, at: 0) }
        #expect(buffer.previewSnapshot(maxSamples: 0).samples.isEmpty)
        #expect(buffer.previewSnapshot(maxSamples: -1).samples.isEmpty)
        #expect(buffer.previewSnapshot(maxSamples: 1).samples.count == 1)
    }
}
