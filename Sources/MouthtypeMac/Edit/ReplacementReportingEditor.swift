import Foundation

/// Wraps a selection editor and says when a replacement was taken. A refused or stale replacement reports nothing, so the
/// achievement counters only see an edit that really landed. Reads and writes pass straight through.
@MainActor struct ReplacementReportingEditor: SelectionEditing {
    let base: any SelectionEditing
    let replaced: @MainActor () -> Void

    func capture() throws -> SelectedText { try base.capture() }
    func capture(budget: TimeInterval) throws -> SelectedText { try base.capture(budget: budget) }
    func captureOffMain(budget: TimeInterval) async throws -> SelectedText { try await base.captureOffMain(budget: budget) }

    func replace(_ original: SelectedText, with replacement: String) -> Bool {
        let taken = base.replace(original, with: replacement)
        if taken { replaced() }
        return taken
    }
}
