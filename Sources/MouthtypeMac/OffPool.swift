import Foundation

/// Runs blocking work (database reads, syscalls like waitpid) on a GCD thread and resumes the caller from there.
/// A cooperative-pool thread must never block: the pool has one thread per core, so a few blocked callers starve
/// every other task, which is what froze the 3-core CI runner.
enum OffPool {
    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try work() }) }
        }
    }
}
