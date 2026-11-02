import CoreGraphics
import Foundation

/// One pixel of art: straight (not premultiplied) components, 0 to 1.
struct PixelColor: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, alpha: alpha)
    }

    func withAlpha(_ value: Double) -> PixelColor {
        var copy = self
        copy.alpha = alpha * value
        return copy
    }

    /// This colour mixed toward `other` by `amount`, keeping this colour's alpha.
    func mixed(with other: PixelColor, _ amount: Double) -> PixelColor {
        PixelColor(
            red: red + (other.red - red) * amount, green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount, alpha: alpha)
    }
}

/// A grid of pixels drawn from character templates, the way the bitmap fonts are: whole pixels, no smoothing. Turned into a
/// `CGImage` at one pixel per art pixel, then scaled up with interpolation off.
struct PixelCanvas {
    let width: Int
    let height: Int
    private(set) var pixels: [PixelColor?]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = Array(repeating: nil, count: width * height)
    }

    func pixel(_ x: Int, _ y: Int) -> PixelColor? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        return pixels[y * width + x]
    }

    /// Paints `color` over what is there, blending by alpha. Out-of-range pixels are ignored.
    mutating func paint(_ x: Int, _ y: Int, _ color: PixelColor) {
        guard x >= 0, y >= 0, x < width, y < height, color.alpha > 0 else { return }
        guard let under = pixels[y * width + x] else { pixels[y * width + x] = color; return }
        let alpha = color.alpha + under.alpha * (1 - color.alpha)
        func mix(_ over: Double, _ below: Double) -> Double {
            (over * color.alpha + below * under.alpha * (1 - color.alpha)) / alpha
        }
        pixels[y * width + x] = PixelColor(
            red: mix(color.red, under.red), green: mix(color.green, under.green), blue: mix(color.blue, under.blue), alpha: alpha)
    }

    /// Draws `rows` with its top left at (`x`, `y`). `.` is clear. A character `color` has no answer for is left clear.
    mutating func draw(_ rows: [String], at origin: (x: Int, y: Int) = (0, 0), color: (Character) -> PixelColor?) {
        for (row, text) in rows.enumerated() {
            for (column, character) in text.enumerated() where character != "." {
                if let paint = color(character) { self.paint(origin.x + column, origin.y + row, paint) }
            }
        }
    }

    mutating func fill(x: Int, y: Int, width: Int, height: Int, _ color: PixelColor) {
        for row in y..<(y + height) { for column in x..<(x + width) { paint(column, row, color) } }
    }

    /// RGBA, premultiplied, one pixel per art pixel.
    var bytes: [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for (index, pixel) in pixels.enumerated() {
            guard let pixel else { continue }
            func byte(_ value: Double) -> UInt8 { UInt8((min(1, max(0, value)) * 255).rounded()) }
            out[index * 4] = byte(pixel.red * pixel.alpha)
            out[index * 4 + 1] = byte(pixel.green * pixel.alpha)
            out[index * 4 + 2] = byte(pixel.blue * pixel.alpha)
            out[index * 4 + 3] = byte(pixel.alpha)
        }
        return out
    }

    var image: CGImage? {
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
