import ArgumentParser
import Darwin
import Foundation
import MouthtypeCore

struct EngineWorker: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "engine-worker", shouldDisplay: false)

    @Argument var engine: String
    @Option var mode: String
    @Option var corpus: String = Corpus.defaultDirectory
    @Option var runs: Int = 5
    @Option var warmups: Int = 1
    @Option var result: String
    @Option(help: "Comma-separated names to bias recognition toward. Only engines that support it use them.") var boostTerms: String?
    @Flag(help: "Use the English hint enabled by the Mac app.") var englishHint = false

    func run() async throws {
        var output = WorkerOutput(engineID: engine, displayName: engine, prepare: nil, peakRSSBytes: 0, peakFootprintBytes: nil, firstTranscribeMs: nil, modelBytes: nil, modelPath: nil, clips: [], error: nil)
        do {
            let transcriber = try EngineCatalog.make(id: engine, englishHint: englishHint)
            output.displayName = transcriber.displayName
            if let measured = transcriber as? any MeasuredTranscriber {
                output.prepare = try await measured.prepareMeasured()
                output.modelPath = measured.modelDirectory.path
                output.modelBytes = Self.directorySize(measured.modelDirectory)
            } else {
                try await transcriber.prepare()
            }
            if let boostTerms, let biasing = transcriber as? any VocabularyBiasing {
                await biasing.setVocabularyBias(VocabularyBias(terms: boostTerms.split(separator: ",").map(String.init)))
            }
            if mode == "full" {
                let outcome = try await Self.benchmark(transcriber, corpus: URL(fileURLWithPath: corpus), runs: runs, warmups: warmups)
                output.clips = outcome.clips
                output.firstTranscribeMs = outcome.firstTranscribeMs
            }
        } catch {
            output.error = "\(error.localizedDescription)"
        }
        output.peakRSSBytes = Self.peakRSS()
        output.peakFootprintBytes = ProcessMemory.peakFootprintBytes()
        try JSONEncoder().encode(output).write(to: URL(fileURLWithPath: result))
    }

    static func benchmark(
        _ transcriber: any Transcriber, corpus: URL, runs: Int, warmups: Int
    ) async throws -> (clips: [ClipResult], firstTranscribeMs: Double?) {
        let clock = ContinuousClock()
        var results: [ClipResult] = []
        var firstTranscribeMs: Double?
        for clip in try Corpus.load(directory: corpus) {
            let samples = try AudioLoading.loadSamples(from: clip.audioURL)
            let audioSeconds = Double(samples.count) / AudioLoading.targetSampleRate
            for _ in 0..<warmups {
                let start = clock.now
                _ = try await transcriber.transcribe(samples: samples)
                if firstTranscribeMs == nil { firstTranscribeMs = (clock.now - start).seconds * 1000 }
            }
            var latencies: [Double] = []
            var hypothesis = ""
            for _ in 0..<runs {
                let start = clock.now
                hypothesis = try await transcriber.transcribe(samples: samples).text
                latencies.append((clock.now - start).seconds * 1000)
            }
            let median = Stats.median(latencies)
            let counts = TextMetrics.errorCounts(reference: clip.reference, hypothesis: hypothesis)
            results.append(ClipResult(
                name: clip.name,
                set: ClipSet(clipName: clip.name),
                audioSeconds: audioSeconds,
                latenciesMs: latencies,
                medianMs: median,
                p95Ms: Stats.percentile(latencies, 95),
                rtfx: median > 0 ? audioSeconds / (median / 1000) : 0,
                reference: clip.reference,
                hypothesis: hypothesis,
                edits: counts.edits,
                referenceWords: counts.referenceWords
            ))
        }
        return (results, firstTranscribeMs)
    }

    static func peakRSS() -> Int {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int(usage.ru_maxrss)
    }

    static func directorySize(_ url: URL) -> Int? {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
        ) else { return nil }
        var total = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += values?.totalFileAllocatedSize ?? 0
            }
        }
        return total > 0 ? total : nil
    }
}
