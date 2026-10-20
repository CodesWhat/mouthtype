import CoreGraphics
import Foundation

/// The Ring pill's measurements and the maths behind them, with no layers in it. The spokes sit on a circle around the
/// middle; the ten smoothed bar levels are folded onto them so the top and bottom read the middle bars and the two sides
/// the outer ones, which keeps the picture balanced left to right and top to bottom.
enum RingPillLayout {
    static let diameter: CGFloat = 40
    static let spokeCount = 24
    static let innerRadius: CGFloat = 11
    static let minSpokeLength: CGFloat = 2
    static let maxSpokeLength: CGFloat = 7
    static let spokeWidth: CGFloat = 1.5
    /// A resting spoke is a dot on this circle, so the settled processing ring is exactly where the spokes were.
    static let ringRadius: CGFloat = innerRadius + minSpokeLength / 2
    static let ringWidth: CGFloat = 1.5
    static let dotRadius: CGFloat = 2.75
    static let dotPulse: CGFloat = 1.25
    static let controlDiameter: CGFloat = 18
    static let controlInset: CGFloat = 5
    static let controlGap: CGFloat = 4
    static let messagePadding: CGFloat = 16

    /// Seconds for the spokes to settle into the ring when processing starts.
    static let settleDuration: TimeInterval = 0.3
    /// Seconds for the comet to go once around.
    static let cometPeriod: TimeInterval = 1.1
    /// How much of the circle the comet's tail covers.
    static let cometSweep: CGFloat = .pi * 0.75

    /// The same measurements at a pill size. Large is exactly 2x every length.
    struct Metrics: Equatable, Sendable {
        let factor: CGFloat
        init(_ scale: PillScale) { factor = scale.factor }

        static let standard = Metrics(.standard)
        static let large = Metrics(.large)

        var diameter: CGFloat { RingPillLayout.diameter * factor }
        var innerRadius: CGFloat { RingPillLayout.innerRadius * factor }
        var minSpokeLength: CGFloat { RingPillLayout.minSpokeLength * factor }
        var maxSpokeLength: CGFloat { RingPillLayout.maxSpokeLength * factor }
        var spokeWidth: CGFloat { RingPillLayout.spokeWidth * factor }
        var ringRadius: CGFloat { RingPillLayout.ringRadius * factor }
        var ringWidth: CGFloat { RingPillLayout.ringWidth * factor }
        var dotRadius: CGFloat { RingPillLayout.dotRadius * factor }
        var dotPulse: CGFloat { RingPillLayout.dotPulse * factor }
        var controlDiameter: CGFloat { RingPillLayout.controlDiameter * factor }
        var controlInset: CGFloat { RingPillLayout.controlInset * factor }
        var controlGap: CGFloat { RingPillLayout.controlGap * factor }
        var cornerRadius: CGFloat { diameter / 2 }
    }

    enum Mode: Equatable {
        case hold, locked, processing
        case message(width: CGFloat, height: CGFloat)
    }

    // MARK: Spokes

    /// Radians clockwise from twelve o'clock for spoke `index` of `count`.
    static func spokeAngle(index: Int, count: Int = spokeCount) -> CGFloat {
        guard count > 0 else { return 0 }
        return 2 * .pi * CGFloat(index) / CGFloat(count)
    }

    /// Where `angle` sits between the middle bars and the outer ones: 0 at the top and bottom, 1 at the sides, linear in
    /// angle in between. The same value at an angle and at its mirror in either axis.
    static func foldedPosition(angle: CGFloat) -> CGFloat {
        guard angle.isFinite else { return 0 }
        let a = angle.truncatingRemainder(dividingBy: .pi)
        let wrapped = a < 0 ? a + .pi : a
        return min(wrapped, .pi - wrapped) / (.pi / 2)
    }

    /// The levels from the middle outward: each middle bar averaged with its mirror, so index 0 is the middle pair.
    static func folded(_ fractions: [Float]) -> [Float] {
        let n = fractions.count
        guard n > 0 else { return [0] }
        return (0..<(n + 1) / 2).map { j in
            let low = (n - 1) / 2 - j
            let high = n - 1 - low
            return (clean(fractions[low]) + clean(fractions[high])) / 2
        }
    }

    /// The folded level at `position` 0...1, interpolated between neighbours.
    static func level(folded: [Float], at position: CGFloat) -> Float {
        guard folded.count > 1 else { return folded.first ?? 0 }
        let x = min(1, max(0, position.isFinite ? position : 0)) * CGFloat(folded.count - 1)
        let i = min(folded.count - 2, Int(x.rounded(.down)))
        let t = Float(x - CGFloat(i))
        return folded[i] + (folded[i + 1] - folded[i]) * t
    }

