import AppKit
import ImageIO

/// What `design/pill/export.py` writes to `Pill/hifi/card/layout.json`: the Hi-Fi delivery card's window sprites, the
/// metrics every layout length comes from, and the art's colours. All lengths are art pixels at 1x.
struct HiFiCardSpec: Decodable, Sendable {
    struct Slices: Decodable, Equatable, Sendable { var left: Int, top: Int, right: Int, bottom: Int }
    struct Sprite: Decodable, Sendable {
        var file: String
        var w: Int, h: Int
        var slices: Slices?
    }
    struct Plate: Decodable, Sendable { var x: Int, y: Int, h: Int, padX: Int, ledGap: Int }
    struct Close: Decodable, Sendable { var right: Int, y: Int, hitW: Int, hitH: Int }
    struct VFD: Decodable, Sendable {
        var gapTop: Int, ring: Int, padX: Int, padY: Int, lineGap: Int
        var barGap: Int, barH: Int, barSegW: Int, barSegGap: Int
    }
    struct Button: Decodable, Sendable { var h: Int, minW: Int, padX: Int, gap: Int, gapTop: Int, labelPressedDy: Int }
    struct Metrics: Decodable, Sendable {
        var titleBar: Int, margin: Int
        var plate: Plate
        var close: Close
        var vfd: VFD
        var button: Button
        var bottomPad: Int
        var maxLines: Int
    }
    struct Colors: Decodable, Sendable {
        var metal: String, metalHi: String, metalLo: String, metalEdge: String
        var engrave: String, engraveDim: String, engraveHi: String
        var cap: String, capHi: String, capLo: String, ink: String
        var vfdBg: String, vfd: String, ledOn: String, ledHi: String, segOff: String
    }

    var sprites: [String: Sprite]
    var metrics: Metrics
    var colors: Colors
}

/// The decoded card art next to the pill's own fonts and LED sprites, so card and pill share one palette and face.
struct HiFiCardAssets {
    enum LoadError: Error { case missing(String), undecodable(String) }

    static let directory = "Pill/hifi/card"

    let spec: HiFiCardSpec
    let frame: CGImage
    let closeUp: CGImage
    let closeDown: CGImage
    let buttonUp: CGImage
    let buttonDown: CGImage
    let vfd: CGImage
    let pill: PillAssets
    /// The readout face (5x7) and the label face (3x5), the pill's own.
    let font5: BitmapFont
    let font3: BitmapFont

    var metrics: HiFiCardSpec.Metrics { spec.metrics }

    static func load(bundle: Bundle = .module) throws -> HiFiCardAssets {
        func url(_ file: String) throws -> URL {
            let name = file as NSString
            guard let found = bundle.url(
                forResource: name.deletingPathExtension, withExtension: name.pathExtension, subdirectory: directory
            ) else { throw LoadError.missing(file) }
            return found
        }
        func image(_ file: String) throws -> CGImage {
            guard let source = CGImageSourceCreateWithURL(try url(file) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw LoadError.undecodable(file) }
            return image
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let spec = try decoder.decode(HiFiCardSpec.self, from: Data(contentsOf: url("layout.json")))
        func sprite(_ name: String) throws -> CGImage {
            guard let entry = spec.sprites[name] else { throw LoadError.missing(name) }
            return try image(entry.file)
        }
        let pill = try PillAssets.loadHiFi(bundle: bundle)
        guard let font5 = pill.fonts["f5"], let font3 = pill.fonts["f3"] else { throw LoadError.missing("fonts") }
        return HiFiCardAssets(
            spec: spec, frame: try sprite("frame"), closeUp: try sprite("close_up"), closeDown: try sprite("close_down"),
            buttonUp: try sprite("button_up"), buttonDown: try sprite("button_down"), vfd: try sprite("vfd"),
            pill: pill, font5: font5, font3: font3
        )
    }

    /// Loaded once; nil when the art is missing, and the card then falls back to the classic one.
    @MainActor static let shared: HiFiCardAssets? = try? load()

    func slices(of name: String) -> HiFiCardSpec.Slices? { spec.sprites[name]?.slices }
}

/// A bitmap at 1 art pixel per pixel, drawn top-left first with whole-pixel rects. The card is composed here and then
/// magnified at an integer scale with no smoothing, so every art pixel stays a crisp block.
final class HiFiCanvas {
    let width: Int, height: Int
    private let context: CGContext

    init?(width: Int, height: Int) {
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        self.width = width
        self.height = height
        self.context = context
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
    }

    private func flipped(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> CGRect {
        CGRect(x: x, y: height - y - h, width: w, height: h)
    }

    func fill(_ rect: PillLayout.Rect, _ color: CGColor) { fill(rect.x, rect.y, rect.w, rect.h, color) }

    func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: CGColor) {
        guard w > 0, h > 0 else { return }
        context.setFillColor(color)
        context.fill(flipped(x, y, w, h))
    }

    func draw(_ image: CGImage, x: Int, y: Int) {
        context.draw(image, in: flipped(x, y, image.width, image.height))
    }

    /// Stretches nothing: each of the nine regions is tiled from its source slice, so edges and centre stay pixel-exact.
    func nineSlice(_ image: CGImage, slices s: HiFiCardSpec.Slices, in rect: PillLayout.Rect) {
        let columns = [(0, s.left, rect.x, s.left), (s.left, image.width - s.left - s.right, rect.x + s.left, rect.w - s.left - s.right),
                       (image.width - s.right, s.right, rect.x + rect.w - s.right, s.right)]
        let rows = [(0, s.top, rect.y, s.top), (s.top, image.height - s.top - s.bottom, rect.y + s.top, rect.h - s.top - s.bottom),
                    (image.height - s.bottom, s.bottom, rect.y + rect.h - s.bottom, s.bottom)]
        for (sy, sh, dy, dh) in rows {
            for (sx, sw, dx, dw) in columns where sw > 0 && sh > 0 && dw > 0 && dh > 0 {
                var oy = 0
                while oy < dh {
                    let th = min(sh, dh - oy)
                    var ox = 0
                    while ox < dw {
                        let tw = min(sw, dw - ox)
                        if let tile = image.cropping(to: CGRect(x: sx, y: sy, width: tw, height: th)) {
                            draw(tile, x: dx + ox, y: dy + oy)
                        }
                        ox += sw
                    }
                    oy += sh
                }
            }
        }
    }

    func makeImage() -> CGImage? { context.makeImage() }

    /// `image`'s shape in one flat `color`.
    static func tinted(_ image: CGImage, _ color: CGColor) -> CGImage? {
        guard let canvas = HiFiCanvas(width: image.width, height: image.height) else { return nil }
        canvas.draw(image, x: 0, y: 0)
        canvas.context.setBlendMode(.sourceIn)
        canvas.context.setFillColor(color)
        canvas.context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return canvas.makeImage()
    }

    /// `a` toward `b` by `t`, both art hex colours.
    static func mix(_ a: String, _ b: String, _ t: CGFloat) -> CGColor {
        let x = PillLayout.color(hex: a).components ?? [0, 0, 0, 1], y = PillLayout.color(hex: b).components ?? [0, 0, 0, 1]
        return CGColor(srgbRed: x[0] + (y[0] - x[0]) * t, green: x[1] + (y[1] - x[1]) * t, blue: x[2] + (y[2] - x[2]) * t, alpha: 1)
    }
}
