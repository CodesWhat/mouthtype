import Foundation
import Observation

@MainActor @Observable final class MicrophonePreparation {
    private(set) var isPrepared = false
    private(set) var isPreparing = false
    private(set) var error: String?
    private var revision: UInt64 = 0
    private var starts: UInt64 = 0

    func invalidate() { revision &+= 1; isPrepared = false; error = nil }

    func start(_ operation: @MainActor () async throws -> Void) async throws {
        starts &+= 1
        let current = revision, started = starts
        isPrepared = false
        error = nil
        do {
            try await operation()
            if revision == current, starts == started { isPrepared = true; error = nil }
        } catch {
            if revision == current, starts == started {
                isPrepared = false
                self.error = error.localizedDescription
            }
            throw error
        }
    }

    func prepare(_ operation: @MainActor () async throws -> Bool) async throws -> Bool {
        guard !isPreparing else { return false }
        isPreparing = true
        isPrepared = false
        error = nil
        let started = starts
        defer { isPreparing = false }
        // A selection change can replace one in-flight preparation, never create a retry loop.
        for _ in 0..<2 {
            let current = revision
            do {
                let prepared = try await operation()
                guard starts == started else { return isPrepared }
                if revision == current {
                    isPrepared = prepared
                    error = prepared ? nil : "Microphone choice changed. Prepare your input again."
                    return prepared
                }
            } catch {
                guard starts == started else { return isPrepared }
                if revision == current {
                    self.error = error.localizedDescription
                    throw error
                }
            }
        }
        error = "Microphone choice changed. Prepare your input again."
        return false
    }
}
