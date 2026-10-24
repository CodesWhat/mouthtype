import AppKit
import SwiftUI
import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@MainActor
@Suite struct PhraseEditorTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func draftsSaveCancelRenameAndDelete() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FilePhrases(url: dir.appendingPathComponent("phrases.json"))
        let editor = PhraseEditor(store: store)
        #expect(editor.items.isEmpty && !editor.canSave && !editor.isDirty)
        editor.trigger = "  my   email "
        editor.expansion = "  me@example.com\n"
        #expect(editor.isDirty && editor.canSave)
        editor.save()
        #expect(editor.items == [Snippet(trigger: "my email", expansion: "  me@example.com\n")])
        #expect(!editor.isDirty && editor.original == editor.items.first)
        editor.trigger = "another trigger"
        editor.cancel()
        #expect(editor.trigger == "my email" && !editor.isDirty)
        editor.trigger = "work email"
        editor.save()
        #expect(try store.all().map(\.trigger) == ["work email"])
        editor.delete()
        #expect(try store.all().isEmpty)
        #expect(editor.original == nil && !editor.isDirty)
    }

    @Test func dirtyDraftCannotBeDiscardedBySelectingOrStartingAnother() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FilePhrases(url: dir.appendingPathComponent("phrases.json"))
        let phrase = Snippet(trigger: "say hello", expansion: "Hello!")
        try store.save(original: nil, phrase: phrase)
        let editor = PhraseEditor(store: store)
        editor.trigger = "draft"
        editor.select(phrase)
        editor.newPhrase()
        editor.reload()
        #expect(editor.trigger == "draft" && editor.original == nil && editor.isDirty)
        editor.cancel()
        editor.select(phrase)
        #expect(editor.trigger == phrase.trigger && !editor.isDirty)
    }

    @Test func externalChangesAreShownWithoutOverwritingTheFileOrDraft() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("phrases.json")
        let store = FilePhrases(url: url)
        let phrase = Snippet(trigger: "say hello", expansion: "Hello!")
        try store.save(original: nil, phrase: phrase)
        let editor = PhraseEditor(store: store)
        editor.select(phrase)
        editor.expansion = "My draft"
        try Data("broken".utf8).write(to: url)
        editor.save()
        #expect(editor.error != nil && editor.expansion == "My draft" && editor.isDirty)
        #expect(try String(contentsOf: url, encoding: .utf8) == "broken")
        editor.cancel()
        editor.reload()
        #expect(editor.loadFailed && !editor.canSave && editor.items == [phrase])
        try JSONEncoder().encode([Snippet(trigger: "new phrase", expansion: "New")]).write(to: url)
        editor.reload()
        #expect(!editor.loadFailed && editor.items.map(\.trigger) == ["new phrase"])
    }

    @Test func reloadPreservesTheSelectionAfterAnExternalCapitalizationChange() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FilePhrases(url: dir.appendingPathComponent("phrases.json"))
        let before = Snippet(trigger: "my email", expansion: "before@example.com")
        let after = Snippet(trigger: "My Email", expansion: "after@example.com")
        try store.save(original: nil, phrase: before)
        let editor = PhraseEditor(store: store)
        editor.select(before)
        try store.save(original: before, phrase: after)
        editor.reload()
        #expect(editor.original == after && editor.trigger == after.trigger && editor.expansion == after.expansion)
        #expect(!editor.isDirty)
    }

    @Test func backgroundPreview() throws {
        guard let path = ProcessInfo.processInfo.environment["MOUTHTYPE_PHRASE_PREVIEW"] else { return }
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FilePhrases(url: dir.appendingPathComponent("phrases.json"))
        let phrase = Snippet(trigger: "my work email", expansion: "name@example.com")
        try store.save(original: nil, phrase: phrase)
        try store.save(original: nil, phrase: Snippet(trigger: "today's date", expansion: "{date}"))
        let editor = PhraseEditor(store: store)
        editor.select(phrase)
        FontRegistry.registerBundledFonts()
        let view = NSHostingView(rootView: PhraseEditorView(editor: editor))
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 620)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = try #require(bitmap.representation(using: .png, properties: [:]))
        try image.write(to: URL(fileURLWithPath: path))
        editor.newPhrase()
        editor.trigger = "MY WORK EMAIL"
        editor.expansion = "A duplicate should show this error."
        editor.save()
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 540)
        view.layoutSubtreeIfNeeded()
        let small = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: small)
        try #require(small.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: path + ".small.png"))
    }

}
