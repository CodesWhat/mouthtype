import MouthtypeCore
import SwiftUI

/// Free-text instructions for Thorough cleanup: one box with an example when empty, a character count, and Save and Clear.
/// The same editor serves the global instructions and each app or site rule. Fast ignores them, and the guard still checks
/// every output against what was said, so the box says both.
struct StyleInstructionsEditor: View {
    /// What is saved now; the box resets to it when it changes underneath (another row saved, or a reload).
    let saved: String?
    /// What to show while the box is empty.
    let placeholder: String
    /// The accessibility label, e.g. "Instructions for Slack".
    let label: String
    let identifier: String
    let save: (String?) -> Void
    @State private var draft: String

    init(saved: String?, placeholder: String, label: String, identifier: String, save: @escaping (String?) -> Void) {
        self.saved = saved
        self.placeholder = placeholder
        self.label = label
        self.identifier = identifier
        self.save = save
        _draft = State(initialValue: saved ?? "")
    }

    static let explanation =
        "Thorough follows these for tone and formatting. It never changes what you said. Fast ignores them."

    private var changed: Bool { CleanupInstructions.normalize(draft) != saved }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft).scrollContentBackground(.hidden)
                    .font(DesignFont.sans(DesignFont.detail)).lineSpacing(3).padding(6).frame(height: 78)
                    .background(RoundedRectangle(cornerRadius: 8).fill(DesignPalette.surface))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesignPalette.hair, lineWidth: 1))
                    .accessibilityLabel(label).accessibilityIdentifier(identifier)
                if draft.isEmpty {
                    Text(placeholder).font(DesignFont.sans(DesignFont.detail)).foregroundStyle(DesignPalette.ink3)
                        .padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Self.explanation).font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text("\(draft.count) / \(CleanupInstructions.maxLength)").font(DesignFont.mono(DesignFont.eyebrow))
                    .foregroundStyle(DesignPalette.ink3).fixedSize().accessibilityIdentifier(identifier + "-count")
                if saved != nil {
                    Button("Clear") {
                        draft = ""; save(nil)
                    }.buttonStyle(.designSecondary).fixedSize()
                        .accessibilityIdentifier(identifier + "-clear")
                }
                Button("Save") { save(CleanupInstructions.normalize(draft)) }.buttonStyle(.designPrimary).fixedSize()
                    .disabled(!changed).accessibilityIdentifier(identifier + "-save")
            }
        }
        .onChange(of: draft) { _, value in
            let limited = CleanupInstructions.limited(value)
            if limited != value { draft = limited }
        }
        .onChange(of: saved) { _, value in draft = value ?? "" }
    }
}

extension StyleContextID {
    /// An example instruction for the empty box, in the voice of that kind of writing.
    var instructionsExample: String {
        switch self {
        case .personal: "For example: Keep it warm and short. No bullet points."
        case .work: "For example: Short, direct sentences. Put action items in a bullet list."
        case .email: "For example: Greeting on its own line, short paragraphs, plain words."
        case .other: "For example: Keep it plain and direct. Use bullet points when I list things."
        }
    }
}
