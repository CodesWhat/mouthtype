import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MouthtypeMac

@MainActor @Suite(.serialized) struct SpellingEditorScaleTests {
    /// Lays the Dictionary page out inside a scroll view, as the app does, with 5,000 saved words.
    private func layoutSeconds(rows: Int) throws -> (seconds: Double, rowViews: Int) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileVocabulary(url: dir.appendingPathComponent("dictionary.json"))
        let editor = SpellingEditor(store: store)
        var csv = "heard,written\n"
        for n in 0..<rows { csv += "heard form \(n),Written\(n)\n" }
        editor.previewImport(data: Data(csv.utf8), fileName: "scale.csv")
        editor.confirmImport()
        #expect(editor.words.count == rows)
        FontRegistry.registerBundledFonts()
        let page = DesignPage(title: "Your names, spelled right.") {
            SpellingEditorView(editor: editor, suggestions: SpellingSuggestionsModel(vocabulary: store))
        }
        let host = NSHostingView(rootView: page)
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        let start = ContinuousClock.now
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return (seconds, countButtons(host))
    }

    private func countButtons(_ view: NSView) -> Int {
        view.subviews.reduce(view is NSButton ? 1 : 0) { $0 + countButtons($1) }
    }

    @Test func fiveThousandWordsLayOutLazily() throws {
        let result = try layoutSeconds(rows: 5000)
        print("SCALE5K layout=\(result.seconds)s views=\(result.rowViews)")
        #expect(result.seconds < 2.0)
    }
}
