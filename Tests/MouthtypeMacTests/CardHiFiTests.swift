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
    let defaults: UserDefaults
    var dismissed = 0

    init(skin: String = "hifi", size: String = "standard", readout: PillReadoutColour = .amber) {
        _ = NSApplication.shared
        FontRegistry.registerBundledFonts()
        let defaults = UserDefaults(suiteName: "card-hifi-test-\(UUID().uuidString)")!
        self.defaults = defaults
        defaults.set(skin, forKey: "pillSkin")
        defaults.set(size, forKey: "pillSize")
        defaults.set(readout.rawValue, forKey: PillReadoutPreference.key)
        pill = PillController(level: { .silence }, defaults: defaults)
        pill.cardSettle = 0
        presenter = DeliveryCardPresenter(surface: cards, clipboard: clipboard, clock: FakeClock(start: 0))
        cards.defaults = defaults
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
        #expect(HiFiCardText.display("Café “quoted” \u{2192} it\u{2019}s\u{2026}", metrics: metrics) == "CAFE \"QUOTED\" \u{2192} IT'S...")
        #expect(HiFiCardText.display("日本", metrics: metrics) == "??")
    }

    @Test func lineEndingsAreNormalizedBeforeDrawing() throws {
        let metrics = try #require(HiFiCardAssets.shared).font5.metrics
        #expect(HiFiCardText.display("one\r\ntwo\rthree\nfour", metrics: metrics) == "ONE\nTWO\nTHREE\nFOUR")
        let hifi = try #require(hifiView(.pasteFailed("First line\r\nSecond line\r\n\r\nFourth")).hifi)
        let drawn = hifi.lines.map { HiFiCardText.text(of: $0) }
        #expect(drawn == ["FIRST LINE", "SECOND LINE", "", "FOURTH"] && !drawn.joined().contains("?"))
    }

    @Test func theFaceHasTheArrowAndTheEarAndOnlyTheEarIsOffLimitsToTypedText() throws {
        let assets = try #require(HiFiCardAssets.shared)
        let metrics = assets.font5.metrics
        #expect(metrics.chars.contains("\u{2192}") && metrics.chars.contains(HiFiCardText.ear))
        #expect(HiFiCardText.canDraw("heard \u{2192} wrote", metrics: metrics) && !HiFiCardText.canDraw(String(HiFiCardText.ear), metrics: metrics))
        #expect(assets.font5.image(for: "\u{2192}", color: PillLayout.color(hex: "#ffffff")) != nil)
        let pair = try #require(hifiView(.rememberSpelling(SpellingPair(heard: "Shawn", corrected: "Sean"))).hifi)
        let drawn = pair.lines.map { HiFiCardText.text(of: $0) }.joined()
        #expect(drawn == "SHAWN \u{2192} SEAN" && !drawn.contains("->"))
        // The ear sits in the title plate, drawn in the plate's engraved ink.
        let frames = try #require(pair.frames)
        #expect(frames.ear.x >= frames.plate.x && frames.ear.x + frames.ear.w <= frames.plate.x + frames.plate.w)
        #expect(frames.ear.y >= frames.plate.y && frames.ear.y + frames.ear.h <= frames.plate.y + frames.plate.h)
        #expect(Int(frames.titleOrigin.x) >= frames.ear.x + frames.ear.w)
    }

    // MARK: Fallback

    @Test func textThePixelFaceCantDrawFallsBackToTheClassicCardForThatDelivery() throws {
        let view = hifiView(.pasteFailed("Hello there."))
        #expect(view.showsHiFi && view.hifiCanDraw)
        let hifiSize = view.faceSize
        for text in ["こんにちは、世界", "Привет мир", "50 \u{20AC} \u{2022} done", "emoji \u{1F600}"] {
            let card = DeliveryCard.pasteFailed(text)
            view.render(CardViewState(card: card), typography: Typography.current())
            #expect(!view.showsHiFi && !view.hifiCanDraw && view.hifi?.isHidden == true, "\(text)")
            #expect(view.faceSize != .zero && view.faceSize != hifiSize)
            #expect(view.center(of: .copy) != nil)
        }
        let header = DeliveryCard(kind: .pasteFailed, header: "Paste failed\n東京", transcript: "ok", actions: [.copy], countdown: nil)
        view.render(CardViewState(card: header), typography: Typography.current())
        #expect(!view.showsHiFi)
        let pair = DeliveryCard.rememberSpelling(SpellingPair(heard: "Shawn", corrected: "Шон"))
        view.render(CardViewState(card: pair), typography: Typography.current())
        #expect(!view.showsHiFi)
        view.render(CardViewState(card: .pasteFailed("Back to Latin, café.")), typography: Typography.current())
        #expect(view.showsHiFi && view.hifi?.isHidden == false && view.faceSize.width == 224)
    }

    @Test func aFallbackDeliveryStillShowsAndCopiesTheOriginalText() throws {
        let rig = HiFiRig()
        let text = "これは日本語です。"
        rig.presenter.present(.pasteFailed(text))
        #expect(rig.cards.view.style == .hifi && !rig.cards.view.showsHiFi && rig.cards.panel.isVisible)
        let frame = try #require(rig.cards.view.buttonFrames[.copy])
        #expect(rig.cards.view.hitTest(CGPoint(x: frame.midX, y: frame.midY)) is CardButtonView)
        rig.presenter.perform(.copy)
        #expect(rig.clipboard.written == [text])
        rig.finish()
    }

    // MARK: Hit areas

    private static let buttonCards: [(card: DeliveryCard, actions: [CardAction])] = [
        (.pasteFailed("Send the notes."), [.copy]),
        (.cancelled(), [.undo]),
        (.recoverOffer(seconds: 12, ago: 30, older: 0), [.recover, .discard]),
        (.micDisconnected(seconds: 4), [.insert, .discard]),
        (.rememberSpelling(SpellingPair(heard: "Shawn", corrected: "Sean")), [.save, .notNow]),
        (.forgetSpelling(SpellingPair(heard: "Shawn", corrected: "Sean")), [.forget, .keep]),
    ]

    @Test func everyButtonIsHitAndFiresAtStandardAndLarge() throws {
        for scale in [PillScale.standard, .large] {
            for entry in Self.buttonCards {
                let view = hifiView(entry.card, scale: scale)
                let hifi = try #require(view.hifi)
                var fired: [CardAction] = []
                view.onAction = { fired.append($0) }
                #expect(Set(hifi.buttonViews.keys) == Set(entry.actions))
                for action in entry.actions {
                    let button = try #require(hifi.buttonViews[action])
                    let frame = try #require(view.buttonFrames[action])
                    let center = try #require(view.center(of: action))
                    #expect(frame.contains(center))
                    // The centre and all four inner corners land on this button.
                    for point in [
                        CGPoint(x: frame.midX, y: frame.midY), CGPoint(x: frame.minX + 1, y: frame.minY + 1),
                        CGPoint(x: frame.maxX - 1, y: frame.minY + 1), CGPoint(x: frame.minX + 1, y: frame.maxY - 1),
                        CGPoint(x: frame.maxX - 1, y: frame.maxY - 1),
                    ] {
                        #expect(view.hitTest(point) === button, "\(action) at \(scale)")
                    }
                    fired = []
                    try click(button, window: nil)
                    #expect(fired == [action], "\(action) at \(scale)")
                }
            }
        }
    }

    @Test func theCloseButtonHitAreaIsAtLeast24PointsAtBothSizes() throws {
        for scale in [PillScale.standard, .large] {
            for card in [DeliveryCard.pasteFailed("Hi"), .cancelled(), .recoverOffer(seconds: 12, ago: 30, older: 0)] {
                let view = hifiView(card, scale: scale)
                let hifi = try #require(view.hifi)
                var dismissed = 0
                view.onDismiss = { dismissed += 1 }
                let frame = view.dismissFrame
                #expect(frame.width >= 24 * scale.factor && frame.height >= 24 * scale.factor, "\(scale)")
                #expect(view.bounds.contains(frame))
                for point in [
                    CGPoint(x: frame.midX, y: frame.midY), CGPoint(x: frame.minX + 1, y: frame.minY + 1),
                    CGPoint(x: frame.maxX - 1, y: frame.maxY - 1),
                ] {
                    #expect(view.hitTest(point) === hifi.closeView)
                }
                try click(hifi.closeView, window: nil)
                #expect(dismissed == 1)
            }
        }
    }

    // MARK: Readout colour

    @Test func anOpenCardRepaintsWhenTheReadoutColourSettingChanges() throws {
        let rig = HiFiRig(readout: .amber)
        rig.presenter.present(.pasteFailed("Send the notes."))
        let hifi = try #require(rig.cards.view.hifi)
        let amber = hifi.faceImage
        #expect(rig.cards.view.hifiReadout == .amber)
        rig.cards.refreshReadoutColour()
        #expect(hifi.faceImage === amber)
        PillReadoutPreference.set(.coolWhite, in: rig.defaults)
        rig.cards.refreshReadoutColour()
        #expect(rig.cards.view.hifiReadout == .coolWhite && hifi.readout == .coolWhite && hifi.faceImage !== amber)
        let palette = PillReadoutColour.coolWhite.palette(base: try #require(HiFiCardAssets.shared).pill.layout.colors)
        #expect(pixelCount(hifi.faceImage, hex: palette.text) > 40 && pixelCount(hifi.faceImage, hex: "#ffb02e") == 0)
        // A later redraw of the same card (a font change, say) keeps the new colour.
        rig.cards.render(CardViewState(card: .pasteFailed("Send the notes.")))
        #expect(rig.cards.view.hifiReadout == .coolWhite)
        rig.finish()
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
