import AppKit
import SwiftUI
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@MainActor @Suite(.serialized) struct TransformsRenderTests {
    private func model(phrases: [Snippet]) throws -> (SettingsModel, PhraseEditor, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-transforms-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = FilePhrases(url: dir.appendingPathComponent("phrases.json"))
        for phrase in phrases { try store.save(original: nil, phrase: phrase) }
        let editor = PhraseEditor(store: store)
        let suite = "TransformsRender-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let model = SettingsModel(defaults: defaults, phrases: editor)
        model.page = .transforms
        return (model, editor, dir)
    }

    private static let sample = [
        Snippet(trigger: "my work email", expansion: "scott@example.com"),
        Snippet(trigger: "sign off", expansion: "Thanks,\nScott"),
        Snippet(trigger: "meeting link", expansion: "https://meet.google.com/kqp-vwxa-hhz"),
        Snippet(trigger: "paste link", expansion: "{clipboard}"),
        Snippet(trigger: "today's date", expansion: "{date}"),
        Snippet(trigger: "a very long spoken phrase that runs past its column", expansion: String(repeating: "A long line of typed text that keeps going. ", count: 8)),
    ]

    @Test(arguments: [false, true])
    func transformsPageRenders(dark: Bool) throws {
        FontRegistry.registerBundledFonts()
        let (model, _, dir) = try model(phrases: Self.sample)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bitmap = try SettingsRender.render(model: model, actions: SettingsActions(), dark: dark)
        #expect(bitmap.pixelsWide >= Int(SettingsTheme.windowSize.width))
        try SettingsRender.save(bitmap, name: "transforms-\(dark ? "dark" : "light")")
    }

    @Test(arguments: [false, true])
    func emptyLibraryStillShowsSelectedTextTransforms(dark: Bool) throws {
        FontRegistry.registerBundledFonts()
        let (model, _, dir) = try model(phrases: [])
        defer { try? FileManager.default.removeItem(at: dir) }
        let bitmap = try SettingsRender.render(model: model, actions: SettingsActions(), dark: dark)
        try SettingsRender.save(bitmap, name: "transforms-empty-\(dark ? "dark" : "light")")
    }

    @Test(arguments: [false, true])
    func phraseSheetRenders(dark: Bool) throws {
        FontRegistry.registerBundledFonts()
        let (_, editor, dir) = try model(phrases: Self.sample)
        defer { try? FileManager.default.removeItem(at: dir) }
        editor.select(Self.sample[1])
        editor.expansion += "\n{date}"
        let size = NSSize(width: 520, height: 470)
        let bitmap = try SettingsRender.render(PhraseFormSheet(editor: editor) {}, dark: dark, size: size)
        #expect(bitmap.pixelsWide >= Int(size.width))
        try SettingsRender.save(bitmap, name: "transforms-sheet-\(dark ? "dark" : "light")")
    }
}
