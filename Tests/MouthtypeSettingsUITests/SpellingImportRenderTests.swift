import AppKit
import SwiftUI
import Testing
@testable import MouthtypeMac

@MainActor @Suite(.serialized) struct SpellingImportRenderTests {
    @Test func importPreviewAndErrorsRenderWithoutOpeningAFilePicker() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileVocabulary(url: dir.appendingPathComponent("dictionary.json"))
        try store.save(heard: "mouth type", written: "Mouthtype")
        let editor = SpellingEditor(store: store)
        FontRegistry.registerBundledFonts()
        editor.previewImport(data: Data("heard,written\nshawn,Sean\nmouth type,Mouthtype\nshawn,Sean".utf8), fileName: "team-names.csv")
        try render(editor, name: "spelling-import-ready", size: NSSize(width: 720, height: 560))
        #expect(editor.canImport)
        #expect(try store.allRules().count == 1)
        editor.cancelImport()
        editor.previewImport(
            data: Data("heard,written\nmouth type,Other\n,Missing\nnew,New".utf8),
            fileName: "Team names and exact aliases for the forthcoming customer support and product documentation rollout with conflicts to resolve before importing.csv")
        try render(editor, name: "spelling-import-errors", size: NSSize(width: 620, height: 520))
        #expect(!editor.canImport)
        editor.cancelImport()
        editor.previewImport(data: Data("bad header".utf8), fileName: "invalid.csv")
        try render(editor, name: "spelling-import-invalid", size: NSSize(width: 620, height: 480))
        #expect(editor.importPreview?.problem != nil)
    }

    @Test func importSheetRendersAllValidWarningsAndManyRowsInLightAndDark() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileVocabulary(url: dir.appendingPathComponent("dictionary.json"))
        try store.save(heard: "priya", written: "Priya")
        let editor = SpellingEditor(store: store)
        FontRegistry.registerBundledFonts()
        editor.previewImport(data: Data("heard,written\nshawn,Sean\npriya,Priya\ndry doc,Drydock".utf8), fileName: "names.csv")
        #expect(editor.canImport)
        try renderBoth(editor, name: "spelling-import-sheet-valid")
        editor.cancelImport()
        editor.previewImport(data: Data("heard,written\nshawn,Sean\npriya,Priya\n,Hyprland\nomar key,Omarchy\nwin,Winn".utf8), fileName: "names.csv")
        #expect(!editor.canImport)
        #expect(editor.importPreview?.rows.contains { $0.everydayWarning != nil } == true)
        try renderBoth(editor, name: "spelling-import-sheet-invalid")
        editor.cancelImport()
        var many = "heard,written\n"
        for n in 1...20 { many += "heard \(n),Written\(n)\n" }
        many += ",Late error\n"
        editor.previewImport(data: Data(many.utf8), fileName: "many.csv")
        #expect(!editor.canImport)
        try renderBoth(editor, name: "spelling-import-sheet-many-invalid-late")
        editor.cancelImport()
        editor.previewImport(data: Data(many.split(separator: "\n").dropLast().joined(separator: "\n").utf8), fileName: "many.csv")
        #expect(editor.canImport)
        try renderBoth(editor, name: "spelling-import-sheet-many")
    }

    private func renderBoth(_ editor: SpellingEditor, name: String) throws {
        for dark in [false, true] {
            let host = NSHostingView(rootView: SpellingImportView(editor: editor).environment(\.colorScheme, dark ? .dark : .light))
            let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            let size = host.fittingSize
            #expect(size.width == SpellingImportView.width)
            host.setFrameSize(size)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(bitmap.pixelsWide >= Int(size.width) && bitmap.pixelsHigh >= Int(size.height))
            if let directory = ProcessInfo.processInfo.environment["MOUTHTYPE_SETTINGS_PREVIEWS"] {
                let output = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    private func render(_ editor: SpellingEditor, name: String, size: NSSize) throws {
        let view = NSHostingView(rootView: SpellingImportView(editor: editor))
        view.setFrameSize(size)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= Int(size.width) && bitmap.pixelsHigh >= Int(size.height))
        if let directory = ProcessInfo.processInfo.environment["MOUTHTYPE_SETTINGS_PREVIEWS"] {
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
        }
    }
}
