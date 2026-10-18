import AppKit
import Foundation
import Testing
@testable import MouthtypeMac

@MainActor
private final class RecordingClipboard: ClipboardWriting {
    var written: [String] = []
    func write(_ text: String) { written.append(text) }
}

/// A real pill, card window and presenter wired the way the app wires them, on one skin, size and readout colour.
@MainActor
private final class HiFiRig {
    let pill: PillController
    let cards = DeliveryCardController()
    let presenter: DeliveryCardPresenter
    let clipboard = RecordingClipboard()
    var dismissed = 0

    init(skin: String = "hifi", size: String = "standard", readout: PillReadoutColour = .amber) {
        _ = NSApplication.shared
        FontRegistry.registerBundledFonts()
        let defaults = UserDefaults(suiteName: "card-hifi-test-\(UUID().uuidString)")!
        defaults.set(skin, forKey: "pillSkin")
        defaults.set(size, forKey: "pillSize")
        defaults.set(readout.rawValue, forKey: PillReadoutPreference.key)
        pill = PillController(level: { .silence }, defaults: defaults)
        pill.cardSettle = 0
        presenter = DeliveryCardPresenter(surface: cards, clipboard: clipboard, clock: FakeClock(start: 0))
        cards.anchor = { [weak pill] in pill?.cardAnchor() }
        cards.onAction = { [weak presenter] in presenter?.perform($0) }
        cards.onDismiss = { [weak self] in
            self?.dismissed += 1
            self?.presenter.userDismissed()
        }
    }

    func finish() {
        presenter.dismiss()
        pill.hide()
    }
}

@MainActor
private func hifiView(_ card: DeliveryCard, scale: PillScale = .standard, readout: PillReadoutColour = .amber) -> DeliveryCardView {
    _ = NSApplication.shared
    FontRegistry.registerBundledFonts()
    let view = DeliveryCardView(frame: .zero)
    view.configure(style: .hifi, scale: scale, embedded: false, readout: readout)
    view.render(CardViewState(card: card), typography: Typography.current())
    return view
}

/// How many pixels of `image` are exactly `hex`.
private func pixelCount(_ image: CGImage?, hex: String) -> Int {
    guard let image, let context = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let data = context.data else { return 0 }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
    let (r, g, b) = (UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF))
    let bytes = data.assumingMemoryBound(to: UInt8.self)
    var count = 0
    for index in 0..<(image.width * image.height) where bytes[index * 4 + 3] == 255 && bytes[index * 4] == r && bytes[index * 4 + 1] == g && bytes[index * 4 + 2] == b {
        count += 1
    }
    return count
}

@MainActor
@Suite struct HiFiCardTests {
    private let longTranscript = String(repeating: "Please send the revised mockups to Sean before Friday and copy the design channel on it. ", count: 6)
        + String(repeating: "Supercalifragilisticexpialidocious", count: 4)

    private func event(_ type: NSEvent.EventType, in view: NSView, at point: CGPoint, window: NSWindow?) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    private func click(_ control: NSView, window: NSWindow?) throws {
        let middle = CGPoint(x: control.bounds.midX, y: control.bounds.midY)
        control.mouseDown(with: try event(.leftMouseDown, in: control, at: middle, window: window))
        control.mouseUp(with: try event(.leftMouseUp, in: control, at: middle, window: window))
    }

    // MARK: Which card

    @Test func theHiFiSkinDrawsItsOwnCardAndTheOthersDoNot() {
        #expect(PillSkinKind.hifi.cardStyle == .hifi && PillSkinKind.classic.cardStyle == .classic)
        let hifi = HiFiRig()
        hifi.presenter.present(.pasteFailed("Send the notes."))
        #expect(hifi.cards.view.style == .hifi && hifi.cards.view.showsHiFi && !hifi.cards.isMerged)
        #expect(hifi.cards.panel.isVisible && hifi.cards.view.hifi?.isHidden == false)
        hifi.finish()
        let classic = HiFiRig(skin: "classic")
        classic.presenter.present(.pasteFailed("Send the notes."))
        #expect(classic.cards.view.style == .classic && !classic.cards.view.showsHiFi)
        #expect(classic.cards.view.hifi?.isHidden ?? true)
        classic.finish()
    }

