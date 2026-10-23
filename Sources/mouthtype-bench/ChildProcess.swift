import Foundation

struct ChildOutcome {
    let exitStatus: Int32
    let timedOut: Bool
    let logTail: String
}

/// Wraps Process so the termination handler and the timeout timer can share it across threads.
private final class ChildProcess: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var timedOutFlag = false

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOutFlag
    }

    func start(
        executable: URL, arguments: [String], log: FileHandle, timeout: TimeInterval,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { onExit($0.terminationStatus) }
        try process.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
            guard process.isRunning else { return }
            lock.lock()
            timedOutFlag = true
            lock.unlock()
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [self] in
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}

func runChild(executable: URL, arguments: [String], logURL: URL, timeout: TimeInterval) async throws -> ChildOutcome {
    try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    let log = try FileHandle(forWritingTo: logURL)
    defer { try? log.close() }

    let child = ChildProcess()
    let status: Int32 = try await withCheckedThrowingContinuation { continuation in
        do {
            try child.start(executable: executable, arguments: arguments, log: log, timeout: timeout) {
                continuation.resume(returning: $0)
            }
        } catch {
            continuation.resume(throwing: error)
        }
    }
    let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    let tail = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(12).joined(separator: "\n")
    return ChildOutcome(exitStatus: status, timedOut: child.timedOut, logTail: tail)
}
