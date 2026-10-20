import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@MainActor
private final class EditorEngine: DictationEngine {
    var readiness: EngineReadiness { .ready }
    var seen: [VocabularyBias?] = []
    private var current: VocabularyBias?
    let applied: [String]?
    init(applied: [String]? = nil) { self.applied = applied }
    func setVocabularyBias(_ bias: VocabularyBias?) async { current = bias }
    func transcribe(samples: [Float]) async throws -> Transcription {
        seen.append(current)
        return Transcription(text: "hi Maya applyTheme", processingSeconds: 0, engineID: "editor", boostTermsApplied: applied)
    }
}

private final class CapturingStore: DictationStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var saved: TranscriptionRecord?
    var transcription: TranscriptionRecord? { lock.withLock { saved } }
    func begin(_ start: DictationStart) async throws {}
    func recordCapture(_ id: String, _ record: CaptureRecord) async throws {}
    func recordTranscription(_ id: String, _ record: TranscriptionRecord) async throws { lock.withLock { saved = record } }
    func recordInsertion(_ id: String, _ record: InsertionRecord) async throws {}
    func recordInsertVerdict(_ id: String, outcome: String, pasteReceiptMs: Int?) async throws {}
    func recordLock(_ id: String, mode: DictationMode, trigger: DictationTrigger) async throws {}
    func reopen(_ id: String) async throws {}
    func finish(_ id: String, status: DictationStatus, errorMessage: String?) async throws {}
    func appendEdits(_ id: String, _ edits: [EditOp]) async throws {}
}

private struct Rules: VocabularyProviding {
    var rules: [DictionaryRule]
    func dictionary() -> [DictionaryRule] { rules }
    func snippets() -> [Snippet] { [] }
}

/// Counts reads so a test can show nothing was touched.
@MainActor
private final class ReaderCalls {
    var cursor = 0, document = 0, cwd = 0, workspace = 0
    func readers(context: InsertionContext? = nil) -> EditorHintsGatherer.Readers {
        EditorHintsGatherer.Readers(
            cursorContext: { [self] in cursor += 1; return context },
            documentURL: { [self] in document += 1; return nil },
            workingDirectory: { _, _ in nil },
            workspaceFolder: { _, _ in nil }
        )
    }
}

@MainActor
@Suite struct EditorHintsGathererTests {
    private func focus(_ bundleID: String?, title: String? = nil, secure: Bool = false) -> FocusSnapshot {
        FocusSnapshot(pid: 1, bundleID: bundleID, windowTitle: title, isSecure: secure)
    }

    private func audio() -> CapturedAudio {
        let samples = (0..<16_000).map { Float(0.4 * sin(Double($0) * 0.2)) }
        return CapturedAudio(
            samples: samples, sampleRate: 16_000, deviceUID: nil, deviceName: nil, deviceTransport: "test",
            firstSampleMs: 0, firstNonzeroMs: 0, captureStartMs: 0, audioMs: 1000
        )
    }

    // MARK: Opt-in and where it runs

    @Test func settingDefaultsOff() {
        let defaults = UserDefaults(suiteName: "editor-hints-\(UUID().uuidString)")!
        #expect(!EditorHintsSetting.isEnabled(defaults))
        EditorHintsSetting.set(true, in: defaults)
        #expect(EditorHintsSetting.isEnabled(defaults))
    }

    @Test func offGathersNothingAndReadsNothing() {
        let calls = ReaderCalls()
        let task = EditorHintsGatherer.start(
            enabled: false, boostEnabled: true, focus: focus("com.microsoft.VSCode", title: "a.swift - b - Visual Studio Code"),
            readers: calls.readers()
        )
        #expect(task == nil)
        #expect(calls.cursor == 0 && calls.document == 0)
    }

    @Test func needsTheSavedWordBoost() {
        let calls = ReaderCalls()
        #expect(EditorHintsGatherer.start(enabled: true, boostEnabled: false, focus: focus("com.apple.dt.Xcode"), readers: calls.readers()) == nil)
        #expect(calls.cursor == 0)
    }

    @Test func otherAppsAndSecureFieldsGatherNothing() {
        let calls = ReaderCalls()
        for bundle in ["com.apple.Safari", "com.tinyspeck.slackmacgap", nil] {
            #expect(EditorHintsGatherer.start(enabled: true, boostEnabled: true, focus: focus(bundle), readers: calls.readers()) == nil)
        }
        #expect(EditorHintsGatherer.start(enabled: true, boostEnabled: true, focus: focus("com.apple.dt.Xcode", secure: true), readers: calls.readers()) == nil)
        #expect(calls.cursor == 0 && calls.document == 0)
    }

