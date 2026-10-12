import CoreGraphics
import Foundation

/// Level-to-meter maths for the pill, with no UI in it. One 0...1 level drives ten columns: each column scales the
/// level by a fixed weight (tallest in the middle), reads it slightly late (the further from the middle, the later,
/// so it ripples outward), and is smoothed with a fast attack and a slower release. The smoothed fractions are then
/// quantised to whole lit segments, because the meter is made of discrete segments.
struct BarModel {
    static let barCount = 10
    /// Segments in each column, matching the skin's meter.
    static let segmentRows = 5

    /// Fixed per-column weights, 1 in the middle pair and lower toward the ends.
    static let weights: [Float] = {
        let raw = (0..<barCount).map { 0.3 + 0.7 * cos(Float.pi * abs(Float($0) - 4.5) / Float(barCount)) }
        let peak = raw.max() ?? 1
        return raw.map { $0 / peak }
    }()

    /// How late each column reads the level, in seconds.
    static let delays: [TimeInterval] = (0..<barCount).map { abs(Double($0) - 4.5) * 0.012 }

    static let attackTime: TimeInterval = 0.03
    static let releaseTime: TimeInterval = 0.16
    /// Below this a column snaps to silence, so silence is exactly the baseline rather than a long tail.
    private static let settleFloor: Float = 0.002

    private var smoothed = [Float](repeating: 0, count: barCount)
    private var history: [(age: TimeInterval, level: Float)] = []

    mutating func reset() {
        smoothed = [Float](repeating: 0, count: Self.barCount)
        history.removeAll()
    }

    /// Advances `dt` seconds with the current input level and returns each column's smoothed fraction, 0...1.
    mutating func step(level: Float, dt: TimeInterval) -> [Float] {
        let dt = dt.isFinite ? max(0, dt) : 0
        let level = level.isFinite ? min(1, max(0, level)) : 0

        for i in history.indices { history[i].age += dt }
        history.append((0, level))
        history.removeAll { $0.age > (Self.delays.last ?? 0) + 0.05 }

        for i in 0..<Self.barCount {
            let target = delayedLevel(Self.delays[i]) * Self.weights[i]
            let tau = target > smoothed[i] ? Self.attackTime : Self.releaseTime
            let alpha = Float(1 - exp(-dt / tau))
            smoothed[i] += (target - smoothed[i]) * alpha
            if smoothed[i] < Self.settleFloor, target == 0 { smoothed[i] = 0 }
        }
        return smoothed
    }

    /// The level as it was `delay` seconds ago: the newest sample at least that old, else the oldest we have.
    private func delayedLevel(_ delay: TimeInterval) -> Float {
        history.last(where: { $0.age >= delay })?.level ?? history.first?.level ?? 0
    }

    /// Whole segments to light per column, 1...`segments`: the baseline segment is always lit, so silence is a
    /// single row, and a full column needs a fraction of 1.
    static func litSegments(_ fractions: [Float], segments: Int) -> [Int] {
        guard segments > 0 else { return fractions.map { _ in 0 } }
        return fractions.map { fraction in
            let f = fraction.isFinite ? min(1, max(0, fraction)) : 0
            return min(segments, max(1, Int((f * Float(segments) - 0.01).rounded(.up))))
        }
    }

    /// Processing: a three-column run of lit segments travelling back and forth along the row.
    static let processingStepsPerSecond = 12.0

    static func processingColumns(time: TimeInterval, columns: Int) -> ClosedRange<Int> {
        guard columns > 1 else { return 0...0 }
        let period = 2 * (columns - 1)
        let step = Int(max(0, time.isFinite ? time : 0) * processingStepsPerSecond) % period
        let centre = step < columns ? step : period - step
        return max(0, centre - 1)...min(columns - 1, centre + 1)
    }
}
