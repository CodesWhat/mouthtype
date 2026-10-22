import CoreGraphics
import Foundation

/// A fixed-cell bitmap face: one row of glyph cells in a white-on-transparent atlas, drawn at whole pixels.
struct BitmapFont {
    /// The layout half, with no image in it, so lookup and width can be tested on their own.
    struct Metrics: Equatable, Sendable {
        var cellWidth: Int
        var cellHeight: Int
        var gap: Int
        var chars: [Character]
        /// Per-glyph advance where it differs from the cell width (the timer's one-pixel colon).
        var advances: [Character: Int]
        private let table: [Character: Int]

        init(cellWidth: Int, cellHeight: Int, gap: Int, chars: [Character], advances: [Character: Int] = [:]) {
            self.cellWidth = cellWidth
            self.cellHeight = cellHeight
            self.gap = gap
            self.chars = chars
            self.advances = advances
            table = Dictionary(chars.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        }

        /// The cell for `character`: itself, else its uppercase (the faces are caps-only), else the blank cell 0.
        func glyphIndex(for character: Character) -> Int {
            if let index = table[character] { return index }
            let upper = Array(String(character).uppercased())
            if upper.count == 1, let index = table[upper[0]] { return index }
            return 0
        }

        func advance(forGlyph index: Int) -> Int {
            advances[chars[index]] ?? cellWidth
        }

        /// Each glyph's cell index and left edge for `text`.
        func placements(of text: String) -> [(index: Int, x: Int)] {
            var x = 0
            return text.map { character in
                let index = glyphIndex(for: character)
                defer { x += advance(forGlyph: index) + gap }
                return (index, x)
            }
        }

        func width(of text: String) -> Int {
            guard let last = placements(of: text).last else { return 0 }
            return last.x + advance(forGlyph: last.index)
        }
    }

    let metrics: Metrics
    let atlas: CGImage

    func width(of text: String) -> Int { metrics.width(of: text) }

    /// `text` as one image at 1 pixel per art pixel, tinted `color`. Nil for empty text.
    func image(for text: String, color: CGColor) -> CGImage? {
        let width = metrics.width(of: text)
        guard width > 0 else { return nil }
        guard
            let context = CGContext(
                data: nil, width: width, height: metrics.cellHeight, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.interpolationQuality = .none
        for (index, x) in metrics.placements(of: text) {
            let cell = CGRect(x: index * metrics.cellWidth, y: 0, width: metrics.cellWidth, height: metrics.cellHeight)
            guard let glyph = atlas.cropping(to: cell) else { continue }
            context.draw(glyph, in: CGRect(x: x, y: 0, width: metrics.cellWidth, height: metrics.cellHeight))
        }
        context.setBlendMode(.sourceIn)
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: metrics.cellHeight))
        return context.makeImage()
    }
}
