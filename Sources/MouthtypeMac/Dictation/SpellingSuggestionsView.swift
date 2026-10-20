import MouthtypeCore
import SwiftUI

/// Suggestions at the top of Saved spellings. One short line when there is nothing to offer.
struct SpellingSuggestionsSection: View {
    var model: SpellingSuggestionsModel
    var editor: SpellingEditor
    /// Opens the first row's examples. Previews use it; the app starts with every row collapsed.
    var expandFirst = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.suggestions.isEmpty {
                Text("No suggestions yet. Mouthtype looks at your recent takes for names it keeps mishearing.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("spelling-suggestions-empty")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        heading("SUGGESTIONS", count: model.confident.count)
                        ForEach(model.confident) { row($0, expanded: expandFirst && $0.id == model.confident.first?.id) }
                        if !model.maybe.isEmpty {
                            heading("MAYBE", count: model.maybe.count).padding(.top, 4)
                            ForEach(model.maybe) { row($0, expanded: false) }
                        }
                    }
                }.frame(maxHeight: 260)
            }
            if let undo = model.undo {
                HStack(spacing: 8) {
                    Label(undo.message, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
                    Button("Undo") { model.undoLast() }.buttonStyle(.link)
                        .accessibilityLabel("Undo: \(undo.message)").accessibilityIdentifier("spelling-suggestion-undo")
                }
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24).padding(.vertical, 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggestions")
    }

    private func heading(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func row(_ suggestion: SpellingSuggestion, expanded: Bool) -> some View {
        SpellingSuggestionRow(suggestion: suggestion, model: model, busy: editor.isDirty || editor.loadFailed, expanded: expanded)
    }
}

struct SpellingSuggestionRow: View {
    let suggestion: SpellingSuggestion
    var model: SpellingSuggestionsModel
    var busy: Bool
    @State private var expanded: Bool

    init(suggestion: SpellingSuggestion, model: SpellingSuggestionsModel, busy: Bool, expanded: Bool = false) {
        self.suggestion = suggestion
        self.model = model
        self.busy = busy
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.title(suggestion)).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                    Text(Self.reason(suggestion)).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if !suggestion.evidence.isEmpty {
                    Button(expanded ? "Hide examples" : "Examples") { expanded.toggle() }
                        .buttonStyle(.link).font(.callout)
                        .accessibilityLabel(expanded ? "Hide examples for \(Self.title(suggestion))" : "Show examples for \(Self.title(suggestion))")
                }
                if suggestion.kind == .removeHazard {
                    Button("Remove") { model.remove(suggestion) }.disabled(busy)
                        .accessibilityLabel("Remove: \(Self.title(suggestion))")
                } else {
                    Button("Add") { model.add(suggestion) }.disabled(busy).buttonStyle(.borderedProminent)
                        .accessibilityLabel("Add: \(Self.title(suggestion))")
                }
                Button("Dismiss") { model.dismiss(suggestion) }
                    .accessibilityLabel("Dismiss: \(Self.title(suggestion))")
            }
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(suggestion.evidence.prefix(5).enumerated()), id: \.offset) { _, item in
                        Text(Self.highlighted(item.fragment, terms: suggestion.heardForms + [suggestion.written]))
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.leading, 12)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }

    static func title(_ suggestion: SpellingSuggestion) -> String {
        if suggestion.kind == .removeHazard {
            return "Remove ‘\(suggestion.heardForms.first ?? "")’ → \(suggestion.written)"
        }
        return suggestion.heardForms.joined(separator: ", ") + " → " + suggestion.written
    }

    static func reason(_ suggestion: SpellingSuggestion) -> String {
        let times = suggestion.count == 1 ? "1 time" : "\(suggestion.count) times"
        if suggestion.kind == .removeHazard {
            return suggestion.count == 0 ? "Matched nothing in your recent takes." : "Rewrites an everyday word. Heard \(times)."
        }
        return "Heard \(times)"
    }

    /// Bolds each match of a heard or written form, ignoring case.
    static func highlighted(_ fragment: String, terms: [String]) -> AttributedString {
        var text = AttributedString(fragment)
        for term in terms where !term.isEmpty {
            var from = text.startIndex
            while from < text.endIndex, let range = text[from...].range(of: term, options: .caseInsensitive) {
                text[range].font = .callout.bold()
                text[range].backgroundColor = Color.accentColor.opacity(0.25)
                from = range.upperBound
            }
        }
        return text
    }
}
