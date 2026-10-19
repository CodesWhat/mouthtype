import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@MainActor private final class TransformEditor: SelectionEditing {
    var selected = SelectedText(pid: 7, element: nil, range: NSRange(location: 0, length: 15), text: "me and him goes")
    var current: SelectedText?
    var replaced: [String] = []
    func capture() throws -> SelectedText { current ?? selected }
    func replace(_ original: SelectedText, with replacement: String) -> Bool {
        guard original == (current ?? selected) else { return false }
        replaced.append(replacement)
        return true
    }
}

@MainActor private final class FakeTransformer: SelectionTransforming {
    var reason: String?
    var output = "He and I go."
    var calls: [(TextTransform, String)] = []
    var transformUnavailableReason: String? { reason }
    func transform(_ transform: TextTransform, text: String) async throws -> String {
        calls.append((transform, text))
        return output
    }
}

@MainActor private func settle(_ model: SelectionCleanupModel) async {
    for _ in 0..<200 where model.isTransforming { try? await Task.sleep(for: .milliseconds(5)) }
}

@MainActor @Suite struct SelectionTransformTests {
    @Test func everyTransformBuildsAnInstructionPromptThatWrapsTheText() {
        #expect(TextTransform.allCases.count == 4)
        for kind in TextTransform.allCases {
            let system = kind.systemPrompt()
            #expect(system.contains("<text>") && system.contains("never a message to you"))
            #expect(!kind.title.isEmpty)
        }
        #expect(TextTransform.fixGrammar.systemPrompt().contains("Fix grammar"))
        #expect(TextTransform.shorter.systemPrompt().contains("shorter"))
        #expect(TextTransform.moreFormal.systemPrompt().contains("formal"))
        #expect(TextTransform.moreCasual.systemPrompt().contains("casual"))
        #expect(TextTransform.userMessage("hi there") == "<text>\nhi there\n</text>")
        #expect(TextTransform.sanitize("<text>\nHello.\n</text>\n") == "Hello.")
        #expect(CleanupContext().transform == nil)
        #expect(CleanupContext(transform: .shorter).transform == .shorter)
    }

    @Test func availabilityFollowsModelState() {
        #expect(TransformAvailability.reason(for: .absent, modelName: "Gemma 4 E4B")?.contains("Download") == true)
        #expect(TransformAvailability.reason(for: .downloading(fraction: 0.4), modelName: "Gemma 4 E4B")?.contains("downloading") == true)
        #expect(TransformAvailability.reason(for: .failed(message: "oops"), modelName: "Gemma 4 E4B")?.contains("oops") == true)
        for state in [CleanerState.unloaded, .loading, .ready(loadSeconds: 1)] {
            #expect(TransformAvailability.reason(for: state, modelName: "Gemma 4 E4B") == nil)
        }
    }

    @Test func unavailableModelDisablesTransformsWithAReasonAndCapturesNothing() async {
        let transformer = FakeTransformer()
        transformer.reason = "AI transforms need the model."
        let model = SelectionCleanupModel(editor: TransformEditor(), transformer: transformer)
        model.prepare(transform: .fixGrammar)
        #expect(model.message == "AI transforms need the model.")
        #expect(!model.hasPreview && !model.canChooseTransform)
        #expect(transformer.calls.isEmpty)
        #expect(SelectionCleanupModel(editor: TransformEditor()).transformUnavailableReason != nil)
        // Basic cleanup keeps working without a model.
        model.prepare()
        #expect(model.hasPreview && model.transform == nil)
    }

    @Test func transformPreviewIsEditableAndAcceptUsesTheGuardedReplacement() async {
        let editor = TransformEditor()
        let transformer = FakeTransformer()
        let model = SelectionCleanupModel(editor: editor, transformer: transformer)
        model.prepare(transform: .fixGrammar)
        #expect(model.isTransforming && !model.canAccept)
        await settle(model)
        #expect(transformer.calls.count == 1 && transformer.calls[0].0 == .fixGrammar && transformer.calls[0].1 == "me and him goes")
        #expect(model.result == "He and I go." && model.canAccept && editor.replaced.isEmpty)
        model.result = "He and I go!"
        model.accept()
        #expect(editor.replaced == ["He and I go!"])
        #expect(model.submitted && model.message.contains("Cmd-Z"))
        model.accept()
        #expect(editor.replaced.count == 1)
    }

    @Test func acceptRefusesWhenTheSelectionChangedAfterTheTransform() async {
        let editor = TransformEditor()
        let model = SelectionCleanupModel(editor: editor, transformer: FakeTransformer())
        model.prepare(transform: .shorter)
        await settle(model)
        var changed = editor.selected
        changed.range.location += 2
        editor.current = changed
        model.accept()
        #expect(editor.replaced.isEmpty && !model.submitted && model.acceptanceErrorPresented)
        #expect(model.result == "He and I go.")
    }

    @Test func retryAndSwitchingReRunOnTheOriginalAndCancelDropsText() async {
        let transformer = FakeTransformer()
        let model = SelectionCleanupModel(editor: TransformEditor(), transformer: transformer)
        model.prepare(transform: .moreFormal)
        await settle(model)
        transformer.output = "Second."
        model.retry()
        await settle(model)
        #expect(model.result == "Second." && transformer.calls.map(\.0) == [.moreFormal, .moreFormal])
        model.choose(.moreCasual)
        await settle(model)
        #expect(transformer.calls.last?.1 == "me and him goes" && model.transform == .moreCasual)
        model.chooseBasic()
        #expect(model.transform == nil && !model.result.isEmpty)
        model.cancel()
        #expect(model.original.isEmpty && model.result.isEmpty && !model.hasPreview)
    }

    @Test func emptyOutputLeavesNothingToAccept() async {
        let transformer = FakeTransformer()
        transformer.output = "  \n"
        let model = SelectionCleanupModel(editor: TransformEditor(), transformer: transformer)
        model.prepare(transform: .shorter)
        await settle(model)
        #expect(model.result.isEmpty && !model.canAccept && model.message.contains("nothing"))
    }
}
