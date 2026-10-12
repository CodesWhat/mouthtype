import Foundation
import MouthtypeCore

enum CleanupReportBuilder {
    static let buildCommand = "swift build -c release --product mouthtype-bench && .build/release/mouthtype-bench cleanup --judge"

    static func aggregate(_ report: inout CleanerReport, cases: [CleanupCase]) {
        guard let warm = report.warm, !warm.cases.isEmpty else { return }
        report.timingsComparable = warm.timingsRepresentative
        let byID = Dictionary(uniqueKeysWithValues: cases.map { ($0.id, $0) })

        var firstSamples: [LengthBucket: [Double]] = [:]
        var totalSamples: [LengthBucket: [Double]] = [:]
        var rates: [Double] = []
        var passes = 0
        var categoryPasses: [String: Int] = [:]
        var categoryTotals: [String: Int] = [:]
        var failures: [CaseFailure] = []

        for run in warm.cases {
            guard let testCase = byID[run.id] else { continue }
            let bucket = LengthBucket(wordCount: TextMetrics.wordCount(testCase.input))
            if run.error == nil {
                firstSamples[bucket, default: []] += run.firstOutputMs
                totalSamples[bucket, default: []] += run.totalMs
            }
            if let rate = run.tokensPerSecond { rates.append(rate) }

            categoryTotals[testCase.category, default: 0] += 1
            let reasons = run.error.map { ["error: \($0)"] } ?? CleanupChecker.failures(for: testCase, output: run.output)
            if reasons.isEmpty {
                passes += 1
                categoryPasses[testCase.category, default: 0] += 1
            } else {
                failures.append(CaseFailure(caseID: testCase.id, category: testCase.category, input: testCase.input, output: run.output, reasons: reasons))
            }
        }

        for bucket in LengthBucket.allCases {
            guard let first = firstSamples[bucket], let total = totalSamples[bucket], !total.isEmpty else { continue }
            report.buckets[bucket.rawValue] = BucketTiming(
                samples: total.count,
                firstMedianMs: Stats.median(first), firstP95Ms: Stats.percentile(first, 95),
                totalMedianMs: Stats.median(total), totalP95Ms: Stats.percentile(total, 95))
        }
        report.tokensPerSecondMedian = rates.isEmpty ? nil : Stats.median(rates)
        report.passRate = Double(passes) / Double(warm.cases.count)
        for (category, total) in categoryTotals {
            report.categoryPassRates[category] = Double(categoryPasses[category, default: 0]) / Double(total)
        }
        report.failures = failures
    }

