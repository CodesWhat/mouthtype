import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The open and save panels for the Transcribe file page. Both attach as sheets to the Mouthtype window.
@MainActor enum FileTranscriptionPanels {
    static func chooseFile(model: FileTranscriptionModel, over window: NSWindow?) {
        guard !model.isBusy, let window else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose an audio file"
        panel.prompt = "Transcribe"
        panel.message = "WAV, AIFF or M4A. Up to 10 minutes and 512 MB. Your original stays unchanged."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = MacAudioFileDecoder.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let source = panel.url else { return }
            model.start(source)
        }
    }

    static func saveText(model: FileTranscriptionModel, over window: NSWindow?) {
        guard !model.isBusy, model.hasResult, let window else { return }
        let panel = NSSavePanel()
        panel.title = "Save transcript"
        panel.allowedContentTypes = [.utf8PlainText]
        panel.allowsOtherFileTypes = false
        panel.nameFieldStringValue = (model.filename as NSString).deletingPathExtension + ".txt"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try model.save(to: url) }
            catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't save the transcript"
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: window)
            }
        }
    }
}

struct FileTranscriptionView: View {
    let model: FileTranscriptionModel
    var choose: () -> Void
    var save: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("WAV, AIFF or M4A. Up to 10 minutes and 512 MB.")
                .font(DesignFont.sans(DesignFont.body)).foregroundStyle(DesignPalette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Choose Audio File\u{2026}", action: choose).buttonStyle(.designPrimary)
                    .disabled(model.isBusy).accessibilityLabel("Choose an audio file").accessibilityIdentifier("file-choose")
                Spacer()
                if model.isBusy {
                    ProgressView().controlSize(.small)
                    Button("Cancel", action: model.cancel).buttonStyle(.designSecondary)
                        .disabled(model.state == .cancelling).accessibilityLabel("Cancel transcription")
                        .accessibilityIdentifier("file-cancel")
                }
            }
            Text(status).font(DesignFont.sans(DesignFont.detail))
                .foregroundStyle(model.state == .failed ? Color.red : DesignPalette.ink2)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("file-status")
            ScrollView {
                Text(model.hasResult ? model.text : "Your transcript appears here. Nothing is pasted automatically.")
                    .font(DesignFont.sans(DesignFont.body))
                    .textSelection(.enabled).foregroundStyle(model.hasResult ? DesignPalette.ink : DesignPalette.ink3)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(14).accessibilityIdentifier("file-result")
            }.frame(minHeight: 200, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 12).fill(DesignPalette.surface))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DesignPalette.hair2, lineWidth: 1))
            HStack(spacing: 8) {
                Button("Copy", action: model.copy).buttonStyle(.designSecondary)
                    .disabled(!model.hasResult || model.isBusy).accessibilityLabel("Copy transcript").accessibilityIdentifier("file-copy")
                Button("Save Text\u{2026}", action: save).buttonStyle(.designSecondary)
                    .disabled(!model.hasResult || model.isBusy).accessibilityLabel("Save transcript as text").accessibilityIdentifier("file-save")
                Spacer()
                Text("Raw transcript \u{00B7} On your Mac").font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink3)
            }
        }.padding(.horizontal, 24).padding(.top, 6).padding(.bottom, 16)
    }

    private var status: String {
        switch model.state {
        case .idle: "Choose a file. Your original stays unchanged."
        case .preparing: "Preparing \(model.filename)…"
        case .transcribing: "Transcribing \(model.filename)…"
        case .cancelling: "Cancelling. Waiting for current work to finish…"
        case .finished: "Transcript ready: \(model.filename)"
        case .empty: "No speech found in \(model.filename)."
        case .cancelled: "Cancelled. Your original file is unchanged."
        case .failed: model.errorMessage ?? "The file could not be transcribed. Your original is unchanged."
        }
    }
}

/// The Transcribe file page. Without an import model, as in most tests, it says so.
struct FileTranscriptionHostPage: View {
    var model: SettingsModel
    var actions: SettingsActions

    var body: some View {
        if let transcription = model.fileTranscription {
            FileTranscriptionView(model: transcription, choose: actions.chooseAudioFile, save: actions.saveTranscript)
        } else {
            Text("File transcription is unavailable.").font(DesignFont.sans(DesignFont.body)).foregroundStyle(DesignPalette.ink2)
                .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
