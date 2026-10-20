import SwiftUI

struct SpellingImportView: View {
    @Bindable var editor: SpellingEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    DesignEyebrow("Import spellings")
                    Spacer()
                    DesignCloseButton(label: "Close without importing") { editor.cancelImport() }
                }
                Text("Import spellings").font(DesignFont.serif(DesignFont.display + 2)).foregroundStyle(DesignPalette.ink)
                    .accessibilityAddTraits(.isHeader)
                note(editor.importFileName)
                note("Use heard,written columns for exact aliases, or a name column for names alone. Include a header row.")
                note("Existing spellings stay unchanged. Conflicts must be fixed before importing.")
            }.padding(24)
            DesignHairline()
            if let preview = editor.importPreview, !preview.rows.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    note(summary(preview))
                    columns(row: "Row", heard: "Heard as", written: "Write as", result: "Result", header: true)
                    DesignHairline()
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(preview.rows) { row in
                                columns(row: String(row.id), heard: row.rule.heard, written: row.rule.written,
                                    result: row.status.label, invalid: isInvalid(row.status), warning: row.everydayWarning)
                                    .padding(.vertical, 10)
                                DesignHairline()
                            }
                        }
                    }
                }.padding(.horizontal, 24).padding(.vertical, 16)
            } else {
                Spacer(minLength: 20)
            }
            if let message = editor.importError ?? editor.importPreview?.problem {
                Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                    .font(DesignFont.sans(DesignFont.detail)).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24).padding(.vertical, 16)
            }
            DesignHairline()
            HStack {
                note("Nothing changes until you import.")
                Spacer()
                Button("Cancel") { editor.cancelImport() }.buttonStyle(.designSecondary).keyboardShortcut(.cancelAction)
                let count = editor.importPreview?.additions.count ?? 0
                Button("Import \(count) Spelling\(count == 1 ? "" : "s")") { editor.confirmImport() }
                    .buttonStyle(.designPrimary).disabled(!editor.canImport)
                    .accessibilityIdentifier("spelling-confirm-import")
            }.padding(20)
        }.background(DesignPalette.bg)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(DesignFont.sans(DesignFont.detail)).foregroundStyle(DesignPalette.ink2).fixedSize(horizontal: false, vertical: true)
    }

    private func columns(row: String, heard: String, written: String, result: String, invalid: Bool = false,
                         warning: String? = nil, header: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(row).monospacedDigit().frame(width: 30, alignment: .leading).foregroundStyle(DesignPalette.ink2)
            Text(heard.isEmpty ? "Blank" : heard).frame(maxWidth: .infinity, alignment: .leading)
            Text(written.isEmpty ? "Blank" : written).frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(result).foregroundStyle(invalid ? Color.red : DesignPalette.ink2)
                if let warning { Text(warning).font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.orange) }
            }.frame(width: 175, alignment: .leading)
        }
        .font(header ? DesignFont.mono(DesignFont.eyebrow) : DesignFont.sans(DesignFont.body))
        .foregroundStyle(header ? DesignPalette.ink3 : DesignPalette.ink)
        .textCase(header ? .uppercase : nil)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func isInvalid(_ status: SpellingImportPreview.Row.Status) -> Bool {
        if case .invalid = status { true } else { false }
    }

    private func summary(_ preview: SpellingImportPreview) -> String {
        let skipped = preview.rows.filter { $0.status == .existing || $0.status == .duplicate }.count
        let invalid = preview.rows.filter { isInvalid($0.status) }.count
        return "\(preview.additions.count) new · \(skipped) already saved or repeated · \(invalid) errors"
    }
}
