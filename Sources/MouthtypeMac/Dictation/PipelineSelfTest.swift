import AppKit
import Foundation
import MouthtypeCore

/// `--pipeline-selftest <audio file>`: run the post-capture path on a file against a temporary database and
/// archive, log one line (category `selftest`), quit. Needs no permissions; skips capture and paste.
@MainActor
enum PipelineSelfTest {
    static let flag = "--pipeline-selftest"
    static let engineTimeout: Duration = .seconds(600)

    static func path(in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    static func run(path: String, engineHost: EngineHost) async {
        do {
            let samples = try AudioLoading.loadSamples(from: URL(fileURLWithPath: path))
            try await waitForEngine(engineHost)

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("mouthtype-pipeline-selftest-\(UUID().uuidString)", isDirectory: true)
            let databaseURL = directory.appendingPathComponent("mouthtype.sqlite")
            let archive = AudioArchive(supportDirectory: directory)
            let clock = SystemDictationClock()
            let pipeline = DictationPipeline(
                store: TranscriptStoreWriter(store: try TranscriptStore(url: databaseURL)), archive: archive,
                engine: HostEngine(host: engineHost), clock: clock
            )

            let audioMs = Double(samples.count) * 1000 / AudioCapture.targetSampleRate
            let audio = CapturedAudio(
                samples: samples, sampleRate: AudioCapture.targetSampleRate, deviceUID: nil, deviceName: "file",
                deviceTransport: "file", firstSampleMs: 0, firstNonzeroMs: 0, captureStartMs: 0, audioMs: audioMs
            )
            let keyDownAt = clock.nowNanos()
            var session = DictationSession(id: UUID().uuidString, startedAt: clock.now(), keyDownAt: keyDownAt)
            session.rowOpen = await pipeline.begin(session, target: DictationTarget(appName: "pipeline-selftest"))

            let features = await pipeline.recordCapture(audio, session: session, keyUpMs: Int(audioMs.rounded()))
            let transcribed = try await pipeline.transcribe(audio, session: session)
            if let transcribed {
                let result = DeliveryResult(
                    method: .none, outcome: .unknown, focusMoved: false, target: nil, finalText: transcribed.text
                )
                await pipeline.recordInsertion(result, session: session)
            }

            let words = transcribed?.words ?? []
            let monotonic = zip(words, words.dropFirst()).allSatisfy { $0.start <= $1.start }
                && words.allSatisfy { $0.start <= $0.end }
            let lastEnd = words.last?.end ?? 0
            let text = transcribed?.text ?? ""
            let line = "pipeline selftest transcript=\"\(text)\" words=\(TranscriptStore.wordCount(text))"
                + " timings=\(words.count) monotonic=\(monotonic) lastEndS=\(String(format: "%.2f", lastEnd))"
                + " clipS=\(String(format: "%.2f", audioMs / 1000)) asrMs=\(transcribed?.asrDoneMs.description ?? "none")"
                + " voicedMs=\(Int(features.voicedMs.rounded())) db=\(databaseURL.path) archive=\(archive.directory.path)"
            Log.selftest.info("\(line, privacy: .public)")
        } catch {
            Log.selftest.error("pipeline selftest failed: \(String(describing: error), privacy: .public)")
        }
        NSApp.terminate(nil)
    }

    private static func waitForEngine(_ host: EngineHost) async throws {
        let deadline = ContinuousClock.now + engineTimeout
        while ContinuousClock.now < deadline {
            switch host.state {
            case .ready: return
            case let .failed(message): throw SelfTestError.engineFailed(message)
            case .loading: try await Task.sleep(for: .milliseconds(200))
            }
        }
        throw SelfTestError.engineTimeout
    }

    enum SelfTestError: Error {
        case engineFailed(String)
        case engineTimeout
    }
}
