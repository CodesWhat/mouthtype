import AppKit
import ImageIO

/// When the Glass pill uses the system material and when it falls back to the solid Classic body, with no view in it.
enum GlassPillPolicy {
    enum Variant: Equatable, Sendable {
        /// Clear glass over light content, with dark ink.
        case clear
        /// Smoked glass over dark content, with the Classic light ink.
        case smoked
    }

    enum Fallback: Equatable, Sendable {
        case materialUnavailable, reduceTransparency, lowContrast
    }

    enum Decision: Equatable, Sendable {
        case glass(Variant)
        case solid(Fallback)

        var usesMaterial: Bool {
            if case .glass = self { return true }
            return false
        }
    }

    /// What lies behind the pill: relative luminance 0 (black) to 1 (white) averaged over the sampled area, and how
    /// much it varies (standard deviation of the same).
    struct Backdrop: Equatable, Sendable {
        var luminance: Double
        var spread: Double
    }

    /// Above this the backdrop is light enough for clear glass with dark ink; below `darkLimit`, dark enough for smoked
    /// glass with light ink. Between them neither ink reads reliably.
    static let lightLimit = 0.62
    static let darkLimit = 0.38
    /// A backdrop that varies more than this is too busy for either ink.
    static let busySpread = 0.22

    /// `backdrop` nil means the wallpaper couldn't be read. Smoked glass is the dark-safe choice then, because its tint
    /// carries the light ink on its own.
    static func decide(materialAvailable: Bool, reduceTransparency: Bool, backdrop: Backdrop?) -> Decision {
        guard materialAvailable else { return .solid(.materialUnavailable) }
        guard !reduceTransparency else { return .solid(.reduceTransparency) }
        guard let backdrop else { return .glass(.smoked) }
        guard backdrop.spread <= busySpread else { return .solid(.lowContrast) }
        if backdrop.luminance >= lightLimit { return .glass(.clear) }
        if backdrop.luminance <= darkLimit { return .glass(.smoked) }
        return .solid(.lowContrast)
    }

    /// Relative luminance of an sRGB colour with 0...1 channels.
    static func luminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// Mean and spread of the luminance over RGBA8 `pixels` (premultiplied alpha is fine, the wallpaper is opaque).
    static func analyze(rgba pixels: [UInt8]) -> Backdrop? {
        let count = pixels.count / 4
        guard count > 0 else { return nil }
        var values = [Double]()
        values.reserveCapacity(count)
        for i in 0..<count {
            values.append(luminance(
                red: Double(pixels[4 * i]) / 255, green: Double(pixels[4 * i + 1]) / 255, blue: Double(pixels[4 * i + 2]) / 255
            ))
        }
        let mean = values.reduce(0, +) / Double(count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(count)
        return Backdrop(luminance: mean, spread: variance.squareRoot())
    }
}

/// Samples the desktop picture under the pill. It reads the wallpaper file at thumbnail size, so it needs no screen
/// recording permission, and it only runs when the pill appears. Windows over the wallpaper are not seen.
@MainActor
enum GlassBackdropSampler {
    private static let thumbnailPixels = 96
    private static let sampleSize = (width: 24, height: 8)
    private static var cache: (key: String, backdrop: GlassPillPolicy.Backdrop?)?

    /// `region` is the pill's area in global screen coordinates.
    static func sample(screen: NSScreen, region: CGRect) -> GlassPillPolicy.Backdrop? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        let key = "\(url.path)|\(Int(region.minX)),\(Int(region.minY)),\(Int(region.width)),\(Int(region.height))"
        if let cache, cache.key == key { return cache.backdrop }
        let result = measure(url: url, screenFrame: screen.frame, region: region)
        cache = (key, result)
        return result
    }

    private static func measure(url: URL, screenFrame: CGRect, region: CGRect) -> GlassPillPolicy.Backdrop? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let crop = cropRect(imageSize: CGSize(width: image.width, height: image.height), screenFrame: screenFrame, region: region)
        guard let part = image.cropping(to: crop) else { return nil }
        let (w, h) = sampleSize
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(part, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? GlassPillPolicy.analyze(rgba: pixels) : nil
    }

    /// The part of the wallpaper (in image pixels, top-left origin) behind `region`, with the picture scaled to fill
    /// the screen and centred, which is how the desktop shows most pictures.
    static func cropRect(imageSize: CGSize, screenFrame: CGRect, region: CGRect) -> CGRect {
        let scale = max(screenFrame.width / imageSize.width, screenFrame.height / imageSize.height)
        let offsetX = (screenFrame.width - imageSize.width * scale) / 2
        let offsetY = (screenFrame.height - imageSize.height * scale) / 2
        // Screen y grows upward, image rows downward.
        let x = (region.minX - screenFrame.minX - offsetX) / scale
        let y = (screenFrame.maxY - region.maxY - offsetY) / scale
        let bounds = CGRect(origin: .zero, size: imageSize)
        let rect = CGRect(x: x, y: y, width: region.width / scale, height: region.height / scale).intersection(bounds)
        return rect.isNull || rect.width < 1 || rect.height < 1 ? bounds : rect.integral.intersection(bounds)
    }
}
