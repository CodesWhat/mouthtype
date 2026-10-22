import AppKit
import Foundation
import MouthtypeCore

/// Debug arguments for the model pass in a self-test: `--cleanup-level <off|basic|light|medium>` overrides the
/// stored level and `--smart-timeout-ms <n>` replaces the word-based time budget.
enum SmartTestOptions {
    static func level(in arguments: [String]) -> CleanupLevel? {
        value(of: "--cleanup-level", in: arguments).flatMap(CleanupLevel.init(rawValue:))
    }

    static func modelLevel(in arguments: [String], saved: CleanupLevel) -> CleanupLevel {
        arguments.contains("--pipeline-selftest") ? level(in: arguments) ?? saved : saved
    }

    static func budget(in arguments: [String]) -> (@Sendable (Int) -> Duration)? {
        guard let ms = value(of: "--smart-timeout-ms", in: arguments).flatMap(Int.init) else { return nil }
        return { _ in .milliseconds(ms) }
    }

    private static func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

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

    static func run(path: String, engineHost: EngineHost, cleanerHost: any CleanupModelManaging) async {
        do {
            let samples = try AudioLoading.loadSamples(from: URL(fileURLWithPath: path))
            try await waitForEngine(engineHost)

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("mouthtype-pipeline-selftest-\(UUID().uuidString)", isDirectory: true)
            let databaseURL = directory.appendingPathComponent("mouthtype.sqlite")
            let archive = AudioArchive(supportDirectory: directory)
            let clock = SystemDictationClock()
            var pipeline = DictationPipeline(
                store: TranscriptStoreWriter(store: try TranscriptStore(url: databaseURL)), archive: archive,
                engine: HostEngine(host: engineHost), clock: clock
            )
            if let level = SmartTestOptions.level(in: CommandLine.arguments) {
                pipeline.settings = {
                    var settings = CleanupSettings.load(); settings.level = level; return settings
                }
            }
            pipeline.smart = cleanerHost
            if pipeline.settings().level.needsModel { try await waitForCleaner(cleanerHost) }

            let audioMs = Double(samples.count) * 1000 / AudioCapture.targetSampleRate
            let audio = CapturedAudio(
                samples: samples, sampleRate: AudioCapture.targetSampleRate, deviceUID: nil, deviceName: "file",
                deviceTransport: "file", firstSampleMs: 0, firstNonzeroMs: 0, captureStartMs: 0, audioMs: audioMs
            )
            let keyDownAt = clock.nowNanos()
            var session = DictationSession(id: UUID().uuidString, startedAt: clock.now(), keyDownAt: keyDownAt)
            session.rowOpen = await pipeline.begin(session, target: DictationTarget(appName: "pipeline-selftest"))

            let features = await pipeline.recordCapture(audio, session: session, keyUpMs: Int(audioMs.rounded()))
            let transcribed = try await pipeline.transcribe(audio, session: session, voicedMs: features.voicedMs)
            var cleanedText = ""
            if let transcribed {
                let cleaned = await pipeline.clean(transcribed, inputs: pipeline.cleanupInputs(), context: nil, clipboard: nil)
                cleanedText = cleaned.text
                let result = DeliveryResult(
                    method: .none, outcome: .unknown, focusMoved: false, target: nil, finalText: cleaned.text
                )
                await pipeline.recordInsertion(result, session: session, cleaned: cleaned)
            }

            let words = transcribed?.words ?? []
            let monotonic =
                zip(words, words.dropFirst()).allSatisfy { $0.start <= $1.start }
                && words.allSatisfy { $0.start <= $0.end }
            let lastEnd = words.last?.end ?? 0
            let text = transcribed?.rawText ?? ""
            let line =
                "pipeline selftest transcript=\"\(text)\" cleaned=\"\(cleanedText.replacingOccurrences(of: "\n", with: "\\n"))\""
                + " words=\(TextMetrics.wordCount(text))"
                + " timings=\(words.count) monotonic=\(monotonic) lastEndS=\(String(format: "%.2f", lastEnd))"
                + " clipS=\(String(format: "%.2f", audioMs / 1000)) asrMs=\(transcribed?.asrDoneMs.description ?? "none")"
                + " voicedMs=\(Int(features.voicedMs.rounded())) db=\(databaseURL.path) archive=\(archive.directory.path)"
            Log.selftest.info("\(line, privacy: .public)")
            Log.selftest.info("pipeline selftest cleaner=\(String(describing: cleanerHost.state), privacy: .public)")
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

    /// Waits for the model to load, or gives up when it isn't on disk or fails; the cleanup then runs as basic.
    private static func waitForCleaner(_ host: any CleanupModelManaging) async throws {
        let deadline = ContinuousClock.now + engineTimeout
        while ContinuousClock.now < deadline {
            switch host.state {
            case .ready, .absent, .failed: return
            default: try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    enum SelfTestError: Error {
        case engineFailed(String)
        case engineTimeout
    }
}