    @Test func theCardKnowsTheReadoutColourFromTheSetting() throws {
        for colour in PillReadoutColour.allCases {
            let rig = HiFiRig(readout: colour)
            let anchor = try #require(rig.pill.cardAnchor())
            #expect(anchor.readout == colour)
            rig.presenter.present(.pasteFailed("Send the notes."))
            #expect(rig.cards.view.hifiReadout == colour && rig.cards.view.hifi?.readout == colour)
            rig.finish()
        }
    }

    // MARK: Layout

    @Test func theCardIsAWholeNumberOfArtPixelsAndDoublesAtLarge() throws {
        for card in [DeliveryCard.pasteFailed(longTranscript), .pasteFailed("Hi"), .cancelled(), .rememberSpelling(SpellingPair(heard: "Shawn", corrected: "Sean")), .micDisconnected(seconds: 4)] {
            let standard = hifiView(card)
            let large = hifiView(card, scale: .large)
            let hs = try #require(standard.hifi), hl = try #require(large.hifi)
            let frames = try #require(hs.frames)
            #expect(frames.width == 224)
            #expect(standard.faceSize == CGSize(width: 224, height: CGFloat(frames.height)))
            #expect(large.faceSize == CGSize(width: 448, height: CGFloat(frames.height) * 2))
            #expect(hl.frames == frames)
            // Everything sits inside the window, buttons clear the VFD and each other.
            let bounds = PillLayout.Rect(x: 0, y: 0, w: frames.width, h: frames.height)
            for rect in [frames.plate, frames.close, frames.closeHit] + frames.buttons + [frames.vfd].compactMap({ $0 }) {
                #expect(rect.x >= bounds.x && rect.y >= bounds.y && rect.x + rect.w <= bounds.w && rect.y + rect.h <= bounds.h)
            }
            if let vfd = frames.vfd, let first = frames.buttons.first { #expect(first.y >= vfd.y + vfd.h) }
            for (a, b) in zip(frames.buttons, frames.buttons.dropFirst()) { #expect(a.x + a.w < b.x) }
            // Button views land on whole multiples of the art scale.
            for view in hl.buttonViews.values {
                #expect(view.frame.width.truncatingRemainder(dividingBy: 2) == 0 && view.frame.height == 34)
            }
        }
    }

    @Test func thePanelKeepsTheSharedWidthsAtBothSizes() {
        for (size, width) in [("standard", CGFloat(224)), ("large", 448)] {
            let rig = HiFiRig(size: size)
            rig.presenter.present(.pasteFailed("Send the notes."))
            #expect(rig.cards.view.faceSize.width == width)
            #expect(rig.cards.panel.frame.width == width + 2 * CardLayout.shadowMargin * (width / 224))
            rig.finish()
        }
    }

    // MARK: Actions

    @Test func copyCopiesTheOriginalCaseText() throws {
        let text = "Send the mockups to Sean, café-side, before Friday."
        let rig = HiFiRig()
        rig.presenter.present(.pasteFailed(text))
        let copy = try #require(rig.cards.view.hifi?.buttonViews[.copy])
        #expect(rig.cards.view.hifi?.lines.map { HiFiCardText.text(of: $0) }.joined(separator: " ").contains("SEAN") == true)
        try click(copy, window: rig.cards.panel)
        #expect(rig.clipboard.written == [text])
        #expect(rig.cards.view.hifi?.buttonViews[.copy]?.label == "COPIED")
        rig.finish()
    }

    @Test func theCloseButtonDismissesAndEveryButtonKeepsItsRealLabelForVoiceOver() throws {
        let rig = HiFiRig()
        rig.presenter.present(.rememberSpelling(SpellingPair(heard: "Shawn", corrected: "Sean")))
        let hifi = try #require(rig.cards.view.hifi)
        #expect(hifi.buttonViews[.save]?.accessibilityLabel() == "Save" && hifi.buttonViews[.notNow]?.accessibilityLabel() == "Not now")
        #expect(hifi.buttonViews[.save]?.accessibilityRole() == .button && hifi.buttonViews[.save]?.isAccessibilityElement() == true)
        #expect(hifi.buttonViews[.save]?.label == "SAVE" && hifi.buttonViews[.notNow]?.label == "NOT NOW")
        #expect(hifi.closeView.accessibilityLabel() == "Dismiss" && hifi.accessibilityLabel() == "Remember this spelling?")
        #expect(hifi.spokenText == "Shawn to Sean")
        try click(hifi.closeView, window: rig.cards.panel)
        #expect(rig.dismissed == 1)
        rig.finish()
    }

    @Test func voiceOverReadsTheOriginalCaseTranscript() throws {
        let view = hifiView(.pasteFailed("Send the mockups to Sean."))
        #expect(try #require(view.hifi).spokenText == "Send the mockups to Sean.")
    }

    @Test func theUndoCountdownShowsOnTheButtonAndDrainsTheBar() throws {
        let view = hifiView(.cancelled())
        let hifi = try #require(view.hifi)
        #expect(hifi.frames?.bar != nil && hifi.frames?.vfd != nil)
        #expect(hifi.buttonViews[.undo]?.label == "UNDO 5S" && hifi.buttonViews[.undo]?.accessibilityLabel() == "Undo 5s")
        let full = hifi.faceImage
        hifi.tick(remaining: 2.2, fraction: 0.44)
        #expect(hifi.buttonViews[.undo]?.label == "UNDO 3S")
        #expect(hifi.faceImage != nil && pixelCount(hifi.faceImage, hex: "#ffb02e") < pixelCount(full, hex: "#ffb02e"))
        #expect(HiFiCardLayout.litSegments(fraction: 1, count: 50) == 50 && HiFiCardLayout.litSegments(fraction: 0, count: 50) == 0)
        #expect(HiFiCardLayout.litSegments(fraction: 0.001, count: 50) == 1)
    }

    // MARK: Colour

    @Test func theReadoutColourTintsTheTextAndTheBar() throws {
        for colour in PillReadoutColour.allCases {
            let view = hifiView(.pasteFailed("Send the notes."), readout: colour)
            let hifi = try #require(view.hifi)
            let palette = colour.palette(base: try #require(HiFiCardAssets.shared).pill.layout.colors)
            #expect(hifi.textColor == PillLayout.color(hex: palette.text))
            #expect(pixelCount(hifi.faceImage, hex: palette.text) > 40)
            if colour != .amber { #expect(pixelCount(hifi.faceImage, hex: "#ffb02e") == 0) }
            let bar = hifiView(.cancelled(), readout: colour)
            #expect(pixelCount(bar.hifi?.faceImage, hex: palette.normal) > 100)
        }
    }

    @Test func theErrorColourIsDistinctFromTheReadoutColour() throws {
        for colour in PillReadoutColour.allCases {
            let card = DeliveryCard.notLanded("Send the notes.")
            let view = hifiView(card, readout: colour)
            let hifi = try #require(view.hifi)
            let palette = colour.palette(base: try #require(HiFiCardAssets.shared).pill.layout.colors)
            #expect(hifi.errorColor != hifi.textColor && palette.error != palette.text && palette.error != palette.normal)
            #expect(hifi.accentColor(for: card.kind) == hifi.errorColor)
            #expect(hifi.accentColor(for: .rememberSpelling) != hifi.errorColor)
            #expect(pixelCount(hifi.faceImage, hex: palette.error) > 20)
        }
    }

    // MARK: Text

    @Test func aLongTranscriptWrapsByWordAndNeverTruncates() throws {
        let view = hifiView(.pasteFailed(longTranscript))
        let hifi = try #require(view.hifi)
        let metrics = try #require(HiFiCardAssets.shared).font5.metrics
        let drawn = hifi.lines.map { HiFiCardText.text(of: $0) }
        let maxWidth = HiFiCardLayout.textMaxWidth(try #require(HiFiCardAssets.shared).metrics)
        #expect(drawn.allSatisfy { metrics.width(of: $0) <= maxWidth })
        #expect(!drawn.joined().contains("\u{2026}") && !drawn.joined().contains("..."))
        // Every character of the original is in there, in order, ignoring the spaces the wraps ate.
        let original = HiFiCardText.display(longTranscript.trimmingCharacters(in: .whitespaces), metrics: metrics).filter { $0 != " " }
        #expect(drawn.joined().filter { $0 != " " } == original)
        // Whole words stay whole: the over-long word is the only one split.
        let words = Set(longTranscript.split(separator: " ").map { $0.uppercased() })
        let split = drawn.flatMap { $0.split(separator: " ") }.filter { !words.contains(String($0)) }
        #expect(split.allSatisfy { $0.contains("SUPERCALI") || "SUPERCALIFRAGILISTICEXPIALIDOCIOUS".contains($0) })
        #expect(hifi.lines.count > 5 && hifi.vfdLinesVisible == 5)
    }

    @Test func aLongTranscriptScrollsByWholeLinesInsideTheFiveLineCap() throws {
        let hifi = try #require(hifiView(.pasteFailed(longTranscript)).hifi)
        #expect(hifi.scrollOffset == 0)
        let before = hifi.faceImage
        hifi.scrollLines(by: 2)
        #expect(hifi.scrollOffset == 2 && hifi.faceImage != before)
        hifi.scrollLines(by: 1000)
        #expect(hifi.scrollOffset == hifi.lines.count - 5)
        hifi.scrollLines(by: -1000)
        #expect(hifi.scrollOffset == 0 && hifi.frames?.visibleLines == 5)
        let short = try #require(hifiView(.pasteFailed("Short.")).hifi)
        short.scrollLines(by: 3)
        #expect(short.scrollOffset == 0 && short.frames?.visibleLines == 1)
    }

    @Test func wrapSplitsAnOverLongWordAndKeepsParagraphs() throws {
        let metrics = try #require(HiFiCardAssets.shared).font5.metrics
        let lines = HiFiCardText.wrap([("AAAAAAAAAAAAAAAAAAAA B\nC", .normal)], metrics: metrics, maxWidth: 6 * 8 - 1)
        #expect(lines.map { HiFiCardText.text(of: $0) } == ["AAAAAAAA", "AAAAAAAA", "AAAA B", "C"])
        #expect(HiFiCardText.wrap([("", .normal)], metrics: metrics, maxWidth: 100).map { HiFiCardText.text(of: $0) } == [""])
    }

    @Test func displayTextIsCapsInTheFacesAlphabet() throws {
        let metrics = try #require(HiFiCardAssets.shared).font5.metrics
        #expect(HiFiCardText.display("Café “quoted” \u{2192} it\u{2019}s\u{2026}", metrics: metrics) == "CAFE \"QUOTED\" -> IT'S...")
        #expect(HiFiCardText.display("日本", metrics: metrics) == "??")
    }

    // MARK: Art

    @Test func theCardArtLoadsWithItsSlicesAndTheSharedFaces() throws {
        let assets = try #require(HiFiCardAssets.shared)
        for name in ["frame", "button_up", "button_down", "vfd"] {
            let slices = try #require(assets.slices(of: name))
            let sprite = try #require(assets.spec.sprites[name])
            #expect(slices.left + slices.right < sprite.w && slices.top + slices.bottom < sprite.h)
        }
        #expect(assets.frame.width == 40 && assets.closeUp.width == HiFiCardLayout.closeSize && assets.closeDown.height == HiFiCardLayout.closeSize)
        #expect(assets.font5.metrics.cellHeight == 7 && assets.font3.metrics.cellHeight == 5)
        #expect(assets.pill.sprites["led_on"] != nil)
    }

    @Test func exportingTwiceChangesNoBytes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = root.appendingPathComponent("design/pill/export.py")
        let output = root.appendingPathComponent("Sources/MouthtypeMac/Resources/Pill/hifi")
        guard FileManager.default.fileExists(atPath: script.path), FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { return }
        func snapshot() throws -> [String: Data] {
            let files = try #require(FileManager.default.enumerator(at: output, includingPropertiesForKeys: nil))
            var result: [String: Data] = [:]
            for case let url as URL in files where !url.hasDirectoryPath { result[url.path] = try Data(contentsOf: url) }
            return result
        }
        func export() throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-I", script.path]
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        let before = try snapshot()
        try export()
        let first = try snapshot()
        try export()
        let second = try snapshot()
        #expect(first == before && first == second && first.keys.contains { $0.hasSuffix("card/frame.png") })
    }
}
