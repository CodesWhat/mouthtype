import Foundation
import Testing
@testable import MouthtypeCore

private func cleanupBench(_ arguments: [String]) throws -> (status: Int32, output: String) {
    let bundlePath = try #require(CommandLine.arguments.first { $0.contains(".xctest") })
    var products = URL(fileURLWithPath: bundlePath)
    while products.pathExtension != "xctest", products.path != "/" { products.deleteLastPathComponent() }
    products.deleteLastPathComponent()
    let process = Process()
    process.executableURL = products.appendingPathComponent("mouthtype-bench")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}


/// The nineteen acceptance dictations against the real S1-mini by Superwhisper, through the bench binary: MLX finds
/// its Metal library next to the executable it runs in, which the test host is not. Skipped when the model isn't
/// on disk.
@Suite(.serialized, .enabled(if: ((try? CleanerCatalog.make(id: "superwhisper-s1-mini")) as? MLXCleaner)?.isDownloaded == true, "S1-mini is not on disk"))
struct SmartRealModelTests {
    @Test(arguments: ["light", "medium"])
    func theAcceptanceCasesPass(level: String) throws {
        let result = try cleanupBench(["clean", "--smart", level, "--cleaner", "superwhisper-s1-mini", "--smart-timeout-ms", "10000"])
        #expect(result.output.contains("19/19 cases pass the automatic checks at \(level)"), "\(result.output)")
        #expect(result.status == 0)
        #expect(!result.output.contains("outcome: guard-rejected") && !result.output.contains("outcome: timeout"), "\(result.output)")
    }
}

@Suite(.serialized, .enabled(if: CleanerCatalog.makeSmartCleanup().isDownloaded, "Quality cleanup model is not on disk"))
struct QualityRealModelTests {
    @Test func longReadThroughKeepsMeaningAndRemovesRestarts() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = root.appendingPathComponent("Tests/Fixtures/long-read-through.json")
        let result = try cleanupBench(["clean", "--smart", "light", "--file", fixtures.path, "--smart-timeout-ms", "10000"])
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("1/1 cases pass"), "\(result.output)")
        #expect(!result.output.contains("outcome: timeout"), "\(result.output)")
    }

    @Test(arguments: ["light", "medium"])
    func projectJoiningPreservesOrdinaryNouns(level: String) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = root.appendingPathComponent("Tests/Fixtures/project-name-joining.json")
        let result = try cleanupBench(["clean", "--smart", level, "--file", fixtures.path, "--smart-timeout-ms", "10000"])
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("12/12 cases pass"), "\(result.output)")
    }

    @Test(arguments: ["light", "medium"])
    func correctionsSurviveRecognitionSentenceBreaks(level: String) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = root.appendingPathComponent("Tests/Fixtures/sentence-corrections.json")
        let result = try cleanupBench(["clean", "--smart", level, "--file", fixtures.path, "--smart-timeout-ms", "10000"])
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("3/3 cases pass"), "\(result.output)")
    }

    @Test(arguments: ["light", "medium"])
    func clockCorrectionsPreserveMeaning(level: String) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = root.appendingPathComponent("Tests/Fixtures/cleanup-corrections.json")
        let result = try cleanupBench(["clean", "--smart", level, "--file", fixtures.path, "--smart-timeout-ms", "10000"])
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("4/4 cases pass the automatic checks at \(level)"), "\(result.output)")
        #expect(!result.output.contains("outcome: timeout"), "\(result.output)")
    }
}
