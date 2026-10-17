import Foundation

actor ParakeetInferenceGate {
    private var occupied = false
    private var finals: ArraySlice<CheckedContinuation<Void, Never>> = []
    var queuedFinalCount: Int { finals.count }

    func withPreview<Input: Sendable>(
        prepare: @Sendable () async throws -> Input,
        predict: @Sendable (Input) async throws -> String?
    ) async throws -> String? {
        try Task.checkCancellation()
        guard !occupied else { return nil }
        occupied = true
        defer { release() }
        let input = try await prepare()
        try Task.checkCancellation()
        return try await predict(input)
    }

    func withFinal<Result: Sendable>(_ work: @Sendable () async throws -> Result) async throws -> Result {
        try Task.checkCancellation()
        if occupied {
            await withCheckedContinuation { finals.append($0) }
        } else {
            occupied = true
        }
        defer { release() }
        try Task.checkCancellation()
        return try await work()
    }

    private func release() {
        if let next = finals.popFirst() {
            // Keep the permit reserved while the next final resumes, so a preview cannot enter between jobs.
            next.resume()
        } else {
            occupied = false
            finals = []
        }
    }
}
