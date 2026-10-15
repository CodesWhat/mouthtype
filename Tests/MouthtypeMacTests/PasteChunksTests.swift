import Foundation
import Testing
@testable import MouthtypeMac

@Suite struct PasteChunksTests {
    @Test func longUnicodeTextIsSplitWithoutLosingAByteOrBreakingACharacter() throws {
        let text = String(repeating: "Hello 👩🏽‍💻 cafe\u{301}\r\n", count: 200)
        let parts = try #require(PasteChunks.parts(text))
        #expect(parts.count > 1)
        #expect(parts.joined() == text)
        #expect(parts.allSatisfy { !$0.isEmpty && $0.utf8.count <= PasteChunks.byteLimit })
        #expect(parts.flatMap(Array.init) == Array(text))
    }

    @Test func exactBoundaryAndShortTextUseOnePaste() {
        for text in ["", "a short sentence", String(repeating: "a", count: PasteChunks.byteLimit)] {
            #expect(PasteChunks.parts(text) == [text])
        }
    }

    @Test func anOversizedGraphemeIsRejectedBeforeAnythingCanBePasted() {
        #expect(PasteChunks.parts("a" + String(repeating: "\u{301}", count: PasteChunks.byteLimit)) == nil)
    }

    @Test func terminalChunkingIsExplicitPersistentAndPerApp() throws {
        let name = "PasteChunksTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(!PasteSettings.chunksEnabled("com.apple.Terminal", defaults: defaults))
        PasteSettings.setChunks(true, bundleID: "com.apple.Terminal", defaults: defaults)
        #expect(PasteSettings.chunksEnabled("com.apple.Terminal", defaults: defaults))
        #expect(!PasteSettings.chunksEnabled("com.googlecode.iterm2", defaults: defaults))
        PasteSettings.setChunks(true, bundleID: "com.example.browser", defaults: defaults)
        #expect(!PasteSettings.chunksEnabled("com.example.browser", defaults: defaults))
        PasteSettings.setChunks(false, bundleID: "com.apple.Terminal", defaults: defaults)
        #expect(!PasteSettings.chunksEnabled("com.apple.Terminal", defaults: defaults))
    }
}
