import SwiftUI

struct SpellingImportView: View {
    @Bindable var editor: SpellingEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Import spellings").font(.custom("InstrumentSerif-Regular", size: 30))
                Text(editor.importFileName).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Use heard,written columns for exact aliases, or a name column for names alone. Include a header row.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Existing spellings stay unchanged. Conflicts must be fixed before importing.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(24)
            Divider()
            if let preview = editor.importPreview, !preview.rows.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(summary(preview)).font(.callout).foregroundStyle(.secondary)
                    columns(row: "Row", heard: "Heard as", written: "Write as", result: "Result")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Divider()
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(preview.rows) { row in
                                columns(row: String(row.id), heard: row.rule.heard, written: row.rule.written,
                                    result: row.status.label, invalid: isInvalid(row.status))
                                    .padding(.vertical, 10)
                                Divider()
                            }
                        }
                    }
                }.padding(.horizontal, 24).padding(.vertical, 16)
            } else {
                Spacer(minLength: 20)
            }
            if let message = editor.importError ?? editor.importPreview?.problem {
                Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24).padding(.vertical, 16)
            }
            Divider()
            HStack {
                Text("Nothing changes until you import.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { editor.cancelImport() }.keyboardShortcut(.cancelAction)
                let count = editor.importPreview?.additions.count ?? 0
                Button("Import \(count) Spelling\(count == 1 ? "" : "s")") { editor.confirmImport() }
                    .buttonStyle(.borderedProminent).disabled(!editor.canImport)
                    .accessibilityIdentifier("spelling-confirm-import")
            }.padding(20)
        }.background(Color(nsColor: .windowBackgroundColor))
    }

    private func columns(row: String, heard: String, written: String, result: String, invalid: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(row).monospacedDigit().frame(width: 30, alignment: .leading).foregroundStyle(.secondary)
            Text(heard.isEmpty ? "Blank" : heard).frame(maxWidth: .infinity, alignment: .leading)
            Text(written.isEmpty ? "Blank" : written).frame(maxWidth: .infinity, alignment: .leading)
            Text(result).foregroundStyle(invalid ? Color.red : Color.secondary).frame(width: 175, alignment: .leading)
        }.fixedSize(horizontal: false, vertical: true)
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
