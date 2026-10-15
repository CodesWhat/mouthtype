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
    }
}
