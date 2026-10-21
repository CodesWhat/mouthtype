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
        editor.heardInput = "  mouth   type "
        editor.written = "Mouthtype"
        #expect(editor.canSave && editor.isDirty)
        editor.save()
        #expect(editor.items == [DictionaryRule(heard: "mouth type", written: "Mouthtype")])
        #expect(editor.original == editor.items && !editor.isDirty)
        editor.heardInput = "different draft"
        editor.cancel()
        #expect(editor.heardInput.isEmpty && editor.heardForms == ["mouth type"])
        editor.removeHeardForm("mouth type")
        editor.heardInput = "mouth typing"
        editor.save()
        #expect(try store.allRules().map(\.heard) == ["mouth typing"])
        editor.delete()
        #expect(try store.allRules().isEmpty)
    }

    @Test func aWordGroupsItsHeardFormsAndSavesThemInOneEdit() throws {
        let (dir, store) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(heard: "shawn", written: "Sean")
        try store.save(heard: "mouth type", written: "Mouthtype")
        try store.save(heard: "shaun", written: "Sean")
        let editor = SpellingEditor(store: store)
        #expect(editor.words.map(\.written) == ["Sean", "Mouthtype"])
        #expect(editor.words.first?.heardForms == ["shawn", "shaun"])
        editor.select(try #require(editor.words.first))
        #expect(editor.isEditing && !editor.isDirty)
        editor.removeHeardForm("shawn")
        editor.heardInput = "  shorn "
        editor.starred = true
        #expect(editor.isDirty && editor.canSave)
        editor.save()
        #expect(!editor.isEditing && !editor.isDirty)
        #expect(try store.allRules() == [
            DictionaryRule(heard: "mouth type", written: "Mouthtype"),
            DictionaryRule(heard: "shaun", written: "Sean", starred: true),
            DictionaryRule(heard: "shorn", written: "Sean", starred: true)])
    }

    @Test func newWordWithoutAHeardFormFixesTheWrittenFormOnly() throws {
        let (dir, store) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = SpellingEditor(store: store)
        editor.newSpelling()
        #expect(editor.isEditing && !editor.isDirty && !editor.canSave)
        editor.written = "Nguyen"
        #expect(editor.canSave)
        editor.heardInput = "win"
        editor.commitHeardInput()
        editor.heardInput = "WIN"
        editor.commitHeardInput()
        #expect(editor.heardForms == ["win"])
        editor.removeHeardForm("win")
        editor.save()
        #expect(try store.allRules() == [DictionaryRule(heard: "Nguyen", written: "Nguyen")])
    }

    @Test func cancelClosesTheSheetAndDropsTheDraft() throws {
        let (dir, store) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(heard: "mouth type", written: "Mouthtype")
        let editor = SpellingEditor(store: store)
        editor.select(try #require(editor.words.first))
        editor.heardInput = "mouse type"
        editor.written = "Other"
        editor.cancel()
        #expect(!editor.isEditing && !editor.isDirty && editor.heardInput.isEmpty)
        #expect(try store.allRules() == [DictionaryRule(heard: "mouth type", written: "Mouthtype")])
    }

    @Test func starTogglesEveryRuleOfAWordAndKeepsOrder() throws {
        let (dir, store) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(heard: "shawn", written: "Sean")
        try store.save(heard: "mouth type", written: "Mouthtype")
        try store.save(heard: "shaun", written: "Sean")
        let editor = SpellingEditor(store: store)
        var changes = 0
        editor.onLibraryChanged = { changes += 1 }
        let sean = try #require(editor.words.first)
        #expect(!sean.starred)
        editor.toggleStar(sean)
        #expect(editor.words.first?.starred == true && editor.words.last?.starred == false && changes == 1)
        #expect(try store.allRules().map(\.heard) == ["shawn", "mouth type", "shaun"])
        editor.toggleStar(try #require(editor.words.first))
        #expect(editor.words.first?.starred == false)
    }

    @Test func savingAWordThatChangedOnDiskReportsAnErrorAndKeepsTheDraft() throws {
        let (dir, store) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(heard: "shawn", written: "Sean")
        let editor = SpellingEditor(store: store)
        editor.select(try #require(editor.words.first))
        try store.save(heard: "shawn", written: "Shaun")
        editor.heardInput = "shaun"
        editor.save()
        #expect(editor.error != nil && editor.isDirty && editor.isEditing)
        #expect(try store.allRules() == [DictionaryRule(heard: "shawn", written: "Shaun")])
    }

    @Test func aHeardFormAnotherWordOwnsIsRejected() throws {
        let (dir, store) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(heard: "shawn", written: "Sean")
        let editor = SpellingEditor(store: store)
        editor.newSpelling()
        editor.written = "Shawn"
        editor.heardInput = "SHAWN"
        editor.save()
        #expect(editor.error != nil && editor.isDirty)
        #expect(try store.allRules().count == 1)
    }

    @Test func saveAndDeleteTellTheSuggestionsTheLibraryChanged() throws {
        let (dir, store) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = SpellingEditor(store: store)
        var changes = 0
        editor.onLibraryChanged = { changes += 1 }
        editor.heardInput = "mouth type"
        editor.written = "Mouthtype"
        editor.save()
        #expect(changes == 1)
        editor.delete()
        #expect(changes == 2)
    }

    @Test func everydayHeardFormWarnsButStillSaves() throws {
        let (dir, store) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = SpellingEditor(store: store)
        editor.heardInput = "win"
        editor.written = "Nguyen"
        #expect(editor.everydayWarning?.contains("everyday word") == true)
        #expect(editor.canSave)
        editor.heardInput = "shivon"
        #expect(editor.everydayWarning == nil)
    }

    @Test func strayWhitespaceDoesNotMakeAnEverydayWordAPhrase() {
        let padded = SpellingWord(written: "Nguyen", rules: [DictionaryRule(heard: " win ", written: "Nguyen")])
        #expect(padded.warning != nil)
        #expect(!padded.hasEverydayPhrase)
        let phrase = SpellingWord(written: "Nguyen", rules: [DictionaryRule(heard: "win win", written: "Nguyen")])
        #expect(phrase.hasEverydayPhrase)
    }

    @Test func draftAndLibrarySurviveOutsideChanges() throws {
        let (dir, store) = try library()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(heard: "mouth type", written: "Mouthtype")
        let editor = SpellingEditor(store: store)
        let first = try #require(editor.words.first)
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
        editor.heardInput = "MOUTH TYPE"
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
        editor.heardInput = "geoff"
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
        editor.select(try #require(editor.words.first))
        FontRegistry.registerBundledFonts()
        let view = NSHostingView(rootView: SpellingEditorView(editor: editor, suggestions: SpellingSuggestionsModel(vocabulary: store)))
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
        editor.heardInput = "  " + String(repeating: "x", count: 128) + "  "
        editor.written = "  " + String(repeating: "Y", count: 128) + "  "
        #expect(editor.canSave && editor.validationMessage == nil)
        editor.save()
        #expect(editor.items.first?.heard.count == 128 && editor.items.first?.written.count == 128)
    }

}
