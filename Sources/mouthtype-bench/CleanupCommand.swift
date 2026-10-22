import ArgumentParser
import Foundation
import MouthtypeCore

struct CleanupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleanup",
        abstract: "Benchmark text-cleanup models and write a report."
    )

    @Option(help: "Comma-separated cleaner ids. Default: all.") var cleaners: String?
    @Option(help: "Timed runs per case.") var runs: Int = 3
    @Option(help: "Report output directory.") var out: String = "docs/benchmarks"
    @Flag(help: "Grade outputs with Claude Sonnet through the claude CLI.") var judge = false

    private static let coldTimeout: TimeInterval = 20 * 60
    private static let warmTimeout: TimeInterval = 90 * 60
    private static let minimumFreeBytes: Int64 = 25 * 1_073_741_824

    func run() async throws {
        let ids =
            cleaners.map { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
            ?? CleanerCatalog.ids
        for id in ids { _ = try CleanerCatalog.make(id: id) }
        let cases = try CleanupFixtures.load()

        if let free = Self.freeDiskBytes(), free < Self.minimumFreeBytes {
            throw ValidationError("Only \(free / 1_073_741_824) GB free in the home volume. Model downloads need at least 25 GB.")
        }

        guard let executable = Bundle.main.executableURL else {
            throw ValidationError("Cannot locate the bench executable to spawn workers")
        }
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let logDir = URL(fileURLWithPath: "bench-cache/logs")

        var reports: [CleanerReport] = []
        for id in ids {
            var report = CleanerReport(
                cleanerID: id, displayName: id, status: "ok", statusDetail: nil, cold: nil, warm: nil,
                timingsComparable: true, buckets: [:], tokensPerSecondMedian: nil, passRate: nil,
                categoryPassRates: [:], failures: [], judge: nil)
            print("[\(id)] cold prepare in a fresh process (download + load)")
            let cold = await runWorker(executable, id: id, mode: "prepare", timeout: Self.coldTimeout, tempDir: tempDir, logDir: logDir)
            report.cold = cold.output
            report.displayName = cold.output?.displayName ?? id
            if let unavailable = cold.output?.unavailable {
                report.status = "unavailable"
                report.statusDetail = unavailable
            } else if let error = cold.error {
                report.status = "failed"
                report.statusDetail = "cold prepare: \(error)"
            } else {
                print("[\(id)] warm run in a fresh process: \(runs) timed runs per case")
                let warm = await runWorker(executable, id: id, mode: "full", timeout: Self.warmTimeout, tempDir: tempDir, logDir: logDir)
                report.warm = warm.output
                if let error = warm.error {
                    report.status = "failed"
                    report.statusDetail = "benchmark run: \(error)"
                }
            }
            CleanupReportBuilder.aggregate(&report, cases: cases)
            print("[\(id)] \(report.status)\(report.statusDetail.map { ": \($0)" } ?? "")")
            reports.append(report)
        }

        var judgeStatus = JudgeStatus(requested: judge, ran: false, model: Judge.model, note: nil)
        if judge {
            if ClaudeCLI.locate() == nil {
                judgeStatus.note = "Judging skipped: the claude CLI was not found on PATH."
            } else {
                do {
                    try await applyJudge(to: &reports, cases: cases)
                    judgeStatus.ran = true
                } catch {
                    judgeStatus.note = "Judging failed: \(error.localizedDescription)"
                }
            }
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let machine = Machine.collect()
        let report = CleanupBenchReport(
            date: formatter.string(from: Date()),
            machine: machine,
            runsPerCase: runs,
            caseCount: cases.count,
            categories: Dictionary(grouping: cases, by: \.category).mapValues(\.count),
            judge: judgeStatus,
            parakeetShortMs: CleanupReportBuilder.parakeetShortMs(in: URL(fileURLWithPath: out, isDirectory: true)),
            cleaners: reports
        )

        let outDir = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let base = outDir.appendingPathComponent("\(report.date)-\(Machine.slug(machine.chip))-cleanup")
        try CleanupReportBuilder.markdown(report, cases: cases).write(to: base.appendingPathExtension("md"), atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: base.appendingPathExtension("json"))
        print("Wrote \(base.path).md and .json")
    }

    private func applyJudge(to reports: inout [CleanerReport], cases: [CleanupCase]) async throws {
        let byID = Dictionary(uniqueKeysWithValues: cases.map { ($0.id, $0) })
        var items: [JudgeItem] = []
        for report in reports {
            for run in report.warm?.cases ?? [] where run.error == nil {
                if let testCase = byID[run.id] { items.append(JudgeItem(testCase: testCase, output: run.output)) }
            }
        }
        let cache = try await Judge.grade(items, cache: Judge.loadCache())
        for index in reports.indices {
            guard let runs = reports[index].warm?.cases, !runs.isEmpty else { continue }
            var total = 0.0
            var graded = 0
            var missing = 0
            for run in runs {
                guard run.error == nil, let testCase = byID[run.id] else {
                    graded += 1
                    continue
                }
                if let judgment = cache[JudgeItem(testCase: testCase, output: run.output).cacheKey] {
                    total += Double(judgment.total)
                    graded += 1
                } else {
                    missing += 1
                }
            }
            reports[index].judge = JudgeSummary(
                meanScore: graded > 0 ? total / Double(graded) : 0, graded: graded, missing: missing)
        }
    }

    private func runWorker(
        _ executable: URL, id: String, mode: String, timeout: TimeInterval, tempDir: URL, logDir: URL
    ) async -> (output: CleanupWorkerOutput?, error: String?) {
        let resultURL = tempDir.appendingPathComponent("\(id)-\(mode).json")
        let logURL = logDir.appendingPathComponent("cleanup-\(id)-\(mode).log")
        let arguments = ["cleanup-worker", id, "--mode", mode, "--runs", String(runs), "--result", resultURL.path]
        do {
            let outcome = try await runChild(executable: executable, arguments: arguments, logURL: logURL, timeout: timeout)
            if outcome.timedOut {
                return (nil, "failed by timeout after \(Int(timeout / 60)) minutes")
            }
            guard let data = try? Data(contentsOf: resultURL),
                let output = try? JSONDecoder().decode(CleanupWorkerOutput.self, from: data)
            else {
                return (nil, "worker exited with status \(outcome.exitStatus) without a result. Log tail:\n\(outcome.logTail)")
            }
            return (output, output.error)
        } catch {
            return (nil, "could not run worker: \(error.localizedDescription)")
        }
    }

    private static func freeDiskBytes() -> Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
