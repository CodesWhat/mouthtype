import AppKit
import Foundation
import Testing
@testable import MouthtypeMac

@MainActor
@Suite struct MessageLayoutTests {
    typealias L = ClassicPillLayout

    /// A fixed-pitch stand-in for a font: 6 pt a character for a headline, 5 for a detail.
    private func block(_ headline: String, _ detail: String? = nil, pitch: (CGFloat, CGFloat) = (6, 5)) -> L.MessageBlock {
        L.messageBlock(headline: headline, detail: detail, headlineLineHeight: 16, detailLineHeight: 14, scale: 2) { text, isDetail in
            CGFloat(text.count) * (isDetail ? pitch.1 : pitch.0)
        }
    }

    @Test func oneLineWhenThereIsNoDetail() {
        let b = block("Too short")
        #expect(b.lines.map(\.text) == ["Too short"] && b.height == L.height)
        #expect(b.width == 9 * 6 + 2 * L.messagePadding && b.lines[0].centerOffset == 0)
        #expect(block("Hi").width == L.messageMinWidth)
        #expect(block("Hi", "").lines.count == 1)
    }

    @Test func twoLinesBreakAtTheLogicalPoint() {
        let b = block("Microphone disconnected", "14 seconds saved to history")
        #expect(b.lines.map(\.text) == ["Microphone disconnected", "14 seconds saved to history"])
        #expect(b.lines.map(\.isDetail) == [false, true])
        #expect(b.height > L.height)
        let widest = max(23 * 6, 27 * 5)
        #expect(b.width == CGFloat(widest) + 2 * L.messagePadding)
        // The block is centred: it spans the same distance above the middle as below it.
        let first = b.lines[0], last = b.lines[1]
        #expect(first.centerOffset - first.height / 2 == -(last.centerOffset + last.height / 2))
        #expect(first.centerOffset < 0 && last.centerOffset > 0)
        #expect(b.height >= first.height + last.height + 2 * L.messageVerticalPadding)
    }

    @Test func aPartWrapsOnlyWhenWiderThanTheCap() {
        let available = L.messageCap - 2 * L.messagePadding
        let headline = Array(repeating: "wordy", count: 20).joined(separator: " ")
        let b = block(headline, "short detail")
        let head = b.lines.filter { !$0.isDetail }
        #expect(head.count > 1 && b.lines.last?.text == "short detail")
        #expect(b.width > 300 && b.width <= L.messageCap)
        for line in head { #expect(CGFloat(line.text.count) * 6 <= available) }
        #expect(head.map(\.text).joined(separator: " ") == headline)
        #expect(b.height > block("a", "b").height)
    }

    @Test func anOverlongWordBreaksBetweenCharactersAndLosesNothing() {
        let word = String(repeating: "x", count: 120)
        let b = block(word)
        #expect(b.lines.count > 1)
        #expect(b.lines.map(\.text).joined() == word)
        for line in b.lines { #expect(CGFloat(line.text.count) * 6 <= L.messageCap - 2 * L.messagePadding) }
    }

    @Test func nothingIsEverEllipsized() {
        let b = block(String(repeating: "lorem ipsum ", count: 40), String(repeating: "dolor sit ", count: 40))
        #expect(!b.lines.contains { $0.text.contains("\u{2026}") })
        #expect(b.lines.map(\.text).joined(separator: " ").split(separator: " ").count == 80 + 80)
    }

    @Test func heightGrowsWithEachLineAndStaysOnTheGrid() {
        var last: CGFloat = 0
        for n in 1...6 {
            let b = block(Array(repeating: String(repeating: "w", count: 40), count: n).joined(separator: " "))
            #expect(b.height >= last)
            #expect(Int(b.height * 2) % 2 == 0 && Int(b.width * 2) % 2 == 0)
            last = b.height
        }
    }

    @Test func wrapHandlesEmptyAndSpacedInput() {
        #expect(L.wrap("", width: 100) { CGFloat($0.count) * 6 } == [""])
        #expect(L.wrap("  a   b  ", width: 100) { CGFloat($0.count) * 6 } == ["a b"])
    }

    @Test func theRealViewLaysOutWithFontsOfDifferentWidths() {
        _ = NSApplication.shared
        FontRegistry.registerBundledFonts()
        let message = PillMessage(
            "Microphone disconnected", detail: "14 seconds saved to history, and the rest of the dictation was lost"
        )
        var widths: [CGFloat] = []
        for choice in [TextFontChoice.system, .mono, .systema, .serif] {
            let view = ClassicPillView(frame: NSRect(origin: .zero, size: PillGeometry.panelSize))
            view.applyTypography(Typography(choice: choice))
            view.showMessage(message, overRecording: false)
            let size = view.messageSize
            widths.append(size.width)
            #expect(size.width <= L.messageCap && size.height > L.height)
            #expect(view.messageLines.count >= 2 && view.messageLines.first?.isDetail == false)
            #expect(!view.messageLines.contains { $0.text.contains("\u{2026}") })
            // Every line fits its box at the real font.
            let typography = Typography(choice: choice)
            for line in view.messageLines {
                let font = typography.font(line.isDetail ? .pillDetail : .pillMessage)
                let measured = NSAttributedString(string: line.text, attributes: [.font: font]).size().width
                #expect(measured <= size.width - 2 * L.messagePadding + 0.5, "\(choice.title): \(line.text)")
            }
        }
        #expect(Set(widths).count > 1)
    }

    @Test func aShortRealMessageStaysOneLineAndAnErrorKeepsItsRed() {
        _ = NSApplication.shared
        let view = ClassicPillView(frame: NSRect(origin: .zero, size: PillGeometry.panelSize))
        view.showMessage(PillMessage("Too short"), overRecording: false)
        #expect(view.messageLines.count == 1 && view.messageSize.height == L.height)
        view.showMessage(PillMessage("Boom", isError: true), overRecording: false)
        #expect(ClassicPillView.errorInk == NSColor(hex: 0xFF6B5E))
    }

    @Test func hiFiGetsTheTwoPartsOnOneLine() {
        #expect(PillMessage("Too short").singleLine == "Too short")
        #expect(PillMessage("Microphone disconnected", detail: "14 seconds saved").singleLine == "Microphone disconnected - 14 seconds saved")
    }

    @Test func theMessageStringsSplitAtTheirLogicalBreak() {
        #expect(DictationController.microphoneAccessMessage == PillMessage(
            "Microphone access needed", detail: "Allow it in System Settings", isError: true
        ))
        let table: [(CaptureError, String, String?)] = [
            (.microphoneDenied, "Microphone access needed", "Allow it in System Settings"),
            (.microphonePending, "Microphone access needed", "Allow it in System Settings"),
            (.noInputDevice, "No microphone found", "Connect one and try again"),
            (.routeChanged, "Microphone changed", "Try again"),
            (.notRecording, "Couldn't record", "Try again"),
        ]
        for (error, headline, detail) in table {
            let message = DictationController.pillMessage(for: error)
            #expect(message.headline == headline && message.detail == detail && message.isError)
        }
        #expect(DictationController.pillMessage(for: NSError(domain: "x", code: 1)) == PillMessage(
            "Transcription failed", detail: "Try again", isError: true
        ))
    }
}
