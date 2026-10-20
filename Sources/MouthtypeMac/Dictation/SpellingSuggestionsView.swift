import MouthtypeCore
import SwiftUI

/// Suggestions at the top of the Dictionary page: one card of rows, then a collapsed Maybe row for the weaker guesses.
/// One short note when there is nothing to offer.
struct SpellingSuggestionsSection: View {
    var model: SpellingSuggestionsModel
    var editor: SpellingEditor
    /// Opens the first row's examples. Previews use it; the app starts with every row collapsed.
    var expandFirst = false
    @State private var showMaybe = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DesignEyebrow(model.suggestions.isEmpty ? "Suggestions" : "Suggestions · heard a lot lately")
            DesignCard {
                if model.suggestions.isEmpty {
                    Text("No suggestions yet. Mouthtype looks at your recent takes for names it keeps mishearing.")
                        .font(DesignFont.sans(DesignFont.body)).foregroundStyle(DesignPalette.ink2)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .accessibilityIdentifier("spelling-suggestions-empty")
                } else {
                    ForEach(model.confident) { row($0, expanded: expandFirst && $0.id == model.confident.first?.id) }
                    if !model.maybe.isEmpty {
                        maybeToggle
                        if showMaybe { ForEach(model.maybe) { row($0, expanded: false) } }
                    }
                }
            }
            if let undo = model.undo {
                HStack(spacing: 8) {
                    Label(undo.message, systemImage: "checkmark.circle").font(DesignFont.sans(DesignFont.detail)).foregroundStyle(DesignPalette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Undo") { model.undoLast() }.buttonStyle(.designSecondary).disabled(editor.isDirty || editor.loadFailed)
                        .accessibilityLabel("Undo: \(undo.message)").accessibilityIdentifier("spelling-suggestion-undo")
                }.padding(.horizontal, 4)
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.circle").font(DesignFont.sans(DesignFont.detail)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggestions")
    }

    private var maybeToggle: some View {
        let count = model.maybe.count
        return Button { showMaybe.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: showMaybe ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 10)
                    .accessibilityHidden(true)
                Text("Maybe · \(count) weaker guess\(count == 1 ? "" : "es")").fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(DesignFont.sans(DesignFont.detail, .medium)).foregroundStyle(DesignPalette.ink2)
            .padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 34, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Maybe, \(count) weaker guess\(count == 1 ? "" : "es")")
        .accessibilityValue(showMaybe ? "Shown" : "Hidden")
        .accessibilityHint("Shows or hides the weaker guesses")
        .accessibilityIdentifier("spelling-suggestions-maybe")
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
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    summary.frame(maxWidth: .infinity, alignment: .leading)
                    actions
                }
                VStack(alignment: .leading, spacing: 6) {
                    summary.frame(maxWidth: .infinity, alignment: .leading)
                    actions
                }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(suggestion.evidence.prefix(5).enumerated()), id: \.offset) { _, item in
                        Text(Self.highlighted(item.fragment, terms: suggestion.heardForms + [suggestion.written]))
                            .font(DesignFont.sans(DesignFont.detail)).foregroundStyle(DesignPalette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.leading, 4).padding(.bottom, 4)
            }
        }
        .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 6).frame(minHeight: 42)
        .accessibilityElement(children: .contain)
    }

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if suggestion.kind == .removeHazard {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.title(suggestion)).font(DesignFont.sans(DesignFont.body, .semibold)).foregroundStyle(DesignPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Self.reason(suggestion)).font(DesignFont.sans(DesignFont.detail)).foregroundStyle(DesignPalette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HeardFlow(spacing: 6) {
                    Text(suggestion.written).font(DesignFont.sans(DesignFont.body, .semibold)).foregroundStyle(DesignPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("for").font(DesignFont.sans(DesignFont.detail)).foregroundStyle(DesignPalette.ink2)
                    ForEach(suggestion.heardForms, id: \.self) { form in
                        Text(form).font(DesignFont.mono(11)).foregroundStyle(DesignPalette.ink).fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(DesignPalette.c0))
                    }
                    Text("· " + Self.reason(suggestion).replacingOccurrences(of: "Heard ", with: "")).font(DesignFont.sans(DesignFont.detail))
                        .foregroundStyle(DesignPalette.ink2)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.title(suggestion) + ". " + Self.reason(suggestion))
    }

    private var actions: some View {
        HStack(spacing: 4) {
            if !suggestion.evidence.isEmpty {
                Button { expanded.toggle() } label: {
                    Text(expanded ? "Hide examples" : "Examples").font(DesignFont.sans(DesignFont.detail, .medium))
                        .foregroundStyle(DesignPalette.ink2).padding(.horizontal, 10).frame(minHeight: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Hide examples for \(Self.title(suggestion))" : "Show examples for \(Self.title(suggestion))")
            }
            if suggestion.kind == .removeHazard {
                Button("Remove") { model.remove(suggestion) }.buttonStyle(.designSecondary).disabled(busy)
                    .accessibilityLabel("Remove: \(Self.title(suggestion))")
            } else {
                Button("Add") { model.add(suggestion) }.buttonStyle(.designPrimary).disabled(busy)
                    .accessibilityLabel("Add: \(Self.title(suggestion))")
            }
            Button { model.dismiss(suggestion) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(DesignPalette.ink3)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Dismiss: \(Self.title(suggestion))")
        }
    }

    static func title(_ suggestion: SpellingSuggestion) -> String {
        if suggestion.kind == .removeHazard {
            let pairs = suggestion.hazardRules.isEmpty
                ? ["‘\(suggestion.heardForms.first ?? "")’ → \(suggestion.written)"]
                : suggestion.hazardRules.map { "‘\($0.heard)’ → \($0.written)" }
            let list = pairs.count <= 2
                ? pairs.joined(separator: " and ")
                : pairs.dropLast().joined(separator: ", ") + ", and " + pairs[pairs.count - 1]
            return "Remove " + list
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
                text[range].font = DesignFont.sans(DesignFont.detail, .semibold)
                text[range].backgroundColor = DesignPalette.c1
                from = range.upperBound
            }
        }
        return text
    }
}
