import AppKit
import Testing
@testable import MouthtypeMac

@MainActor @Suite struct PillPreviewTests {
    @Test func readoutFitsInsideFixedPanelAndNeverTakesEvents() {
        let view = PillPreviewView(frame: NSRect(x: 24, y: 94, width: 320, height: 100))
        #expect(view.isHidden)
        let text = String(repeating: "👨‍👩‍👧‍👦", count: 400)
        view.update(text)
        view.layoutSubtreeIfNeeded()
        #expect(!view.isHidden)
        #expect(view.visibleText.count <= LivePreviewSession.maximumCharacters)
        #expect(text.hasSuffix(view.visibleText))
        #expect(view.hitTest(NSPoint(x: 20, y: 20)) == nil)
        #expect(view.frame.maxY <= PillGeometry.panelSize.height)
        view.update("")
        #expect(view.isHidden)
    }
    @Test func optionalOffscreenPreviewImage() throws {
        guard let path = ProcessInfo.processInfo.environment["MOUTHTYPE_PREVIEW_IMAGE"] else { return }
        let view = PillPreviewView(frame: NSRect(x: 0, y: 0, width: 320, height: 100))
        view.update("Send the first draft before lunch. These words may change before the final transcript is inserted.")
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path))
    }

}
