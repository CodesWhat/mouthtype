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
    static let messagePadding: CGFloat = 16
    static let messageVerticalPadding: CGFloat = 7
    static let messageMinWidth: CGFloat = 64
    static let messageCap: CGFloat = 320
    /// Gap between the headline and the detail under it.
    static let detailGap: CGFloat = 1
    /// A taller pill keeps the corner of the 28 pt one, so the capsule becomes a rounded rectangle.
    static let cornerRadius: CGFloat = height / 2

    enum Mode: Equatable {
        case hold, locked, processing
        case message(width: CGFloat, height: CGFloat)
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

    /// One line of a laid-out message and where it sits, as the offset of its middle from the block's middle
    /// (positive is down).
    struct MessageLine: Equatable {
        var text: String
        var isDetail: Bool
        var centerOffset: CGFloat
        var height: CGFloat
    }

    struct MessageBlock: Equatable {
        var width: CGFloat
        var height: CGFloat
        var lines: [MessageLine]
    }

    /// Breaks a message at its logical point: the headline on its own line or lines, the detail under it. A part wraps
    /// onto further lines only where it is wider than the cap, at a word boundary, and a single word wider than the
    /// cap breaks between characters. Nothing is cut off. `measure` gives a string's width in the part's real font.
    static func messageBlock(
        headline: String, detail: String?, headlineLineHeight: CGFloat, detailLineHeight: CGFloat,
        scale: CGFloat, measure: (String, _ isDetail: Bool) -> CGFloat
    ) -> MessageBlock {
        let available = messageCap - 2 * messagePadding
        let head = wrap(headline, width: available) { measure($0, false) }
        let tail = (detail?.isEmpty == false) ? wrap(detail ?? "", width: available) { measure($0, true) } : []
        let widest = (head.map { measure($0, false) } + tail.map { measure($0, true) }).max() ?? 0
        let width = evenCeil(min(messageCap, max(messageMinWidth, ceil(widest) + 2 * messagePadding)), scale: scale)

        let stack = head.count * Int(headlineLineHeight.rounded()) + tail.count * Int(detailLineHeight.rounded())
        let gap = tail.isEmpty ? 0 : detailGap
        let block = CGFloat(stack) + gap
        let height = head.count + tail.count == 1
            ? Self.height
            : max(Self.height, evenCeil(block + 2 * messageVerticalPadding, scale: scale))
        var lines: [MessageLine] = []
        var y = -block / 2
        for text in head {
            lines.append(MessageLine(text: text, isDetail: false, centerOffset: y + headlineLineHeight / 2, height: headlineLineHeight))
            y += headlineLineHeight
        }
        y += gap
        for text in tail {
            lines.append(MessageLine(text: text, isDetail: true, centerOffset: y + detailLineHeight / 2, height: detailLineHeight))
            y += detailLineHeight
        }
        return MessageBlock(width: width, height: height, lines: lines)
    }

    /// Greedy word wrap to `width`; an over-wide word is split between characters.
    static func wrap(_ text: String, width: CGFloat, measure: (String) -> CGFloat) -> [String] {
        var lines: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { lines.append(current) }
            current = ""
        }
        for word in text.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
            let joined = current.isEmpty ? word : current + " " + word
            if measure(joined) <= width {
                current = joined
                continue
            }
            flush()
            if measure(word) <= width {
                current = word
                continue
            }
            for character in word {
                let next = current + String(character)
                if measure(next) > width, !current.isEmpty {
                    flush()
                    current = String(character)
                } else {
                    current = next
                }
            }
        }
        flush()
        return lines.isEmpty ? [""] : lines
    }

    static func capsuleWidth(_ mode: Mode, scale: CGFloat) -> CGFloat {
        switch mode {
        case .hold, .processing: evenCeil(holdWidth, scale: scale)
        case .locked: lockedWidth(scale: scale)
        case .message(let width, _): width
        }
    }

    static func capsuleHeight(_ mode: Mode) -> CGFloat {
        if case .message(_, let height) = mode { return height }
        return height
    }

    /// The capsule inside a view of `bounds`: centred across, `bottomMargin` up from the bottom.
    static func capsuleFrame(
        width: CGFloat, height: CGFloat = ClassicPillLayout.height, bounds: CGSize, bottomMargin: CGFloat, scale: CGFloat
    ) -> CGRect {
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
