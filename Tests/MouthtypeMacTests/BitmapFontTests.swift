import CoreGraphics
import Testing
@testable import MouthtypeMac

@Suite struct BitmapFontTests {
    private let metrics = BitmapFont.Metrics(
        cellWidth: 5, cellHeight: 7, gap: 1, chars: Array(" AB.:"), advances: [":": 1]
    )

    @Test func lookupFindsTheGlyphAndUppercasesLetters() {
        #expect(metrics.glyphIndex(for: "A") == 1)
        #expect(metrics.glyphIndex(for: "b") == 2)
        #expect(metrics.glyphIndex(for: ".") == 3)
    }

    @Test func unknownCharactersFallBackToTheBlankCell() {
        #expect(metrics.glyphIndex(for: "~") == 0)
        #expect(metrics.glyphIndex(for: "é") == 0)
        #expect(metrics.glyphIndex(for: "ß") == 0)
        #expect(metrics.glyphIndex(for: " ") == 0)
    }

    @Test func widthCountsAdvancesAndGapsButNoTrailingGap() {
        #expect(metrics.width(of: "") == 0)
        #expect(metrics.width(of: "A") == 5)
        #expect(metrics.width(of: "AB") == 11)
        #expect(metrics.width(of: "A~") == 11)
        #expect(metrics.width(of: "A:B") == 5 + 1 + 1 + 1 + 5)
        #expect(metrics.width(of: "ab") == metrics.width(of: "AB"))
    }

    @Test func placementsFollowTheAdvances() {
        let placed = metrics.placements(of: "A:B")
        #expect(placed.map(\.x) == [0, 6, 8])
        #expect(placed.map(\.index) == [1, 4, 2])
    }

    @Test func shippedAtlasesMatchTheirMetricsAndRenderTintedImages() throws {
        let assets = try PillAssets.loadHiFi()
        for (name, font) in assets.fonts {
            #expect(font.atlas.width == font.metrics.cellWidth * font.metrics.chars.count, "\(name)")
            #expect(font.atlas.height == font.metrics.cellHeight)
            #expect(font.metrics.chars.first == " ")
        }
        let f5 = try #require(assets.fonts["f5"])
        let image = try #require(f5.image(for: "too short", color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)))
        #expect(image.width == f5.width(of: "TOO SHORT") && image.height == 7)
        #expect(f5.image(for: "", color: CGColor(gray: 1, alpha: 1)) == nil)

        let f3 = try #require(assets.fonts["f3"])
        #expect(f3.width(of: "1:24") == 13)
        #expect(f3.width(of: "0:00") == 13)
    }
}
