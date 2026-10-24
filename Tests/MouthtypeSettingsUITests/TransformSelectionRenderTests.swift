import AppKit
import MouthtypeCore
import Testing
@testable import MouthtypeMac

@MainActor @Suite(.serialized) struct TransformSelectionRenderTests {
    enum Scene: String, CaseIterable { case normal, aiBusy, refused, modelMissing }

    @Test(arguments: Scene.allCases, ["light", "dark"])
    func panelRenders(scene: Scene, appearance: String) async throws {
        let editor = SceneEditor(replaces: scene != .refused)
        let transformer = SceneTransformer(reason: scene == .modelMissing ? "AI transforms need the Thorough cleanup model. Download it in Settings, then try again." : nil)
        let model = SelectionCleanupModel(editor: editor, transformer: transformer, appName: { _ in "Slack" })
        switch scene {
        case .normal, .modelMissing: await model.prepare()
        case .aiBusy: await model.prepare(transform: .fixGrammar)
        case .refused:
            await model.prepare()
            model.accept()
        }
        let controller = SelectionCleanupWindow(model: model)
        let window = try #require(controller.window)
        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        let view = try #require(window.contentView)
        view.layoutSubtreeIfNeeded()
        _ = view.fittingSize
        #expect(view.frame.width == 640)
        #expect(view.frame.height <= 620 && view.frame.height >= 240)
        #expect(!window.isVisible)
        switch scene {
        case .normal:
            #expect(model.transform == nil && model.sourceApp == "Slack" && model.canAccept)
            #expect(model.transformUnavailableReason == nil)
        case .aiBusy:
            #expect(model.isTransforming && model.canRetry == false && model.transform == .fixGrammar)
        case .refused:
            #expect(model.refused && !model.canAccept && !model.result.isEmpty)
            #expect(model.refusalTitle.contains("Slack"))
        case .modelMissing:
            #expect(model.transformUnavailableReason != nil && !model.canChooseTransform)
        }
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["MOUTHTYPE_SETTINGS_PREVIEWS"] {
            let folder = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: folder.appendingPathComponent("transform-selection-\(scene.rawValue)-\(appearance).png"))
        }
        model.cancel()
    }

    @Test func highlightsAndStrikesAreDrawnFromTheDiff() {
        let original = "um so the meeting is uh at three pm tomorrow. i think we should bring the report."
        let result = "So the meeting is at three pm tomorrow. I think we should bring the report."
        let struck = SelectionCleanupView.originalText(original, result: result)
        #expect(struck.runs.filter { $0.strikethroughStyle != nil }.map { String(struck[$0.range].characters) } == ["um", "uh"])
        let marked = SelectionCleanupView.resultText(result, original: original)
        #expect(marked.runs.filter { $0.backgroundColor != nil }.map { String(marked[$0.range].characters) } == ["S", "I"])
    }
}

@MainActor private final class SceneEditor: SelectionEditing {
    let replaces: Bool
    init(replaces: Bool) { self.replaces = replaces }
    func capture() throws -> SelectedText {
        let text = "um so the meeting is uh at three pm tomorrow. i think we should bring the report."
        return SelectedText(pid: 123, element: nil, range: NSRange(location: 0, length: text.utf16.count), text: text)
    }
    func replace(_ original: SelectedText, with replacement: String) -> Bool { replaces }
}

/// Never finishes, so the AI-busy scene stays busy for the render.
@MainActor private final class SceneTransformer: SelectionTransforming {
    let transformUnavailableReason: String?
    init(reason: String?) { transformUnavailableReason = reason }
    func transform(_ transform: TextTransform, text: String) async throws -> String {
        try await Task.sleep(for: .seconds(60))
        return text
    }
}
