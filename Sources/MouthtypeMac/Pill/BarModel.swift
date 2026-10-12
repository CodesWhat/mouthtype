import CoreGraphics
import Foundation

/// Level-to-bar-heights maths for the pill, with no UI in it. One 0...1 level drives ten bars: each bar scales the
/// level by a fixed weight (tallest in the middle), reads it slightly late (the further from the middle, the later,
/// so it ripples outward like a waveform), and is smoothed with a fast attack and a slower release.
struct BarModel {
    static let barCount = 10
    static let minHeight: CGFloat = 2.25
    static let maxHeight: CGFloat = 14.25

    /// Fixed per-bar weights, 1 in the middle pair and lower toward the ends.
    static let weights: [Float] = {
        let raw = (0..<barCount).map { 0.3 + 0.7 * cos(Float.pi * abs(Float($0) - 4.5) / Float(barCount)) }
        let peak = raw.max() ?? 1
        return raw.map { $0 / peak }
    }()

    /// How late each bar reads the level, in seconds.
    static let delays: [TimeInterval] = (0..<barCount).map { abs(Double($0) - 4.5) * 0.012 }

    static let attackTime: TimeInterval = 0.03
    static let releaseTime: TimeInterval = 0.16
    /// Below this a bar snaps to a dot, so silence is exactly dots rather than a long tail.
    private static let settleFloor: Float = 0.002

    private var smoothed = [Float](repeating: 0, count: barCount)
    private var history: [(age: TimeInterval, level: Float)] = []

    mutating func reset() {
        smoothed = [Float](repeating: 0, count: Self.barCount)
        history.removeAll()
    }

    /// Advances `dt` seconds with the current input level and returns the bar heights.
    mutating func step(level: Float, dt: TimeInterval) -> [CGFloat] {
        let dt = dt.isFinite ? max(0, dt) : 0
        let level = level.isFinite ? min(1, max(0, level)) : 0

        for i in history.indices { history[i].age += dt }
        history.append((0, level))
        history.removeAll { $0.age > (Self.delays.last ?? 0) + 0.05 }

        var heights = [CGFloat](repeating: Self.minHeight, count: Self.barCount)
        for i in 0..<Self.barCount {
            let target = delayedLevel(Self.delays[i]) * Self.weights[i]
            let tau = target > smoothed[i] ? Self.attackTime : Self.releaseTime
            let alpha = Float(1 - exp(-dt / tau))
            smoothed[i] += (target - smoothed[i]) * alpha
            if smoothed[i] < Self.settleFloor, target == 0 { smoothed[i] = 0 }
            heights[i] = Self.height(for: smoothed[i])
        }
        return heights
    }

    /// The level as it was `delay` seconds ago: the newest sample at least that old, else the oldest we have.
    private func delayedLevel(_ delay: TimeInterval) -> Float {
        history.last(where: { $0.age >= delay })?.level ?? history.first?.level ?? 0
    }

    static func height(for fraction: Float) -> CGFloat {
        minHeight + (maxHeight - minHeight) * CGFloat(min(1, max(0, fraction)))
    }

    /// The processing animation: a slow low-amplitude ripple travelling across the bars, with no level input.
    static func ripple(time: TimeInterval) -> [CGFloat] {
        (0..<barCount).map { i in
            let phase = 2 * Double.pi * (time / 1.4 - Double(i) / 12)
            return height(for: Float(0.16 * (0.5 + 0.5 * sin(phase))))
        }
    }
}
