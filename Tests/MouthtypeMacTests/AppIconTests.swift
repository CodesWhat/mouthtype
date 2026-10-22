import Foundation
import ImageIO
import Testing

@Suite struct AppIconTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func pixelSize(of url: URL) throws -> [Int] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil), "\(url.lastPathComponent) missing")
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil), "\(url.lastPathComponent) undecodable")
        return [image.width, image.height]
    }

    @Test func theIconsetHasEveryRequiredSize() throws {
        let dir = Self.root.appendingPathComponent("design/icon/AppIcon.iconset")
        let expected = [
            "icon_16x16": 16, "icon_16x16@2x": 32, "icon_32x32": 32, "icon_32x32@2x": 64,
            "icon_128x128": 128, "icon_128x128@2x": 256, "icon_256x256": 256, "icon_256x256@2x": 512,
            "icon_512x512": 512, "icon_512x512@2x": 1024,
        ]
        for (name, side) in expected {
            #expect(try pixelSize(of: dir.appendingPathComponent(name + ".png")) == [side, side], "\(name)")
        }
    }

    @Test func theIcnsDecodesAndHoldsTheMaster() throws {
        let url = Self.root.appendingPathComponent("packaging/AppIcon.icns")
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        var widths: Set<Int> = []
        for index in 0..<CGImageSourceGetCount(source) {
            if let image = CGImageSourceCreateImageAtIndex(source, index, nil) { widths.insert(image.width) }
        }
        #expect(widths.contains(1024) && widths.contains(16))
    }

    @Test func theInfoPlistNamesTheIcon() throws {
        let plist = Self.root.appendingPathComponent("packaging/Info.plist")
        let dict = try #require(NSDictionary(contentsOf: plist))
        #expect(dict["CFBundleIconFile"] as? String == "AppIcon")
        #expect(dict["CFBundleIconName"] as? String == "AppIcon")
    }

    private func alphaAt(_ image: CGImage, x: Int, y: Int) throws -> UInt8 {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(
            CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return pixel[3]
    }

    private func image(_ path: String) throws -> CGImage {
        let url = Self.root.appendingPathComponent(path)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil), "\(path) missing")
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    @Test func theTileIsFullBleedWithNoBakedShadowOrCorners() throws {
        for path in ["design/icon/AppIcon-1024.png", "design/icon/AppIcon.iconset/icon_32x32.png"] {
            let tile = try image(path)
            for (x, y) in [(0, 0), (tile.width - 1, 0), (0, tile.height - 1), (tile.width - 1, tile.height - 1)] {
                #expect(try alphaAt(tile, x: x, y: y) == 255, "\(path) corner (\(x), \(y)) should be opaque")
            }
        }
    }

    @Test func theIconBundleHasTileAndLipsLayers() throws {
        let bundle = Self.root.appendingPathComponent("design/icon/AppIcon.icon")
        let json = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: bundle.appendingPathComponent("icon.json"))) as? [String: Any])
        let groups = try #require(json["groups"] as? [[String: Any]])
        let layers = try #require(groups.first?["layers"] as? [[String: Any]])
        let names = Set(layers.compactMap { $0["name"] as? String })
        #expect(names == ["tile", "lips", "lips-mono"])
        for layer in layers {
            let file = try #require(layer["image-name"] as? String)
            let url = bundle.appendingPathComponent("Assets/" + file)
            #expect(try pixelSize(of: url) == [1024, 1024], "\(file)")
        }
        #expect(json["fill-specializations"] != nil, "the Dark appearance needs its own tile fill")

        // Tinted shows only the mono lips: the coloured lips hide under tinted, the mono ones hide everywhere else.
        func hiddenSpecializations(_ name: String) throws -> [[String: Any]] {
            let layer = try #require(layers.first { $0["name"] as? String == name }, "\(name) layer")
            return try #require(layer["hidden-specializations"] as? [[String: Any]], "\(name) hidden-specializations")
        }
        func value(_ specs: [[String: Any]], appearance: String?) -> Bool? {
            specs.first { $0["appearance"] as? String == appearance }?["value"] as? Bool
        }
        let colour = try hiddenSpecializations("lips")
        #expect(value(colour, appearance: nil) == false && value(colour, appearance: "tinted") == true)
        let mono = try hiddenSpecializations("lips-mono")
        #expect(value(mono, appearance: nil) == true && value(mono, appearance: "tinted") == false)
    }

    @Test func theMonoLipsKnockOutTheMouthAndCursor() throws {
        let lips = try image("design/icon/AppIcon.icon/Assets/lips-mono.png")
        let colour = try image("design/icon/AppIcon.icon/Assets/lips.png")
        // the cursor stem sits at the centre: opaque in the coloured lips, knocked out in the mono ones
        #expect(try alphaAt(colour, x: 512, y: 512) == 255)
        #expect(try alphaAt(lips, x: 512, y: 512) == 0)
        // the red body of the lips stays solid
        #expect(try alphaAt(lips, x: 512, y: 420) == 255)
        #expect(try alphaAt(lips, x: 4, y: 4) == 0)
    }
}