    /// One 0...1 level per spoke, mirrored left and right and top and bottom.
    static func spokeFractions(from fractions: [Float], count: Int = spokeCount) -> [Float] {
        let folded = folded(fractions)
        return (0..<count).map { level(folded: folded, at: foldedPosition(angle: spokeAngle(index: $0, count: count))) }
    }

    static func spokeLength(fraction: Float, metrics m: Metrics = .standard) -> CGFloat {
        m.minSpokeLength + (m.maxSpokeLength - m.minSpokeLength) * CGFloat(clean(fraction))
    }

    /// The spoke's inner and outer ends around `centre`, in a y-up plane.
    static func spokeEnds(angle: CGFloat, length: CGFloat, centre: CGPoint, metrics m: Metrics = .standard) -> (CGPoint, CGPoint) {
        let direction = CGPoint(x: sin(angle), y: cos(angle))
        return (
            CGPoint(x: centre.x + direction.x * m.innerRadius, y: centre.y + direction.y * m.innerRadius),
            CGPoint(x: centre.x + direction.x * (m.innerRadius + length), y: centre.y + direction.y * (m.innerRadius + length))
        )
    }

    // MARK: Centre dot and level arc

    /// The overall 0...1 level of the bars, so loud speech reads near 1 whatever the weights do to single bars.
    static func overallLevel(_ fractions: [Float]) -> Float {
        guard !fractions.isEmpty else { return 0 }
        let weights = BarModel.weights
        let mean = fractions.map(clean).reduce(0, +) / Float(fractions.count)
        let reference = weights.reduce(0, +) / Float(weights.count)
        return min(1, max(0, mean / max(0.01, reference)))
    }

    static func dotRadius(level: Float, metrics m: Metrics = .standard) -> CGFloat {
        m.dotRadius + m.dotPulse * CGFloat(clean(level))
    }

    /// The arc that shows the level without motion: from twelve o'clock clockwise, in radians.
    static func levelSweep(level: Float) -> CGFloat { 2 * .pi * CGFloat(clean(level)) }

    // MARK: Processing

    /// 0...1 progress of the spokes settling into the ring, eased.
    static func settleProgress(time: TimeInterval) -> CGFloat {
        let t = min(1, max(0, time.isFinite ? time / settleDuration : 0))
        return 1 - (1 - t) * (1 - t) * (1 - t)
    }

    /// Clockwise radians from twelve o'clock where the comet's head is at `time`.
    static func cometHeadAngle(time: TimeInterval) -> CGFloat {
        let t = time.isFinite ? max(0, time) : 0
        return CGFloat((t / cometPeriod).truncatingRemainder(dividingBy: 1)) * 2 * .pi
    }

    /// Colour stops for the comet's conic gradient, which runs clockwise from twelve o'clock. The head is at 0 and 1, the
    /// tail ends `cometSweep` before it, and the alpha rises with the square of the distance along the tail so it fades
    /// smoothly into nothing.
    static func cometStops(count: Int = 8) -> [(location: CGFloat, alpha: CGFloat)] {
        let n = max(2, count)
        let tail = cometSweep / (2 * .pi)
        return [(0, 0)] + (0..<n).map { i in
            let t = CGFloat(i) / CGFloat(n - 1)
            return (1 - tail + tail * t, t * t)
        }
    }

    // MARK: Pill shape

    static func lockedWidth(metrics m: Metrics = .standard) -> CGFloat {
        m.diameter + 2 * (m.controlDiameter + m.controlInset + m.controlGap)
    }

    static func capsuleWidth(_ mode: Mode, metrics m: Metrics = .standard) -> CGFloat {
        switch mode {
        case .hold, .processing: m.diameter
        case .locked: lockedWidth(metrics: m)
        case .message(let width, _): max(m.diameter, width)
        }
    }

    static func capsuleHeight(_ mode: Mode, metrics m: Metrics = .standard) -> CGFloat {
        if case .message(_, let height) = mode { return max(m.diameter, height) }
        return m.diameter
    }

    /// The cancel disc at the left end and the stop disc at the right.
    static func controlFrames(capsule: CGRect, metrics m: Metrics = .standard) -> [PillControl: CGRect] {
        let d = m.controlDiameter
        let y = capsule.midY - d / 2
        return [
            .cancel: CGRect(x: capsule.minX + m.controlInset, y: y, width: d, height: d),
            .stop: CGRect(x: capsule.maxX - m.controlInset - d, y: y, width: d, height: d),
        ]
    }

    private static func clean(_ value: Float) -> Float { value.isFinite ? min(1, max(0, value)) : 0 }
}
