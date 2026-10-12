import Foundation
import Synchronization

/// A 0...1 input level written by the render callback and read from the main thread. A single atomic word, so
/// neither side takes a lock. Only the render thread calls `update`, so its read-then-store of the decay is safe.
final class LevelMeter: Sendable {
    static let floorDb: Float = -60
    /// Fall per callback (~10 ms), so the meter drops over ~250 ms instead of flickering.
    static let decay: Float = 0.04

    private let bits = Atomic<UInt32>(0)

    var value: Float { Float(bitPattern: bits.load(ordering: .relaxed)) }

    func update(rms: Float) {
        let db = 20 * log10(max(rms, 1e-6))
        let target = min(1, max(0, (db - Self.floorDb) / -Self.floorDb))
        bits.store(max(target, value - Self.decay).bitPattern, ordering: .relaxed)
    }

    func reset() {
        bits.store(0, ordering: .relaxed)
    }
}
