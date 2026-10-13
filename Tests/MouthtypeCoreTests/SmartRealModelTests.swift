import Foundation
import Testing
@testable import MouthtypeCore

/// The twelve acceptance dictations against the real S1-mini by Superwhisper, through the bench binary: MLX finds
/// its Metal library next to the executable it runs in, which the test host is not. Skipped when the model isn't
/// on disk.
@Suite(.serialized, .enabled(if: CleanerCatalog.makeSmartCleanup().isDownloaded, "S1-mini is not on disk"))
struct SmartRealModelTests {
    private func bench(_ arguments: [String]) throws -> (status: Int32, output: String) {
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

    @Test(arguments: ["light", "medium"])
    func theAcceptanceCasesPass(level: String) throws {
        let result = try bench(["clean", "--smart", level, "--smart-timeout-ms", "10000"])
        #expect(result.output.contains("12/12 cases pass the automatic checks at \(level)"), "\(result.output)")
        #expect(result.status == 0)
        #expect(!result.output.contains("outcome: guard-rejected") && !result.output.contains("outcome: timeout"), "\(result.output)")
    }
}
