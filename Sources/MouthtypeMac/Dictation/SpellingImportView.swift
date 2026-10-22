import SwiftUI

/// The Import CSV sheet over the Dictionary page: a summary line, a short row table and the Import button. The table shows the
/// first few rows plus every invalid row, then counts the rest, so an error is never hidden behind "and n more rows".
struct SpellingImportView: View {
    @Bindable var editor: SpellingEditor
    static let width: CGFloat = 620
    static let previewRows = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                DesignEyebrow(editor.importFileName.isEmpty ? editor.importSource.sheetEyebrow : "\(editor.importSource.sheetEyebrow) · \(editor.importFileName)").padding(.leading, 0)
                Spacer(minLength: 12)
                DesignCloseButton(label: "Close without importing") { editor.cancelImport() }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Import spellings.").font(DesignFont.serif(24)).foregroundStyle(DesignPalette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(editor.importSource.summaryLine)
                .font(DesignFont.sans(12.5)).foregroundStyle(DesignPalette.ink2).fixedSize(horizontal: false, vertical: true)
            }
            if let preview = editor.importPreview, !preview.rows.isEmpty {
                summary(preview)
                table(preview)
            }
            if let message = editor.importError ?? editor.importPreview?.problem {
                Label(message, systemImage: "exclamationmark.circle").foregroundStyle(DesignPalette.danger)
                    .font(DesignFont.sans(DesignFont.detail)).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .center, spacing: 12) {
                Text(footnote).font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Button("Cancel") { editor.cancelImport() }.buttonStyle(.designSecondary).keyboardShortcut(.cancelAction)
                    let count = editor.importPreview?.additions.count ?? 0
                    Button("Import \(count) spelling\(count == 1 ? "" : "s")") { editor.confirmImport() }
                        .buttonStyle(.designPrimary).disabled(!editor.canImport)
                        .accessibilityIdentifier("spelling-confirm-import")
                }.fixedSize()
            }
        }
        .padding(EdgeInsets(top: 22, leading: 24, bottom: 20, trailing: 24))
        .frame(width: Self.width)
        .background(DesignPalette.bg)
    }

    // MARK: Summary

    private func summary(_ preview: SpellingImportPreview) -> some View {
        let saved = preview.rows.filter { $0.status == .existing || $0.status == .duplicate }.count
        let errors = preview.rows.filter { isInvalid($0.status) }.count
        return HStack(spacing: 14) {
            count(preview.additions.count, "new")
            separator
            count(saved, "already saved")
            separator
            count(errors, errors == 1 ? "error" : "errors", danger: errors > 0)
        }
        .designEyebrow().tracking(1).fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var separator: some View { Text("|").foregroundStyle(DesignPalette.hair).accessibilityHidden(true) }

    private func count(_ value: Int, _ label: String, danger: Bool = false) -> some View {
        let tint = danger ? DesignPalette.danger : DesignPalette.ink
        return Text("\(Text("\(value)").foregroundStyle(tint).fontWeight(danger ? .semibold : .regular)) \(Text(label).foregroundStyle(danger ? DesignPalette.danger : DesignPalette.ink3))")
    }

    // MARK: Table

    private func visibleRows(_ preview: SpellingImportPreview) -> [SpellingImportPreview.Row] {
        preview.rows.enumerated().filter { $0.offset < Self.previewRows || isInvalid($0.element.status) }.map(\.element)
    }

    private func table(_ preview: SpellingImportPreview) -> some View {
        let shown = visibleRows(preview)
        let hidden = preview.rows.count - shown.count
        return DesignCard {
            columns(row: "Row", heard: "Heard as", written: "Write as", result: "Result", header: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { DesignHairline() }
                        columns(
                            row: String(row.id), heard: row.rule.heard, written: row.rule.written,
                            result: resultLabel(row.status), invalid: isInvalid(row.status), warning: row.everydayWarning)
                    }
                    if hidden > 0 {
                        DesignHairline()
                        Text("… and \(hidden) more row\(hidden == 1 ? "" : "s")").font(DesignFont.sans(DesignFont.caption))
                            .foregroundStyle(DesignPalette.ink3).padding(.horizontal, 14).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 300).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func columns(
        row: String, heard: String, written: String, result: String, invalid: Bool = false,
        warning: String? = nil, header: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(row).font(header ? DesignFont.mono(DesignFont.eyebrow) : DesignFont.mono(11)).monospacedDigit()
                .foregroundStyle(DesignPalette.ink3).frame(width: 32, alignment: .leading)
            cell(heard, header: header)
            cell(written, header: header)
            VStack(alignment: .leading, spacing: 1) {
                Text(result).font(header ? DesignFont.mono(DesignFont.eyebrow) : DesignFont.sans(DesignFont.detail, invalid ? .medium : .regular))
                    .foregroundStyle(invalid ? DesignPalette.danger : (header ? DesignPalette.ink3 : DesignPalette.ink2))
                if let warning {
                    Text(warning).font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.orange)
                }
            }.frame(width: 170, alignment: .leading)
        }
        .textCase(header ? .uppercase : nil)
        .tracking(header ? DesignFont.eyebrowTracking : 0)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func cell(_ text: String, header: Bool) -> some View {
        Group {
            if header {
                Text(text).font(DesignFont.mono(DesignFont.eyebrow)).foregroundStyle(DesignPalette.ink3)
            } else if text.isEmpty {
                Text("Blank").font(DesignFont.sans(DesignFont.body)).italic().foregroundStyle(DesignPalette.ink3)
            } else {
                Text(text).font(DesignFont.sans(DesignFont.body)).foregroundStyle(DesignPalette.ink)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resultLabel(_ status: SpellingImportPreview.Row.Status) -> String {
        switch status {
        case .add: "New"
        case let .invalid(message): "Error · \(message)"
        default: status.label
        }
    }

    // MARK: Footer

    /// Why Import is off, or the usual reassurance. Mirrors `SpellingEditor.canImport`.
    private var footnote: String {
        guard !editor.canImport else { return "Nothing changes until you import." }
        if let preview = editor.importPreview, preview.rows.contains(where: { isInvalid($0.status) }) {
            return "Nothing changes until you import. Fix the errors in the file, then choose it again."
        }
        if editor.importError != nil || editor.importPreview?.problem != nil {
            return "Nothing changes until you import. Fix the file, then choose it again."
        }
        if let preview = editor.importPreview, preview.additions.isEmpty {
            return "Nothing new to import. Every row is already saved or repeated."
        }
        return "Nothing changes until you import. Finish or discard your open edit first."
    }

    private func isInvalid(_ status: SpellingImportPreview.Row.Status) -> Bool {
        if case .invalid = status { true } else { false }
    }
}