    @Test func coversEditorsAndSupportedTerminals() {
        for bundle in ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode", "com.apple.Terminal",
                       "com.mitchellh.ghostty", "com.googlecode.iterm2", "net.kovidgoyal.kitty", "com.github.wez.wezterm"] {
            #expect(EditorHintsSurface.of(bundleID: bundle) != nil, "\(bundle)")
        }
        #expect(EditorHintsSurface.of(bundleID: "com.apple.finder") == nil)
    }

    @Test func gathersTitleAndCursorNamesInAnEditor() async throws {
        let calls = ReaderCalls()
        let context = InsertionContext(before: "func render() { applyTheme(", after: ")")
        let task = try #require(EditorHintsGatherer.start(
            enabled: true, boostEnabled: true,
            focus: focus("com.microsoft.VSCode", title: "DictationPipeline.swift - mouthtype - Visual Studio Code"),
            readers: calls.readers(context: context)
        ))
        let terms = await task.value
        #expect(terms.map(\.text) == ["applyTheme", "DictationPipeline", "mouthtype"])
        #expect(calls.cursor == 1)
    }

    @Test func terminalsNeverReadTheirScreenText() async throws {
        let calls = ReaderCalls()
        let context = InsertionContext(before: "secretCommandOutput", after: nil)
        let task = try #require(EditorHintsGatherer.start(
            enabled: true, boostEnabled: true, focus: focus("com.apple.Terminal"), readers: calls.readers(context: context)
        ))
        #expect(await task.value.isEmpty)
        #expect(calls.cursor == 0)
    }

    // MARK: Terminals and editors resolving a folder

    @Test func oneForegroundDirectoryWins() {
        let shell = TerminalWorkingDirectory.Entry(pid: 5, parent: 1, isForeground: true, hasTTY: true, started: 10, directory: "/Users/x/proj")
        let login = TerminalWorkingDirectory.Entry(pid: 4, parent: 1, isForeground: false, hasTTY: true, started: 9, directory: "/")
        #expect(TerminalWorkingDirectory.choose(from: [login, shell], windowTitle: nil)?.path == "/Users/x/proj")
    }

    @Test func severalTabsPreferTheTitleThenTheNewest() {
        let a = TerminalWorkingDirectory.Entry(pid: 5, parent: 1, isForeground: true, hasTTY: true, started: 10, directory: "/Users/x/alpha")
        let b = TerminalWorkingDirectory.Entry(pid: 6, parent: 1, isForeground: true, hasTTY: true, started: 20, directory: "/Users/x/beta")
        #expect(TerminalWorkingDirectory.choose(from: [a, b], windowTitle: "alpha - zsh")?.path == "/Users/x/alpha")
        #expect(TerminalWorkingDirectory.choose(from: [a, b], windowTitle: "zsh")?.path == "/Users/x/beta")
        #expect(TerminalWorkingDirectory.choose(from: [], windowTitle: nil) == nil)
    }

    @Test func descendantsFollowParentLinks() {
        let all = [
            TerminalWorkingDirectory.Entry(pid: 2, parent: 1, isForeground: true, hasTTY: true, started: 1, directory: nil),
            TerminalWorkingDirectory.Entry(pid: 3, parent: 2, isForeground: true, hasTTY: true, started: 2, directory: nil),
            TerminalWorkingDirectory.Entry(pid: 9, parent: 8, isForeground: true, hasTTY: true, started: 3, directory: nil),
        ]
        #expect(TerminalWorkingDirectory.descendants(of: 1, in: all).map(\.pid) == [2, 3])
    }

    @Test func workspaceFolderNeedsExactlyOneExistingMatch() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        let project = home.appendingPathComponent("code/mouthtype")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let storage = home.appendingPathComponent("Library/Application Support/Code/User/workspaceStorage")
        func entry(_ id: String, folder: String) throws {
            let dir = storage.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "{\"folder\": \"\(folder)\"}".write(to: dir.appendingPathComponent("workspace.json"), atomically: true, encoding: .utf8)
        }
        try entry("a", folder: project.absoluteString)
        try entry("b", folder: "vscode-remote://ssh/mouthtype")
        try entry("c", folder: home.appendingPathComponent("gone/mouthtype").absoluteString)
        #expect(WorkspaceFolder.resolve(supportFolder: "Code", projectName: "mouthtype", home: home)?.path == project.path)
        #expect(WorkspaceFolder.resolve(supportFolder: "Code", projectName: "other", home: home) == nil)

        let twin = home.appendingPathComponent("work/mouthtype")
        try FileManager.default.createDirectory(at: twin, withIntermediateDirectories: true)
        try entry("d", folder: twin.absoluteString)
        #expect(WorkspaceFolder.resolve(supportFolder: "Code", projectName: "mouthtype", home: home) == nil)
    }

    // MARK: Bias and history

    @Test func editorTermsFollowSavedOnesAndNeverDuplicateThem() {
        let rules = [DictionaryRule(heard: "mia", written: "Maya")]
        let editor = [VocabularyBias.Term(text: "maya"), VocabularyBias.Term(text: "applyTheme", aliases: ["apply theme"])]
        let bias = VocabularyBoostSetting.bias(enabled: true, rules: rules, editorTerms: editor)
        #expect(bias?.terms == ["Maya", "applyTheme"])
        #expect(bias?.entries.first?.aliases == ["mia"])
    }

    @Test func editorTermsOnlyFillWhatIsLeftOfTwoHundred() {
        let rules = (0..<190).map { DictionaryRule(heard: "heard \($0)", written: "Saved\($0)") }
        let editor = (0..<40).map { VocabularyBias.Term(text: "editorName\($0)") }
        let bias = VocabularyBoostSetting.bias(enabled: true, rules: rules, editorTerms: editor)
        #expect(bias?.entries.count == VocabularyBias.maxTerms)
        #expect(bias?.terms.prefix(190).allSatisfy { $0.hasPrefix("Saved") } == true)
    }

    @Test func offStaysOffEvenWithEditorTerms() {
        #expect(VocabularyBoostSetting.bias(enabled: false, rules: [], editorTerms: [.init(text: "applyTheme")]) == nil)
    }

    @Test func pipelineSendsEditorTermsAndKeepsThemOutOfHistory() async throws {
        let store = CapturingStore()
        let engine = EditorEngine(applied: ["Maya", "applyTheme"])
        var pipeline = DictationPipeline(store: store, archive: nil, engine: engine, clock: SystemDictationClock())
        pipeline.vocabulary = Rules(rules: [DictionaryRule(heard: "maya", written: "Maya")])
        pipeline.boostSavedWords = { true }
        let clock = SystemDictationClock()
        var session = DictationSession(id: "t", startedAt: clock.now(), keyDownAt: clock.nowNanos(), rowOpen: true)
        session.editorHints = Task { [VocabularyBias.Term(text: "applyTheme", aliases: ["apply theme"])] }
        let result = try #require(try await pipeline.transcribe(audio(), session: session, voicedMs: 1000))
        #expect(engine.seen.first??.terms == ["Maya", "applyTheme"])
        #expect(result.text == "hi Maya applyTheme")
        let record = try #require(store.transcription)
        #expect(record.boostTerms == ["Maya"])
    }

    @Test func historyIsNilWhenOnlyEditorTermsWereApplied() async throws {
        let store = CapturingStore()
        var pipeline = DictationPipeline(store: store, archive: nil, engine: EditorEngine(applied: ["applyTheme"]), clock: SystemDictationClock())
        pipeline.boostSavedWords = { true }
        let clock = SystemDictationClock()
        var session = DictationSession(id: "t", startedAt: clock.now(), keyDownAt: clock.nowNanos(), rowOpen: true)
        session.editorHints = Task { [VocabularyBias.Term(text: "applyTheme")] }
        _ = try await pipeline.transcribe(audio(), session: session, voicedMs: 1000)
        #expect(try #require(store.transcription).boostTerms == nil)
    }

    @Test func noHintsTaskLeavesTheBiasAndHistoryAlone() async throws {
        let store = CapturingStore()
        let engine = EditorEngine(applied: ["Maya"])
        var pipeline = DictationPipeline(store: store, archive: nil, engine: engine, clock: SystemDictationClock())
        pipeline.vocabulary = Rules(rules: [DictionaryRule(heard: "maya", written: "Maya")])
        pipeline.boostSavedWords = { true }
        let clock = SystemDictationClock()
        let session = DictationSession(id: "t", startedAt: clock.now(), keyDownAt: clock.nowNanos(), rowOpen: true)
        _ = try await pipeline.transcribe(audio(), session: session, voicedMs: 1000)
        #expect(engine.seen.first??.terms == ["Maya"])
        #expect(try #require(store.transcription).boostTerms == ["Maya"])
    }
}
