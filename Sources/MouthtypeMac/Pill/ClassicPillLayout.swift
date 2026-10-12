import CoreGraphics
import Foundation

/// The classic pill's measurements and the maths behind them, with no layers in it. Widths and bar sizes are
/// snapped to whole device pixels (and bar sizes to an even count of them) so the centre-anchored bars land on the
/// pixel grid at 1x and 2x and don't shimmer as they grow.
enum ClassicPillLayout {
    static let height: CGFloat = 28
    static let holdWidth: CGFloat = 97
    /// The dot-like capsule the pill grows from and shrinks to.
    static let dotWidth: CGFloat = height
    static let barWidth: CGFloat = 2.25
    static let barPitch: CGFloat = 4.25
    static let maxBarHeight: CGFloat = 14.25
    static let controlDiameter: CGFloat = 18
    static let controlInset: CGFloat = 5
    static let controlGap: CGFloat = 16
    static let messageFontSize: CGFloat = 12
    static let messagePadding: CGFloat = 16
    static let messageMinWidth: CGFloat = 64
    static let messageCap: CGFloat = 320

    enum Mode: Equatable {
        case hold, locked, processing
        case message(textWidth: CGFloat)
    }

    /// Rounds to a whole number of device pixels, returned in points.
    static func snap(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }

    /// Rounds to an even number of device pixels, so a size centred on the pixel grid has both edges on it.
    static func snapEven(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        2 * (value * scale / 2).rounded() / scale
    }

    static func evenCeil(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        2 * (value * scale / 2).rounded(.up) / scale
    }

    /// Bar width and pitch on the pixel grid.
    static func barMetrics(scale: CGFloat) -> (width: CGFloat, pitch: CGFloat) {
        (max(2 / scale, snapEven(barWidth, scale: scale)), max(2 / scale, snapEven(barPitch, scale: scale)))
    }

    /// Dot height for silence and the tallest bar, both on the grid.
    static func barHeightRange(scale: CGFloat) -> ClosedRange<CGFloat> {
        let width = barMetrics(scale: scale).width
        return width...max(width, snapEven(maxBarHeight, scale: scale))
    }

    /// A smoothed 0...1 level as a bar height. A small dead zone keeps room noise at dots, and the gain and curve
    /// make ordinary speech reach most of the range.
    static func barHeight(fraction: Float, scale: CGFloat) -> CGFloat {
        let f = fraction.isFinite ? min(1, max(0, fraction)) : 0
        let shaped = pow(min(1, max(0, (f - 0.03) * 1.45)), 0.8)
        let range = barHeightRange(scale: scale)
        return snapEven(range.lowerBound + (range.upperBound - range.lowerBound) * CGFloat(shaped), scale: scale)
            .clamped(to: range)
    }

    /// A low, slow wave travelling along the bars, as 0...1 fractions for `barHeight`.
    static func processingFractions(time: TimeInterval, count: Int) -> [Float] {
        let t = time.isFinite ? time : 0
        return (0..<count).map { i in
            Float(0.2 + 0.1 * sin(2 * .pi * (t * 0.8 - Double(i) * 0.09)))
        }
    }

    /// Width of the bars alone, first edge to last.
    static func barsSpan(scale: CGFloat) -> CGFloat {
        let m = barMetrics(scale: scale)
        return 9 * m.pitch + m.width
    }

    static func lockedWidth(scale: CGFloat) -> CGFloat {
        evenCeil(2 * (controlInset + controlDiameter + controlGap) + barsSpan(scale: scale), scale: scale)
    }

    /// The message capsule: wide enough for the text and its padding, within the minimum and the cap. `truncated`
    /// when the text doesn't fit even at the cap, and `textWidth` is then what the text layer gets.
    static func messageLayout(textWidth: CGFloat, scale: CGFloat) -> (width: CGFloat, textWidth: CGFloat, truncated: Bool) {
        let natural = ceil(max(0, textWidth.isFinite ? textWidth : 0))
        let wanted = natural + 2 * messagePadding
        let width = evenCeil(min(messageCap, max(messageMinWidth, wanted)), scale: scale)
        let available = width - 2 * messagePadding
        return (width, min(natural, available), natural > available)
    }

    static func capsuleWidth(_ mode: Mode, scale: CGFloat) -> CGFloat {
        switch mode {
        case .hold, .processing: evenCeil(holdWidth, scale: scale)
        case .locked: lockedWidth(scale: scale)
        case .message(let textWidth): messageLayout(textWidth: textWidth, scale: scale).width
        }
    }

    /// The capsule inside a view of `bounds`: centred across, `bottomMargin` up from the bottom.
    static func capsuleFrame(width: CGFloat, bounds: CGSize, bottomMargin: CGFloat, scale: CGFloat) -> CGRect {
        CGRect(x: snap((bounds.width - width) / 2, scale: scale), y: bottomMargin, width: width, height: height)
    }

    /// One frame per bar, centred on the capsule's middle.
    static func barFrames(capsule: CGRect, heights: [CGFloat], scale: CGFloat) -> [CGRect] {
        let m = barMetrics(scale: scale)
        let range = barHeightRange(scale: scale)
        return heights.enumerated().map { i, raw in
            let h = raw.clamped(to: range)
            let centre = capsule.midX + (CGFloat(i) - CGFloat(heights.count - 1) / 2) * m.pitch
            return CGRect(x: centre - m.width / 2, y: capsule.midY - h / 2, width: m.width, height: h)
        }
    }

    /// The cancel disc at the left end and the stop disc at the right.
    static func controlFrames(capsule: CGRect) -> [PillControl: CGRect] {
        let d = controlDiameter
        let y = capsule.midY - d / 2
        return [
            .cancel: CGRect(x: capsule.minX + controlInset, y: y, width: d, height: d),
            .stop: CGRect(x: capsule.maxX - controlInset - d, y: y, width: d, height: d),
        ]
    }
}

extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat { Swift.min(range.upperBound, Swift.max(range.lowerBound, self)) }
}
