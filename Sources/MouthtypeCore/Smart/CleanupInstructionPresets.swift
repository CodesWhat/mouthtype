import Foundation

/// Ready-made instruction texts a user can start from. Choosing one only fills the instructions box; the text is edited and
/// saved like anything typed. Every preset here passed the guard evaluation in `docs/evals/instruction-presets-2026-10.md`.
public struct CleanupInstructionPreset: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let text: String
}

public enum CleanupInstructionPresets {
    public static let all: [CleanupInstructionPreset] = [
        CleanupInstructionPreset(
            id: "slack", title: "Slack",
            text: "Write it like a quick Slack message: short and casual, with contractions. No greeting and no sign-off."),
        CleanupInstructionPreset(
            id: "keep-my-wording", title: "Keep my wording",
            text: "Keep my exact wording. Only fix punctuation, capitalization and grammar. Don't rephrase or reorder anything."),
        CleanupInstructionPreset(
            id: "code-comments", title: "Code comments",
            text: "Write it as a code comment: terse, plain words. No trailing period on a one-line comment."),
    ]
}
