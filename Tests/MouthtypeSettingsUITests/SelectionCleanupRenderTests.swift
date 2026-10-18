import AppKit
import Testing
@testable import MouthtypeMac

@MainActor @Suite(.serialized) struct SelectionCleanupRenderTests {
    @Test(arguments: [false, true], ["light", "dark"])
    func selectionStartsInCompactWindow(long: Bool, appearance: String) throws {
        let text = long ? String(repeating: "hello world ", count: 1_000) : "um hello  world"
        let model = SelectionCleanupModel(editor: PreviewSelectionEditor(text: text))
        model.prepare()
        let controller = SelectionCleanupWindow(model: model)
        let window = try #require(controller.window)
        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        let view = try #require(window.contentView)
        view.layoutSubtreeIfNeeded()
        _ = view.fittingSize
        #expect(view.frame.height <= 620)
        if long {
            #expect(view.frame.height >= 450)
        } else {
            #expect(view.frame.height <= 340)
        }
        #expect(!window.isVisible)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if long {
            let editor = try #require(descendants(of: view).compactMap { $0 as? NSTextView }.first)
            let scroll = try #require(editor.enclosingScrollView)
            #expect(editor.frame.height > scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: editor.frame.height - scroll.contentView.bounds.height))
            #expect(scroll.contentView.bounds.minY > 0)
        }
        if let directory = ProcessInfo.processInfo.environment["MOUTHTYPE_SETTINGS_PREVIEWS"] {
            let folder = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: folder.appendingPathComponent("selection-\(long ? "long" : "short")-\(appearance).png"))
        }
    }

    @Test func editingPreviewGrowsAndShrinksTheSameWindow() throws {
        let model = SelectionCleanupModel(editor: PreviewSelectionEditor(text: "um hello  world"))
        model.prepare()
        let controller = SelectionCleanupWindow(model: model)
        let view = try #require(controller.window?.contentView)
        let shortHeight = view.frame.height
        model.result = String(repeating: "A longer edited preview. ", count: 100)
        view.layoutSubtreeIfNeeded()
        _ = view.fittingSize
        #expect(view.frame.height > shortHeight + 100)
        #expect(view.frame.height <= 620)
        model.result = "Hello again"
        view.layoutSubtreeIfNeeded()
        _ = view.fittingSize
        #expect(view.frame.height <= shortHeight + 8)
        #expect(controller.window?.isVisible == false)
    }

    @Test(arguments: [260.0, 300.0, 400.0])
    func longSelectionFitsShortDisplay(heightLimit: CGFloat) throws {
        let model = SelectionCleanupModel(editor: PreviewSelectionEditor(text: String(repeating: "hello world ", count: 1_000)))
        model.prepare()
        model.accept()
        let controller = SelectionCleanupWindow(model: model, maximumContentHeight: heightLimit)
        let view = try #require(controller.window?.contentView)
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.height <= heightLimit)
        #expect(view.frame.height <= heightLimit)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let editor = try #require(descendants(of: view).compactMap { $0 as? NSTextView }.first)
        #expect(editor.enclosingScrollView?.contentView.bounds.height ?? 0 >= 44)
        #expect(model.message.contains("selection changed"))
        #expect(controller.window?.isVisible == false)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

@MainActor private final class PreviewSelectionEditor: SelectionEditing {
    let text: String
    init(text: String) { self.text = text }

    func capture() throws -> SelectedText {
        SelectedText(pid: 123, element: nil, range: NSRange(location: 0, length: text.utf16.count), text: text)
    }

    func replace(_ original: SelectedText, with replacement: String) -> Bool { false }
}
