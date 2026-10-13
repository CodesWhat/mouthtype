import ArgumentParser
import Foundation
import MouthtypeCore

enum SmartLevel: String, ExpressibleByArgument, CaseIterable {
    case light, medium

    var level: CleanupLevel { self == .light ? .light : .medium }
}

enum StyleChoice: String, ExpressibleByArgument, CaseIterable {
    case formal, casual
    case veryCasual = "very-casual"

    var preset: StylePreset {
        switch self {
        case .formal: .formal
        case .casual: .casual
        case .veryCasual: .veryCasual
        }
    }
}

/// `mouthtype-bench clean`: runs the deterministic text pipeline on typed text, a file of utterances, or the
/// app's own transcript history (opened read-only). With `--smart` the S1-mini pass runs after it, as in the app.
struct CleanTextCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean",
        abstract: "Run the deterministic text cleanup on text, a file, or the transcript history."
    )

    @Option(help: "One utterance to clean.") var text: String?
    @Option(help: "A file with one utterance per line.") var file: String?
    @Flag(help: "Re-run the current cleanup on stored dictations (database opened read-only).") var history = false
    @Option(help: "History: the newest N dictations.") var limit: Int = 20
    @Option(help: "History: only dictations since this ISO date (2026-10-01 or 2026-10-01T09:00:00Z).") var since: String?
    @Option(help: "History: also write the comparison as a Markdown table to this path.") var markdown: String?
    @Option(help: "Style preset: formal, casual or very-casual.") var style: StyleChoice = .formal
    @Option(help: "Also run S1-mini by Superwhisper at this level: light or medium. --file may be a .json list of cases; with no input the bundled acceptance cases run.")
    var smart: SmartLevel?
    @Option(help: "--smart: give up on the model after this many milliseconds instead of the word-based budget.")
    var smartTimeoutMs: Int?

    func validate() throws {
        let modes = [text != nil, file != nil, history].filter { $0 }.count
        guard modes == 1 || (smart != nil && modes == 0) else {
            throw ValidationError("Give exactly one of --text, --file or --history (--smart alone runs the bundled acceptance cases).")
        }
        if smart != nil, history { throw ValidationError("--smart does not apply to --history.") }
        if smartTimeoutMs != nil, smart == nil { throw ValidationError("--smart-timeout-ms needs --smart.") }
        if markdown != nil, !history { throw ValidationError("--markdown only applies to --history.") }
        if since != nil, !history { throw ValidationError("--since only applies to --history.") }
        if limit < 1 { throw ValidationError("--limit must be at least 1.") }
    }

    private var pipeline: TextPipeline { TextPipeline() }

    private func run(_ raw: String) -> TextPipelineResult {
        let options = TextPipelineOptions(style: style.preset.options)
        return pipeline.run(TextPipelineInput(text: raw, options: options))
    }

    func run() async throws {
        if let smart {
            try await runSmart(level: smart.level)
            return
        }
        if let text {
            show(text)
        } else if let file {
            let contents = try String(contentsOfFile: file, encoding: .utf8)
            for line in contents.split(whereSeparator: \.isNewline) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                show(String(line))
                print("")
            }
        } else {
            try runHistory()
        }
    }

    private func runSmart(level: CleanupLevel) async throws {
        let cleaner = CleanerCatalog.makeSmartCleanup()
        guard cleaner.isDownloaded else {
            throw ValidationError("\(CleanerCatalog.smartCleanupName) is not on disk. Run the cleanup benchmark once to download it.")
        }
        try await cleaner.load()
        _ = try? await cleaner.clean("warm up the model before timing it", context: CleanupContext())
        let smart: SmartCleanup
        if let ms = smartTimeoutMs {
            smart = SmartCleanup(cleaner: cleaner, budget: { _ in .milliseconds(ms) })
        } else {
            smart = SmartCleanup(cleaner: cleaner)
        }

        var cases: [SmartCase] = []
        if text == nil, file == nil {
            cases = try SmartFixtures.load()
        } else if let text {
            cases = [SmartCase(id: "text", input: text, target: "")]
        } else if let file, file.hasSuffix(".json") {
            cases = try JSONDecoder().decode([SmartCase].self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        } else if let file {
            let contents = try String(contentsOfFile: file, encoding: .utf8)
            cases = contents.split(whereSeparator: \.isNewline)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .enumerated().map { SmartCase(id: "line-\($0.offset + 1)", input: String($0.element), target: "") }
        }
        var passed = 0
        var checked = 0
        for item in cases {
            let run = await SmartRunner.run(item.input, rules: item.rules, level: level, style: style.preset.options, smart: smart)
            print("[\(item.id)] raw:     \(Self.escaped(item.input))")
            print("         det:     \(Self.escaped(run.deterministic))")
            print("         final:   \(Self.escaped(run.result.text))")
            let note = run.result.rejection.map { " (\($0))" } ?? ""
            var verdict = ""
            if item.exact != nil || item.mustContain != nil || item.mustNotContain != nil {
                checked += 1
                let failure = item.failure(for: run.result.text)
                if failure == nil { passed += 1 }
                verdict = failure.map { "  FAIL: \($0)" } ?? "  pass"
            }
            print("         outcome: \(run.result.outcome.rawValue)\(note)  \(run.result.milliseconds) ms\(verdict)")
            print("")
        }
        if checked > 0 { print("\(passed)/\(checked) cases pass the automatic checks at \(level.rawValue)") }
        if passed < checked { throw ExitCode.failure }
    }

    private func show(_ raw: String) {
        let result = run(raw)
        print("raw:     \(Self.escaped(raw))")
        print("cleaned: \(Self.escaped(result.text))")
        if result.edits.isEmpty {
            print("edits:   none")
        } else {
            for edit in result.edits {
                let from = edit.fromText.map(Self.escaped) ?? ""
                let to = edit.toText.map(Self.escaped) ?? ""
                print("edit:    [\(edit.stage)] \"\(from)\" -> \"\(to)\"")
            }
        }
    }

    private func runHistory() throws {
        let sinceDate = try since.map(Self.parseDate)
        let url = TranscriptStore.defaultURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError("No transcript database at \(url.path).")
        }
        let entries = try TranscriptHistory.entries(at: url, limit: limit, since: sinceDate)
        let timeFormat = Date.FormatStyle(date: .abbreviated, time: .standard)
        var table = "| Time | Raw | Cleaned now | Differs from stored det_text | Differs from stored final_text |\n"
        table += "| --- | --- | --- | --- | --- |\n"
        for entry in entries {
            let result = run(entry.rawText)
            let when = entry.startedAt.formatted(timeFormat)
            let detDiffers = entry.detText.map { $0 != result.text }
            let finalDiffers = entry.finalText.map { $0.trimmingCharacters(in: .whitespaces) != result.text }
            print("\(when)")
            print("raw:     \(Self.escaped(entry.rawText))")
            print("cleaned: \(Self.escaped(result.text))")
            print("vs det_text: \(Self.verdict(detDiffers))   vs final_text: \(Self.verdict(finalDiffers))")
            print("")
            table += "| \(when) | \(Self.cell(entry.rawText)) | \(Self.cell(result.text)) | "
                + "\(Self.verdict(detDiffers)) | \(Self.verdict(finalDiffers)) |\n"
        }
        print("\(entries.count) dictations")
        if let markdown {
            try table.write(toFile: markdown, atomically: true, encoding: .utf8)
            print("Wrote \(markdown)")
        }
    }

    private static func verdict(_ differs: Bool?) -> String {
        switch differs {
        case .some(true): "differs"
        case .some(false): "same"
        case .none: "not stored"
        }
    }

    private static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func cell(_ s: String) -> String {
        escaped(s).replacingOccurrences(of: "|", with: "\\|")
    }

    private static func parseDate(_ string: String) throws -> Date {
        if let date = try? Date(string, strategy: .iso8601) { return date }
        if let date = try? Date(string, strategy: .iso8601.year().month().day()) { return date }
        throw ValidationError("Can't read \"\(string)\" as an ISO date.")
    }
}
