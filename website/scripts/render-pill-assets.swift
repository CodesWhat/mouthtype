import AppKit
import QuartzCore
import ImageIO
import UniformTypeIdentifiers
import OSLog

// The standalone renderer compiles the app's views without SwiftPM's generated resource accessor.
extension Bundle { static var module: Bundle { .main } }
enum Log { static let app = Logger(subsystem: "com.codeswhat.mouthtype.website", category: "assets") }

@main
struct RenderPills {
    @MainActor
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let art = root.appendingPathComponent("Sources/MouthtypeMac/Resources/Pill/hifi")
        func image(_ file: String) throws -> CGImage {
            let source = CGImageSourceCreateWithURL(art.appendingPathComponent(file) as CFURL, nil)!
            return CGImageSourceCreateImageAtIndex(source, 0, nil)!
        }
        let layout = try JSONDecoder().decode(PillLayout.self, from: Data(contentsOf: art.appendingPathComponent("layout.json")))
        let assets = PillAssets(
            layout: layout, chassis: try image(layout.chassis),
            sprites: try layout.sprites.mapValues { try image($0.file) },
            fonts: try layout.fonts.mapValues { BitmapFont(metrics: $0.metrics, atlas: try image($0.file)) }
        )
        let frame = NSRect(x: 0, y: 0, width: 200, height: 90)
        let classic = ClassicPillView(frame: frame)
        let hifi = HiFiPillView(frame: frame, assets: assets)
        for (name, view) in [("classic", classic as NSView & PillSkinView), ("hifi", hifi as NSView & PillSkinView)] {
            view.appear(reduceMotion: true)
            view.showRecording(locked: true)
            view.showFractions([0.12, 0.34, 0.61, 0.42, 0.87, 0.72, 0.47, 0.62, 0.29, 0.15])
            view.setElapsed(4)
            try save(view, to: output.appendingPathComponent("\(name)-recording.png"))
        }
    }

    @MainActor
    static func save(_ view: NSView, to url: URL) throws {
        let scale = 4
        let width = Int(view.bounds.width) * scale, height = Int(view.bounds.height) * scale
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        func settle(_ layer: CALayer) {
            layer.removeAllAnimations()
            layer.sublayers?.forEach(settle)
        }
        let layer = view.layer!
        settle(layer)
        layer.render(in: context)
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        var left = width, right = 0, top = height, bottom = 0
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 0 {
                left = min(left, x); right = max(right, x)
                top = min(top, y); bottom = max(bottom, y)
            }
        }
        guard left <= right, top <= bottom else { throw NSError(domain: "EmptyPillRender", code: 1) }
        let crop = CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        let image = context.makeImage()!.cropping(to: crop)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "PillPNGWrite", code: 1) }
        print("\(url.lastPathComponent): \(image.width) × \(image.height), native offscreen view")
    }
}
