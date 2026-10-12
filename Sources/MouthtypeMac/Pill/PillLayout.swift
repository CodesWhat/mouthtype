import AppKit
import ImageIO

/// What `design/pill/export.py` writes to `layout.json`: every position, rect and colour of the pill, in art pixels
/// with the origin at the top left. A skin is a layout plus its images.
struct PillLayout: Decodable, Sendable {
    struct Size: Decodable, Equatable, Sendable { var w: Int; var h: Int }

    struct Rect: Decodable, Equatable, Sendable {
        var x: Int, y: Int, w: Int, h: Int

        func overlaps(_ other: Rect) -> Bool {
            x < other.x + other.w && other.x < x + w && y < other.y + other.h && other.y < y + h
        }

        func isInside(_ size: Size) -> Bool {
            x >= 0 && y >= 0 && w > 0 && h > 0 && x + w <= size.w && y + h <= size.h
        }
    }

    struct Sprite: Decodable, Equatable, Sendable {
        var file: String
        var x: Int, y: Int, w: Int, h: Int
        var rect: Rect { Rect(x: x, y: y, w: w, h: h) }
    }

    struct Meter: Decodable, Sendable {
        var columns: Int
        var segmentsPerColumn: Int
        /// `segments[column][row]`, row 0 is the baseline.
        var segments: [[Rect]]
        var rowTiers: [String]
    }

    struct TextSlot: Decodable, Equatable, Sendable {
        var x: Int, y: Int, maxWidth: Int
        var font: String
    }

    struct TextSlots: Decodable, Sendable {
        var timer: TextSlot
        var timerLocked: TextSlot
        var message: TextSlot
    }

    struct Colors: Decodable, Sendable {
        var segmentNormal: String, segmentHot: String, segmentPeak: String, segmentDim: String
        var windowBackground: String, text: String, error: String
    }

    struct FontSpec: Decodable, Sendable {
        var file: String
        var cellWidth: Int, cellHeight: Int, gap: Int
        var chars: String
        var advances: [String: Int]

        var metrics: BitmapFont.Metrics {
            BitmapFont.Metrics(
                cellWidth: cellWidth, cellHeight: cellHeight, gap: gap, chars: Array(chars),
                advances: Dictionary(advances.compactMap { key, value in key.first.map { ($0, value) } }, uniquingKeysWith: { a, _ in a })
            )
        }
    }

    var size: Size
    var chassis: String
    var sprites: [String: Sprite]
    var window: Rect
    var meter: Meter
    var text: TextSlots
    var colors: Colors
    var fonts: [String: FontSpec]

    static func color(hex: String) -> CGColor {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return CGColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1
        )
    }

    func tierColor(_ tier: String) -> CGColor {
        switch tier {
        case "hot": Self.color(hex: colors.segmentHot)
        case "peak": Self.color(hex: colors.segmentPeak)
        default: Self.color(hex: colors.segmentNormal)
        }
    }
}

/// A decoded skin: the layout, the static chassis, the state sprites and the font atlases.
struct PillAssets {
    enum LoadError: Error { case missing(String), undecodable(String) }

    let layout: PillLayout
    let chassis: CGImage
    let sprites: [String: CGImage]
    let fonts: [String: BitmapFont]

    static let hifiDirectory = "Pill/hifi"

    static func loadHiFi(bundle: Bundle = .module) throws -> PillAssets {
        func url(_ file: String) throws -> URL {
            let name = file as NSString
            guard let found = bundle.url(
                forResource: name.deletingPathExtension, withExtension: name.pathExtension, subdirectory: hifiDirectory
            ) else { throw LoadError.missing(file) }
            return found
        }
        func image(_ file: String) throws -> CGImage {
            guard let source = CGImageSourceCreateWithURL(try url(file) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw LoadError.undecodable(file) }
            return image
        }
        let layout = try JSONDecoder().decode(PillLayout.self, from: Data(contentsOf: url("layout.json")))
        return PillAssets(
            layout: layout,
            chassis: try image(layout.chassis),
            sprites: try layout.sprites.mapValues { try image($0.file) },
            fonts: try layout.fonts.mapValues { BitmapFont(metrics: $0.metrics, atlas: try image($0.file)) }
        )
    }
}
