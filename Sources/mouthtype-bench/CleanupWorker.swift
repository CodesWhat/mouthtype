import ArgumentParser
import Foundation
import MouthtypeCore

struct CleanupWorker: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cleanup-worker", shouldDisplay: false)

    @Argument var cleaner: String
    @Option var mode: String
    @Option var runs: Int = 3
    @Option var result: String

    func run() async throws {
        var output = CleanupWorkerOutput(
            cleanerID: cleaner, displayName: cleaner, prepare: nil, peakFootprintBytes: 0, firstCleanMs: nil,
            modelBytes: nil, modelPath: nil, timingsRepresentative: true, usesSharedPrompt: true, license: nil,
            cases: [], unavailable: nil, error: nil)
        do {
            let instance = try CleanerCatalog.make(id: cleaner)
            output.displayName = instance.displayName
            output.timingsRepresentative = instance.timingsAreRepresentative
            output.usesSharedPrompt = instance.usesSharedPrompt
            output.license = instance.license
            output.prepare = try await instance.prepareMeasured()
            if let directory = instance.modelDirectory {
                output.modelPath = (directory.path as NSString).abbreviatingWithTildeInPath
                output.modelBytes = EngineWorker.directorySize(directory)
            }
            if mode == "full" {
                let cases = try CleanupFixtures.load()
                let outcome = await Self.benchmark(instance, cases: cases, runs: instance.timingsAreRepresentative ? runs : 1)
                output.cases = outcome.cases
                output.firstCleanMs = outcome.firstCleanMs
            }
        } catch let error as CleanerError {
            if case let .unavailable(reason) = error {
                output.unavailable = reason
            } else {
                output.error = error.localizedDescription
            }
        } catch {
            output.error = error.localizedDescription
        }
        output.peakFootprintBytes = ProcessMemory.peakFootprintBytes()
        try JSONEncoder().encode(output).write(to: URL(fileURLWithPath: result))
    }

    static func benchmark(
        _ cleaner: any MeasuredCleaner, cases: [CleanupCase], runs: Int
    ) async -> (cases: [CaseRun], firstCleanMs: Double?) {
        var firstCleanMs: Double?
        if cleaner.timingsAreRepresentative, let warmup = cases.first {
            let clock = ContinuousClock()
            let start = clock.now
            _ = try? await cleaner.cleanMeasured(warmup.input, context: CleanupContext(vocabulary: warmup.vocabulary, appName: warmup.appName))
            firstCleanMs = (clock.now - start).seconds * 1000
        }
        var results: [CaseRun] = []
        for testCase in cases {
            let context = CleanupContext(vocabulary: testCase.vocabulary, appName: testCase.appName)
            var run = CaseRun(id: testCase.id, output: "", error: nil, firstOutputMs: [], totalMs: [], outputTokens: nil, tokensPerSecond: nil)
            var rates: [Double] = []
            for _ in 0..<max(runs, 1) {
                do {
                    let result = try await cleaner.cleanMeasured(testCase.input, context: context)
                    run.output = result.text
                    run.firstOutputMs.append(result.firstOutputSeconds * 1000)
                    run.totalMs.append(result.totalSeconds * 1000)
                    run.outputTokens = result.outputTokens
                    if let tokens = result.outputTokens, let seconds = result.generationSeconds, seconds > 0, tokens > 1 {
                        rates.append(Double(tokens) / seconds)
                    }
                } catch {
                    run.error = error.localizedDescription
                    break
                }
            }
            run.tokensPerSecond = rates.isEmpty ? nil : Stats.median(rates)
            results.append(run)
            print("[\(cleaner.id)] \(testCase.id) \(run.error.map { "error: \($0)" } ?? "ok")")
        }
        return (results, firstCleanMs)
    }
}
