import Foundation

/// Runs a process to completion without parking a cooperative-pool thread: the exit arrives through
/// terminationHandler and the pipes drain on their own handlers.
func runProcess(_ process: Process, stdout: Pipe? = nil, stderr: Pipe? = nil) async throws -> (out: Data, err: Data) {
    final class Buffer: @unchecked Sendable {
        let lock = NSLock()
        var data = Data()
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }
    }
    let outBuffer = Buffer(), errBuffer = Buffer()
    stdout?.fileHandleForReading.readabilityHandler = { outBuffer.append($0.availableData) }
    stderr?.fileHandleForReading.readabilityHandler = { errBuffer.append($0.availableData) }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        process.terminationHandler = { _ in continuation.resume() }
        do { try process.run() } catch {
            process.terminationHandler = nil
            continuation.resume(throwing: error)
        }
    }
    stdout?.fileHandleForReading.readabilityHandler = nil
    stderr?.fileHandleForReading.readabilityHandler = nil
    if let handle = stdout?.fileHandleForReading { outBuffer.append((try? handle.readToEnd()) ?? Data()) }
    if let handle = stderr?.fileHandleForReading { errBuffer.append((try? handle.readToEnd()) ?? Data()) }
    return (outBuffer.value, errBuffer.value)
}
