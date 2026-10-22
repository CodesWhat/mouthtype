import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

private actor ImportGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { entered = true; await withCheckedContinuation { waiter = $0 } }
    func release() { waiter?.resume(); waiter = nil }
}
private struct ImportDecoder: AudioFileDecoding {
    func decode(_ url: URL, limits: AudioFileLimits) async throws -> DecodedAudioFile {
        DecodedAudioFile(samples: [0.1, 0.2], durationSeconds: 1)
    }
}
private struct ImportEngine: Transcriber {
    let id = "test", displayName = "Test"
    let gate: ImportGate?
    var text = "Émilie 世界 👋\nSecond line."
    func prepare() async throws { Issue.record("Unexpected preparation") }
    func transcribe(samples: [Float]) async throws -> Transcription {
        await gate?.wait()
        return Transcription(text: text, processingSeconds: 0, engineID: id)
    }
}

@MainActor @Suite struct FileTranscriptionModelTests {
    private func settled(_ model: FileTranscriptionModel) async {
        for _ in 0..<500 where model.isBusy { await Task.yield() }
    }
    @Test func successfulImportNeverCopiesUntilExplicitActionAndExportsExactUnicode() async throws {
        var copies: [String] = []
        let engine = ImportEngine(gate: nil)
        let model = FileTranscriptionModel(makeJob: { AudioFileTranscription(decoder: ImportDecoder(), engine: engine) }, copy: { copies.append($0) })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.wav")
        let originalData = Data("original contents".utf8)
        try originalData.write(to: original)
        model.start(original)
        await settled(model)
        #expect(model.state == .finished)
        #expect(model.text == engine.text)
        #expect(copies.isEmpty)
        model.copy()
        #expect(copies == [engine.text])
        let exported = root.appendingPathComponent("transcript.txt")
        try model.save(to: exported)
        #expect(try Data(contentsOf: exported) == Data(engine.text.utf8))
        #expect(throws: (any Error).self) { try model.save(to: original) }
        #expect(try Data(contentsOf: original) == originalData)
    }
    @Test func cancellingHoldsActivityUntilUnderlyingInferenceSettles() async {
        let gate = ImportGate()
        let job = AudioFileTranscription(decoder: ImportDecoder(), engine: ImportEngine(gate: gate))
        let model = FileTranscriptionModel(makeJob: { job }, copy: { _ in Issue.record("Unexpected clipboard action") })
        model.start(URL(fileURLWithPath: "/audio.wav"))
        for _ in 0..<200 where await !gate.entered { await Task.yield() }
        #expect(model.isBusy)
        model.cancel()
        #expect(model.state == .cancelling)
        #expect(model.isBusy)
        await gate.release()
        await settled(model)
        #expect(model.state == .cancelled)
        #expect(model.text.isEmpty)
        #expect(!model.isBusy)
    }
    @Test func busyAppDoesNotCreateJobAndEmptySpeechIsTruthful() async {
        var jobs = 0
        let blocked = FileTranscriptionModel(
            makeJob: {
                jobs += 1; throw AudioFileError.busy
            }, canBegin: { false }, copy: { _ in })
        blocked.start(URL(fileURLWithPath: "/audio.wav"))
        #expect(jobs == 0)
        #expect(blocked.state == .failed)
        let model = FileTranscriptionModel(makeJob: { AudioFileTranscription(decoder: ImportDecoder(), engine: ImportEngine(gate: nil, text: "")) }, copy: { _ in Issue.record("Empty speech copied") })
        model.start(URL(fileURLWithPath: "/audio.wav"))
        await settled(model)
        #expect(model.state == .empty)
        #expect(!model.hasResult)
        model.copy()
    }
    @Test func failedExportKeepsResultAndSourceAliasesAreRefused() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.wav")
        try Data("unchanged".utf8).write(to: source)
        let alias = root.appendingPathComponent("alias.txt")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        var activityChanges = 0
        let model = FileTranscriptionModel(
            makeJob: { AudioFileTranscription(decoder: ImportDecoder(), engine: ImportEngine(gate: nil)) },
            activityChanged: { activityChanges += 1 }, copy: { _ in })
        model.start(source)
        await settled(model)
        #expect(activityChanges == 2 && !model.isBusy)
        #expect(throws: AudioFileError.cannotReplaceSource) { try model.save(to: alias) }
        #expect(throws: (any Error).self) { try model.save(to: root.appendingPathComponent("missing/result.txt")) }
        #expect(model.state == .finished && model.hasResult)
        #expect(try Data(contentsOf: source) == Data("unchanged".utf8))
    }

    @Test func failedImportKeepsThePreviousResultAndNamesTheFileThatFailed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let good = root.appendingPathComponent("good.wav"), bad = root.appendingPathComponent("bad.wav")
        try Data(count: 2048).write(to: good)
        try Data(count: 10).write(to: bad)
        let model = FileTranscriptionModel(makeJob: { AudioFileTranscription(decoder: FlakyDecoder(), engine: ImportEngine(gate: nil)) }, copy: { _ in })
        model.start(good)
        await settled(model)
        #expect(model.state == .finished && model.fileSize == 2048 && model.duration == 1)
        let kept = model.text
        model.start(bad)
        await settled(model)
        #expect(model.state == .failed && model.text == kept && model.filename == "good.wav")
        #expect(model.failedFilename == "bad.wav" && model.fileSize == 2048 && model.errorMessage == AudioFileError.invalidAudio.errorDescription)
        #expect(model.wordCount == TextMetrics.wordCount(kept))
        model.start(good)
        await settled(model)
        #expect(model.state == .finished && model.failedFilename == nil)
    }
}

private struct FlakyDecoder: AudioFileDecoding {
    func decode(_ url: URL, limits: AudioFileLimits) async throws -> DecodedAudioFile {
        if url.lastPathComponent == "bad.wav" { throw AudioFileError.invalidAudio }
        return DecodedAudioFile(samples: [0.1, 0.2], durationSeconds: 1)
    }
}
