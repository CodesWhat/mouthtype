import Foundation

/// Runs blocking work (database reads, syscalls like waitpid) on a GCD thread and resumes the caller from there.
/// A cooperative-pool thread must never block: the pool has one thread per core, so a few blocked callers starve
/// every other task, which is what froze the 3-core CI runner.
///
/// The work can't see the caller's task, so cancelling the caller flips a flag the work reads through
/// `OffPool.isCancelled` while it runs on the GCD thread.
enum OffPool {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    }

    private static let flagKey = "mouthtype.OffPool.flag"

    /// True when the task that called `run` was cancelled. Only meaningful inside the work closure.
    static var isCancelled: Bool {
        (Thread.current.threadDictionary[flagKey] as? Flag)?.isCancelled ?? false
    }

    private static func execute<T>(_ flag: Flag, _ work: @Sendable () -> T) -> T {
        Thread.current.threadDictionary[flagKey] = flag
        defer { Thread.current.threadDictionary.removeObject(forKey: flagKey) }
        return work()
    }

    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        let flag = Flag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: execute(flag, work)) }
            }
        } onCancel: {
            flag.cancel()
        }
    }

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let flag = Flag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: execute(flag) { Result { try work() } })
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }
}
