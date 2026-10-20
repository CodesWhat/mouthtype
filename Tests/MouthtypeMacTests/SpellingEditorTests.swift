import AppKit
import Foundation
import SwiftUI
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@MainActor @Suite struct SpellingEditorTests {
    private func library() throws -> (URL, FileVocabulary) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, FileVocabulary(url: dir.appendingPathComponent("dictionary.json")))
    }

    @Test func draftsCanSaveCancelRenameAndDeleteWithoutExamples() throws {
        let (dir, store) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = SpellingEditor(store: store)
        #expect(editor.items.isEmpty && !editor.isDirty && !editor.canSave)
        editor.heard = "  mouth   type "
        editor.written = "Mouthtype"
        #expect(editor.canSave && editor.isDirty)
        editor.save()
        #expect(editor.items == [DictionaryRule(heard: "mouth type", written: "Mouthtype")])
        #expect(editor.original == editor.items.first && !editor.isDirty)
        editor.heard = "different draft"
        editor.cancel()
        #expect(editor.heard == "mouth type")
        editor.heard = "mouth typing"
        editor.save()
        #expect(try store.allRules().map(\.heard) == ["mouth typing"])
        editor.delete()
        #expect(try store.allRules().isEmpty)
    }

    @Test func everydayHeardFormWarnsButStillSaves() throws {
        let (dir, store) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = SpellingEditor(store: store)
        editor.heard = "win"
        editor.written = "Nguyen"
        #expect(editor.everydayWarning?.contains("everyday word") == true)
        #expect(editor.canSave)
        editor.heard = "shivon"
        #expect(editor.everydayWarning == nil)
    }

    @Test func draftAndLibrarySurviveOutsideChanges() throws {
        let (dir, store) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(heard: "mouth type", written: "Mouthtype")
        let editor = SpellingEditor(store: store)
        let first = try #require(editor.items.first)
        editor.select(first)
        editor.written = "My draft"
        editor.newSpelling()
        editor.reload()
        #expect(editor.isDirty && editor.written == "My draft")
        try store.save(heard: "mouth type", written: "External")
        editor.save()
        #expect(editor.isDirty && editor.error != nil && editor.written == "My draft")
        #expect(try store.allRules().first?.written == "External")
        editor.cancel()
        editor.reload()
        #expect(editor.written == "External" && !editor.isDirty)
        try Data("broken".utf8).write(to: store.url)
        editor.reload()
        #expect(editor.loadFailed && editor.items.first?.written == "External")
        editor.written = "Blocked"
        #expect(!editor.canSave)
        editor.save()
        #expect(try String(contentsOf: store.url, encoding: .utf8) == "broken")
        editor.cancel()
        #expect(editor.error != nil && editor.loadFailed)
        editor.select(first)
        #expect(editor.error != nil && editor.loadFailed)

    }

    @Test func duplicateReportsAnErrorWithoutLosingTheDraft() throws {
        let (dir, store) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(heard: "mouth type", written: "Mouthtype")
        let editor = SpellingEditor(store: store)
        editor.heard = "MOUTH TYPE"
        editor.written = "Other"
        editor.save()
        #expect(editor.error != nil && editor.isDirty && editor.written == "Other")
        #expect(try store.allRules().first?.written == "Mouthtype")
    }
    @Test func menuWorksWithCleanupOffWithoutCreatingExampleRules() throws {
        let suite = "spelling-menu-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = CleanupSettings()
        settings.level = .off
        settings.save(to: defaults)
        var opened = 0
        let section = CleanupMenuSection(defaults: defaults, manageSpellings: { opened += 1 })
        let menu = try #require(section.items.first?.submenu)
        let item = try #require(menu.items.first { $0.title == "Saved Spellings…" })
        #expect(item.isEnabled)
        _ = item.target?.perform(item.action, with: item)
        #expect(opened == 1)
    }

    @Test func configuredNameReachesThePipelineWithoutChangingLongerWords() throws {
        let (dir, store) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = SpellingEditor(store: store)
        editor.heard = "geoff"
        editor.written = "Jeff"
        editor.save()
        let result = TextPipeline().run(TextPipelineInput(text: "the meeting is with geoff and geoffrey", dictionary: store.dictionary()))
        #expect(result.text == "The meeting is with Jeff and geoffrey")
        editor.delete()
        let after = TextPipeline().run(TextPipelineInput(text: "the meeting is with geoff", dictionary: store.dictionary()))
        #expect(after.text == "The meeting is with geoff")
    }

    @Test func backgroundPreview() throws {
        guard let path = ProcessInfo.processInfo.environment["MOUTHTYPE_SPELLING_PREVIEW"] else { return }
        let (dir, store) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(heard: "mouth type", written: "Mouthtype")
        try store.save(heard: "super whisper", written: "Superwhisper")
        let editor = SpellingEditor(store: store)
        editor.select(try #require(editor.items.first))
        FontRegistry.registerBundledFonts()
        let view = NSHostingView(rootView: SpellingEditorView(editor: editor))
        for (label, size) in [("", NSSize(width: 900, height: 550)), (".small", NSSize(width: 760, height: 500))] {
            view.frame = NSRect(origin: .zero, size: size)
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path + label + ".png"))
        }
    }

    @Test func lengthValidationUsesTheSpellingThatWillActuallyBeSaved() throws {
        let (dir, store) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = SpellingEditor(store: store)
        editor.heard = "  " + String(repeating: "x", count: 128) + "  "
        editor.written = "  " + String(repeating: "Y", count: 128) + "  "
        #expect(editor.canSave && editor.validationMessage == nil)
        editor.save()
        #expect(editor.items.first?.heard.count == 128 && editor.items.first?.written.count == 128)
    }

}
