import CoreGraphics
import Foundation

/// The Hi-Fi card's measurements, in art pixels at 1x with the origin at the top left, and no views in it. Every
/// length comes from the exported spec, so the art and the layout can't drift apart. The card is `CardLayout.width`
/// art pixels wide; at the Large pill size the view magnifies the whole card by 2.
enum HiFiCardLayout {
    typealias Rect = PillLayout.Rect

    static let ledSize = 4
    static let closeSize = 10
    /// The title-bar ear is a 5x7 glyph of the readout face, set between the LED and the title.
    static let earWidth = 5
    static let earHeight = 7
    static let earGap = 2
    static let frameBottom = 4

    static var width: Int { Int(CardLayout.width) }

    struct Input {
        var titleWidth: Int
        /// How many lines the VFD holds, and its text's cell height.
        var lineCount: Int
        var lineHeight: Int
        var hasBar: Bool
        var buttonLabelWidths: [Int]
    }

    struct Frames: Equatable {
        var width: Int, height: Int
        var plate: Rect
        var led: Rect
        var ear: Rect
        var titleOrigin: CGPoint
        var close: Rect
        var closeHit: Rect
        var vfd: Rect?
        var textOrigin: CGPoint
        var visibleLines: Int
        var bar: Rect?
        var buttons: [Rect]
    }

    /// The close button's hit area: centred on the art, pulled in so it stays inside the card.
    static func closeHit(_ m: HiFiCardSpec.Metrics) -> Rect {
        let x = min(width - m.close.right - closeSize - (m.close.hitW - closeSize) / 2, width - m.close.hitW)
        return Rect(x: x, y: 0, w: m.close.hitW, h: m.close.hitH)
    }

    /// The widest title that fits between the plate's start and the close button.
    static func titleMaxWidth(_ m: HiFiCardSpec.Metrics) -> Int {
        closeHit(m).x - 2 - m.plate.x - 2 * m.plate.padX - ledSize - m.plate.ledGap - earWidth - earGap
    }

    /// The width a line of VFD text can use.
    static func textMaxWidth(_ m: HiFiCardSpec.Metrics) -> Int {
        width - 2 * m.margin - 2 * (m.vfd.ring + m.vfd.padX)
    }

    static func buttonWidth(label: Int, _ m: HiFiCardSpec.Metrics) -> Int { max(m.button.minW, label + 2 * m.button.padX) }

    static func make(_ input: Input, _ m: HiFiCardSpec.Metrics) -> Frames {
        let plate = Rect(x: m.plate.x, y: m.plate.y, w: 2 * m.plate.padX + ledSize + m.plate.ledGap + earWidth + earGap + input.titleWidth, h: m.plate.h)
        let led = Rect(x: plate.x + m.plate.padX, y: plate.y + (plate.h - ledSize) / 2, w: ledSize, h: ledSize)
        let ear = Rect(x: led.x + ledSize + m.plate.ledGap, y: plate.y + (plate.h - earHeight) / 2, w: earWidth, h: earHeight)
        let closeX = width - m.close.right - closeSize
        let close = Rect(x: closeX, y: m.close.y, w: closeSize, h: closeSize)
        let closeHit = Self.closeHit(m)

        var y = m.titleBar + m.vfd.gapTop
        var vfd: Rect?
        var bar: Rect?
        let visible = min(input.lineCount, m.maxLines)
        let textHeight = visible > 0 ? visible * input.lineHeight + (visible - 1) * m.vfd.lineGap : 0
        let textX = m.margin + m.vfd.ring + m.vfd.padX
        var textY = y
        if visible > 0 || input.hasBar {
            let barBlock = input.hasBar ? (textHeight > 0 ? m.vfd.barGap : 0) + m.vfd.barH : 0
            let inner = 2 * m.vfd.padY + textHeight + barBlock
            let frame = Rect(x: m.margin, y: y, w: width - 2 * m.margin, h: inner + 2 * m.vfd.ring)
            vfd = frame
            textY = frame.y + m.vfd.ring + m.vfd.padY
            if input.hasBar {
                bar = Rect(
                    x: textX, y: textY + textHeight + (textHeight > 0 ? m.vfd.barGap : 0),
                    w: frame.w - 2 * (m.vfd.ring + m.vfd.padX), h: m.vfd.barH
                )
            }
            y = frame.y + frame.h
        }

        var buttons: [Rect] = []
        if !input.buttonLabelWidths.isEmpty {
            y += m.button.gapTop
            var x = m.margin
            for label in input.buttonLabelWidths {
                let w = buttonWidth(label: label, m)
                buttons.append(Rect(x: x, y: y, w: w, h: m.button.h))
                x += w + m.button.gap
            }
            y += m.button.h
        }
        let height = y + m.bottomPad + frameBottom
        return Frames(
            width: width, height: height, plate: plate, led: led, ear: ear,
            titleOrigin: CGPoint(x: ear.x + earWidth + earGap, y: plate.y + (plate.h - 5) / 2),
            close: close, closeHit: closeHit, vfd: vfd, textOrigin: CGPoint(x: textX, y: textY), visibleLines: visible,
            bar: bar, buttons: buttons
        )
    }

    /// Lit segments of the countdown bar: `fraction` of `count`, rounded up so a running bar never reads empty.
    static func litSegments(fraction: CGFloat, count: Int) -> Int {
        max(0, min(count, Int(ceil(min(1, max(0, fraction)) * CGFloat(count) - 1e-6))))
    }
}
