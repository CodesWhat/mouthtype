import ArgumentParser
import Foundation
import MouthtypeCore

@main
struct MouthtypeBench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mouthtype-bench",
        abstract: "Benchmark Mouthtype speech engines and text-cleanup models.",
        subcommands: [List.self, Run.self, CleanupCommand.self, CorpusCommand.self, EngineWorker.self, CleanupWorker.self]
    )
}

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the engine catalog.")

    func run() {
        for entry in EngineCatalog.entries {
            print("\(entry.id)\t\(entry.displayName)")
        }
    }
}

struct CorpusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "corpus",
        abstract: "Generate the built-in benchmark corpus (say clips plus LibriSpeech test-clean utterances)."
    )

    @Option(help: "Output directory.") var out: String = Corpus.defaultDirectory

    func run() async throws {
        let realFetched = try await Corpus.build(into: URL(fileURLWithPath: out))
        let clips = try Corpus.load(directory: URL(fileURLWithPath: out))
        print("Corpus at \(out): \(clips.count) clips\(realFetched ? "" : " (synthetic only)")")
    }
}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Benchmark engines and write a report.")

    @Option(help: "Comma-separated engine ids. Default: all.") var engines: String?
    @Option(help: "Corpus directory of audio files with same-basename .txt references.") var corpus: String = Corpus.defaultDirectory
    @Option(help: "Timed runs per clip.") var runs: Int = 5
    @Option(help: "Report output directory.") var out: String = "docs/benchmarks"

    private static let warmups = 1
    private static let coldTimeout: TimeInterval = 20 * 60
    private static let warmTimeout: TimeInterval = 45 * 60

    func run() async throws {
        let ids = engines.map { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
            ?? EngineCatalog.ids
        for id in ids { _ = try EngineCatalog.make(id: id) }

        let corpusURL = URL(fileURLWithPath: corpus)
        if corpus == Corpus.defaultDirectory, !FileManager.default.fileExists(atPath: corpusURL.path) {
            try await Corpus.build(into: corpusURL)
        }
        let clips = try Corpus.load(directory: corpusURL)
        let hasReal = clips.contains { ClipSet(clipName: $0.name) == .real }
        if !hasReal {
            FileHandle.standardError.write(Data("WARNING: corpus has no real speech clips (real-*). WER will be TTS-only.\n".utf8))
        }

        guard let executable = Bundle.main.executableURL else {
            throw ValidationError("Cannot locate the bench executable to spawn workers")
        }
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let logDir = URL(fileURLWithPath: "bench-cache/logs")

        var reports: [EngineReport] = []
        for id in ids {
            var report = EngineReport(engineID: id, displayName: id)
            print("[\(id)] cold prepare in a fresh process (download + CoreML compile can take minutes)")
            let cold = await runWorker(executable, id: id, mode: "prepare", timeout: Self.coldTimeout, tempDir: tempDir, logDir: logDir)
            report.cold = cold.output
            report.displayName = cold.output?.displayName ?? id
            if let error = cold.error {
                report.error = "cold prepare: \(error)"
            } else {
                print("[\(id)] warm run in a fresh process: \(runs) timed runs per clip")
                let warm = await runWorker(executable, id: id, mode: "full", timeout: Self.warmTimeout, tempDir: tempDir, logDir: logDir)
                report.warm = warm.output
                if let error = warm.error { report.error = "benchmark run: \(error)" }
            }
            Report.aggregate(&report)
            print("[\(id)] \(report.error.map { "FAILED: \($0)" } ?? "done")")
            reports.append(report)
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let machine = Machine.collect()
        let report = BenchReport(
            date: formatter.string(from: Date()),
            machine: machine,
            corpus: corpus,
            runsPerClip: runs,
            warmupRuns: Self.warmups,
            hasRealSpeech: hasReal,
            engines: reports
        )

        let outDir = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let base = outDir.appendingPathComponent("\(report.date)-\(Machine.slug(machine.chip))")
        try Report.markdown(report).write(to: base.appendingPathExtension("md"), atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: base.appendingPathExtension("json"))
        print("Wrote \(base.path).md and .json")
    }

    private func runWorker(
        _ executable: URL, id: String, mode: String, timeout: TimeInterval, tempDir: URL, logDir: URL
    ) async -> (output: WorkerOutput?, error: String?) {
        let resultURL = tempDir.appendingPathComponent("\(id)-\(mode).json")
        let logURL = logDir.appendingPathComponent("\(id)-\(mode).log")
        let arguments = [
            "engine-worker", id, "--mode", mode, "--corpus", corpus,
            "--runs", String(runs), "--warmups", String(Self.warmups), "--result", resultURL.path,
        ]
        do {
            let outcome = try await runChild(executable: executable, arguments: arguments, logURL: logURL, timeout: timeout)
            if outcome.timedOut {
                return (nil, "failed by timeout after \(Int(timeout / 60)) minutes")
            }
            guard let data = try? Data(contentsOf: resultURL),
                  let output = try? JSONDecoder().decode(WorkerOutput.self, from: data)
            else {
                return (nil, "worker exited with status \(outcome.exitStatus) without a result. Log tail:\n\(outcome.logTail)")
            }
            return (output, output.error)
        } catch {
            return (nil, "could not run worker: \(error.localizedDescription)")
        }
    }
}
