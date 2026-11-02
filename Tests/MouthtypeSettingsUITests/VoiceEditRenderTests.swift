import AppKit
import MouthtypeCore
import Testing
@testable import MouthtypeMac

@MainActor private final class RenderEditor: SelectionEditing {
    let text: String
    init(text: String) { self.text = text }
    func capture() throws -> SelectedText { throw SelectionCleanupError.unavailable }
    func captureOffMain(budget: TimeInterval) async throws -> SelectedText {
        SelectedText(pid: 1, element: nil, range: NSRange(location: 0, length: text.utf16.count), text: text)
    }
    func replace(_ original: SelectedText, with replacement: String) -> Bool { true }
}

@MainActor private final class RenderRecorder: VoiceInstructionRecording {
    func start() async throws {}
    func finish() async throws -> String { "make it shorter" }
    func cancel() async {}
}

private struct RenderEngine: VoiceEditing {
    var replacement: String
    func run(_ request: VoiceEditRequest) async -> VoiceEditResult {
        .preview(replacement: replacement, instruction: request.instruction)
    }
}

@MainActor @Suite(.serialized) struct VoiceEditRenderTests {
    enum Stage: String, CaseIterable { case recording, preview, previewLong, refused }

    private func coordinator(_ stage: Stage) async -> VoiceEditCoordinator {
        let long = String(repeating: "A longer replacement sentence that keeps going. ", count: 60)
        let flow = VoiceEditCoordinator(
            editor: RenderEditor(text: stage == .refused ? "" : "Hello there, this is the original selection."),
            recorder: RenderRecorder(),
            engine: RenderEngine(replacement: stage == .previewLong ? long : "Hi, this is the original."))
        await flow.begin()
        if stage == .preview || stage == .previewLong { await flow.stopRecording() }
        return flow
    }

    @Test(arguments: Stage.allCases, ["light", "dark"])
    func panelRenders(stage: Stage, appearance: String) async throws {
        let flow = await coordinator(stage)
        let controller = VoiceEditWindow(model: flow)
        let window = try #require(controller.window)
        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        let view = try #require(window.contentView)
        view.layoutSubtreeIfNeeded()
        _ = view.fittingSize
        #expect(view.frame.height <= 560)
        #expect(!window.isVisible)
        switch stage {
        case .recording: #expect(flow.phase == .recording)
        case .preview, .previewLong: #expect(flow.phase == .preview)
        case .refused: #expect(flow.phase == .ended(.refused(.noSelection)))
        }
        if stage == .previewLong {
            let scroll = try #require(descendants(of: view).compactMap { $0 as? NSScrollView }.first)
            #expect(scroll.documentView.map { $0.frame.height > scroll.contentView.bounds.height } == true)
        }
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["MOUTHTYPE_SETTINGS_PREVIEWS"] {
            let folder = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: folder.appendingPathComponent("voice-edit-\(stage.rawValue)-\(appearance).png"))
        }
        await flow.cancel()
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
}
