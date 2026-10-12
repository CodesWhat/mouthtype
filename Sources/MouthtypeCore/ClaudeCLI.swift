import Foundation

/// Runs prompts through the Claude Code CLI (`claude -p`), the only Claude access on this machine.
public enum ClaudeCLI {
    public static func locate() -> URL? {
        let fm = FileManager.default
        var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories.append(NSHomeDirectory() + "/.local/bin")
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("claude")
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Single-turn call with no tools, no session persistence and no user settings. Returns stdout.
    public static func run(model: String, system: String, prompt: String, timeout: TimeInterval = 300) async throws -> String {
        guard let executable = locate() else {
            throw CleanerError.unavailable(reason: "The claude CLI was not found on PATH")
        }
        let arguments = [
            "-p", "--model", model,
            "--system-prompt", system,
            "--tools", "",
            "--no-session-persistence",
            "--disable-slash-commands",
            "--setting-sources", "",
            "--output-format", "text",
        ]
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    continuation.resume(returning: try runBlocking(executable: executable, arguments: arguments, input: prompt, timeout: timeout))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runBlocking(executable: URL, arguments: [String], input: String, timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

        let errorReader = DispatchQueue(label: "claude-cli-stderr")
        nonisolated(unsafe) var errorData = Data()
        let errorDone = DispatchSemaphore(value: 0)
        errorReader.async {
            errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            errorDone.signal()
        }

        stdin.fileHandleForWriting.write(Data(input.utf8))
        try? stdin.fileHandleForWriting.close()
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        errorDone.wait()
        timer.cancel()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CleanerError.failed("claude exited with status \(process.terminationStatus): \(message)")
        }
        return String(decoding: outputData, as: UTF8.self)
    }
}

/// Quality ceiling: Claude Haiku through the CLI. Its latency includes process startup, so it is not comparable to a local model or an API call.
public final class ClaudeCLICleaner: MeasuredCleaner {
    public static let haikuID = "claude-haiku-cli"
    public static let haikuDisplayName = "Claude Haiku via claude CLI (quality ceiling)"

    public let id: String
    public let displayName: String
    public let modelDirectory: URL? = nil
    public let timingsAreRepresentative = false
    private let model: String

    init(id: String, displayName: String, model: String) {
        self.id = id
        self.displayName = displayName
        self.model = model
    }

    public func prepareMeasured() async throws -> PrepareTimings {
        guard ClaudeCLI.locate() != nil else {
            throw CleanerError.unavailable(reason: "The claude CLI was not found on PATH")
        }
        return PrepareTimings(downloadSeconds: 0, loadSeconds: 0, downloaded: false)
    }

    public func cleanMeasured(_ transcript: String, context: CleanupContext) async throws -> CleanupResult {
        let clock = ContinuousClock()
        let start = clock.now
        let output = try await ClaudeCLI.run(
            model: model, system: CleanupPrompt.system(for: context), prompt: CleanupPrompt.user(transcript))
        let total = (clock.now - start).seconds
        return CleanupResult(text: CleanupPrompt.sanitize(output), firstOutputSeconds: total, totalSeconds: total)
    }
}