    /// Short-clip median for Parakeet v3 from the most recent speech report in `directory`.
    static func parakeetShortMs(in directory: URL) -> Double? {
        struct Speech: Decodable {
            struct Engine: Decodable {
                let engineID: String
                let shortClipMedianMs: Double?
            }
            let engines: [Engine]
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files.filter({ $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix("-cleanup.json") }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            if let data = try? Data(contentsOf: file),
               let speech = try? JSONDecoder().decode(Speech.self, from: data),
               let value = speech.engines.first(where: { $0.engineID == "parakeet-tdt-v3" })?.shortClipMedianMs {
                return value
            }
        }
        return nil
    }

    static func markdown(_ report: CleanupBenchReport, cases: [CleanupCase]) -> String {
        var out = "# Mouthtype text-cleanup benchmark\n\n"
        let m = report.machine
        let v = m.packageVersions
        out += "Machine: \(m.chip), \(m.ramGB) GB, macOS \(m.macOS), \(m.swift). "
        out += "mlx-swift-lm \(v["mlx-swift-lm"] ?? "?"), mlx-swift \(v["mlx-swift"] ?? "?"), swift-huggingface \(v["swift-huggingface"] ?? "?"), swift-transformers \(v["swift-transformers"] ?? "?").\n\n"
        out += "Date: \(report.date). \(report.caseCount) cases, \(report.runsPerCase) timed runs per case after 1 untimed warm-up call. Greedy decoding (temperature 0), output capped at 3 tokens per input word plus 48. All cleaners get the same system prompt (`CleanupPrompt.systemPrompt`) except where marked below.\n\n"

        let ranked = report.cleaners.filter { $0.timingsComparable && $0.buckets[LengthBucket.short.rawValue] != nil }
        if let speech = report.parakeetShortMs, !ranked.isEmpty {
            let parts = ranked.sorted { ($0.buckets["short"]?.totalMedianMs ?? 0) < ($1.buckets["short"]?.totalMedianMs ?? 0) }.map {
                "\($0.displayName) \(num(speech + ($0.buckets["short"]?.totalMedianMs ?? 0), 0)) ms"
            }
            out += "Speech plus cleanup for a short utterance (Parakeet TDT v3 at \(num(speech, 0)) ms plus the cleaner's median total): " + parts.joined(separator: "; ") + ".\n\n"
        }

        out += "## Summary\n\n"
        out += "| Cleaner | Status | Cold prepare (s) | Warm load (s) | Short: first / total (ms) | Medium: first / total (ms) | Long: first / total (ms) | Tokens/s | Peak memory (MB) | Size (MB) | Pass rate | Judge (/8) |\n"
        out += "|---|---|---|---|---|---|---|---|---|---|---|---|\n"
        for c in report.cleaners {
            let comparable = c.timingsComparable
            func cell(_ bucket: LengthBucket) -> String {
                guard let t = c.buckets[bucket.rawValue] else { return "n/a" }
                let text = "\(num(t.firstMedianMs, 0)) / \(num(t.totalMedianMs, 0)) (p95 \(num(t.totalP95Ms, 0)))"
                return comparable ? text : "\(text) *not comparable*"
            }
            let judge = c.judge.map { "\(num($0.meanScore, 2))\($0.missing > 0 ? " (\($0.missing) ungraded)" : "")" } ?? "n/a"
            out += "| \(c.displayName) (`\(c.cleanerID)`) | \(statusCell(c)) | \(coldCell(c)) | \(warmCell(c)) | \(cell(.short)) | \(cell(.medium)) | \(cell(.long)) | \(num(c.tokensPerSecondMedian, 0)) | \(mb(c.warm?.peakFootprintBytes ?? c.cold?.peakFootprintBytes)) | \(mb(c.warm?.modelBytes ?? c.cold?.modelBytes)) | \(pct(c.passRate)) | \(judge) |\n"
        }
        out += "\nCold prepare is the first process for the cleaner: download plus load. Warm load is `prepare()` in a fresh process with the weights already on disk. "
        out += "First is time to first non-empty output and total is time to the last chunk, both measured from the start of the call and including prompt processing; each cell is the median over every timed run of every case in that length bucket, with the p95 of total in parentheses. "
        out += "Tokens/s is the median decode rate (generated tokens over decode time, excluding prompt processing) across cases, for backends that report it. "
        out += "Peak memory is the warm process's peak `phys_footprint` from `TASK_VM_INFO`, which includes GPU-backed unified memory. Size is the model directory on disk. "
        out += "Pass rate is the share of cases meeting every `mustContain`, `mustNotContain` and length-ratio constraint (case-insensitive substring checks; length is output characters over input characters). "
        out += "Judge is the mean of Claude Sonnet's rubric total per case (meaning 0-1, did not obey 0-1, fillers and corrections 0-2, formatting 0-2, over-editing 0-2, maximum 8), graded blind to the producing cleaner; a case that errored scores 0.\n\n"

        if report.cleaners.contains(where: { !$0.timingsComparable }) {
            out += "> The Claude CLI row's timings include CLI startup and a network round trip. They are not comparable to the other rows and are left out of the latency ranking below. That row is a quality ceiling only.\n\n"
        }
        for c in report.cleaners where c.warm?.usesSharedPrompt == false {
            out += "> \(c.displayName) used its native prompt from the model card (fixed system prompt plus the control line `\(S1MiniPrompt.controlLine)`, thinking disabled), not the shared prompt, because it was trained on that format. It does not see the custom vocabulary or app name. Its row is not a controlled-prompt comparison.\n\n"
        }
        if report.judge.requested {
            if report.judge.ran {
                out += "Judge: ran with `claude -p --model \(report.judge.model)`, \(Judge.batchSize) outputs per call, cached in `bench-cache/judge-cache.json`.\n\n"
            } else {
                out += "Judge: not run. \(report.judge.note ?? "")\n\n"
            }
        } else {
            out += "Judge: not requested (run with `--judge`).\n\n"
        }

        out += "## Latency ranking (short inputs, median total)\n\n"
        let order = ranked.sorted { ($0.buckets["short"]?.totalMedianMs ?? 0) < ($1.buckets["short"]?.totalMedianMs ?? 0) }
        if order.isEmpty {
            out += "No comparable timings.\n\n"
        } else {
            for (index, c) in order.enumerated() {
                out += "\(index + 1). \(c.displayName): \(num(c.buckets["short"]?.totalMedianMs, 0)) ms\n"
            }
            out += "\n"
        }

        out += "## Pass rate by category\n\n"
        let categories = CleanupFixtures.requiredCategories.filter { report.categories[$0] != nil }
            + report.categories.keys.filter { !CleanupFixtures.requiredCategories.contains($0) }.sorted()
        out += "| Category (cases) | " + report.cleaners.map(\.displayName).joined(separator: " | ") + " |\n"
        out += "|---|" + report.cleaners.map { _ in "---" }.joined(separator: "|") + "|\n"
        for category in categories {
            out += "| \(category) (\(report.categories[category] ?? 0)) | " + report.cleaners.map { pct($0.categoryPassRates[category]) }.joined(separator: " | ") + " |\n"
        }
        out += "\n"

        out += "## Cleaner details\n\n"
        for c in report.cleaners {
            out += "### \(c.displayName)\n\n"
            out += "- Status: \(c.status)\(c.statusDetail.map { ". \($0)" } ?? "")\n"
            if let spec = CleanerCatalog.mlxSpec(id: c.cleanerID) {
                out += "- Model: `\(spec.repo)`, quantization \(spec.quantization), run through MLX\n"
            }
            if let path = c.warm?.modelPath ?? c.cold?.modelPath {
                out += "- Cached at: `\(path)`\n"
            }
            if let bytes = c.warm?.modelBytes ?? c.cold?.modelBytes {
                out += "- Size on disk: \(mb(bytes)) MB\n"
            }
            if let license = c.warm?.license ?? c.cold?.license {
                out += "- License: \(license)\n"
            }
            if let first = c.warm?.firstCleanMs {
                out += "- First call after load (untimed warm-up): \(num(first, 0)) ms\n"
            }
            out += "\n"
        }

        out += "## Failures\n\n"
        out += "Every case a cleaner failed on the deterministic checks, input and output side by side. Newlines are shown as `\\n`.\n\n"
        for c in report.cleaners {
            out += "### \(c.displayName)\n\n"
            if c.warm == nil {
                out += "No run: \(c.statusDetail ?? c.status).\n\n"
                continue
            }
            if c.failures.isEmpty {
                out += "No failures.\n\n"
                continue
            }
            out += "\(c.failures.count) of \(c.warm?.cases.count ?? 0) cases failed.\n\n"
            for failure in c.failures {
                out += "- `\(failure.caseID)` (\(failure.category)): \(failure.reasons.joined(separator: "; "))\n"
                out += "  - Input: \(escaped(failure.input))\n"
                out += "  - Output: \(escaped(failure.output))\n"
            }
            out += "\n"
        }

        out += "## Rerun\n\n"
        out += "`\(buildCommand)`\n\n"
        out += "Metal shaders compile only when the Metal Toolchain component is installed (`xcodebuild -downloadComponent MetalToolchain`).\n"
        return out
    }

    private static func escaped(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "`", with: "'")
        return "`\(flat)`"
    }

    private static func statusCell(_ c: CleanerReport) -> String {
        switch c.status {
        case "ok": return "ok"
        case "unavailable": return "unavailable: \(c.statusDetail ?? "")"
        default: return "FAILED"
        }
    }

    private static func coldCell(_ c: CleanerReport) -> String {
        guard let p = c.cold?.prepare else { return "n/a" }
        let total = p.downloadSeconds + p.loadSeconds
        if !p.downloaded { return "\(num(total, 1)) (already on disk)" }
        return "\(num(total, 1)) (download \(num(p.downloadSeconds, 1)) + load \(num(p.loadSeconds, 1)))"
    }

    private static func warmCell(_ c: CleanerReport) -> String {
        guard let p = c.warm?.prepare else { return "n/a" }
        return num(p.downloadSeconds + p.loadSeconds, 1)
    }

    private static func num(_ value: Double?, _ digits: Int) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.\(digits)f", value)
    }

    private static func pct(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.0f%%", value * 100)
    }

    private static func mb(_ bytes: Int?) -> String {
        guard let bytes else { return "n/a" }
        return String(format: "%.0f", Double(bytes) / 1_048_576)
    }
}
