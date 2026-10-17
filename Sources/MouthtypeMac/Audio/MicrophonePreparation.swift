import Foundation

@MainActor final class MicrophonePreparation {
    private(set) var isPrepared = false
    private var preparing = false
    private var revision: UInt64 = 0

    func invalidate() { revision &+= 1; isPrepared = false }

    func prepare(_ operation: @MainActor () async throws -> Bool) async throws -> Bool {
        guard !preparing else { return false }
        preparing = true
        isPrepared = false
        defer { preparing = false }
        // A selection change can replace one in-flight preparation, never create a retry loop.
        for _ in 0..<2 {
            let current = revision
            do {
                let prepared = try await operation()
                if revision == current {
                    isPrepared = prepared
                    return prepared
                }
            } catch {
                if revision == current { throw error }
            }
        }
        return false
    }
}
