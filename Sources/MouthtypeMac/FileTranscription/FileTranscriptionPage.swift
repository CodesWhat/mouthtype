import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The open and save panels for the Transcribe Audio File window. Both attach as sheets to it.
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

/// The Transcribe Audio File window content: header, a file row with its status chip, the raw transcript card, then Copy and Save Text.
struct FileTranscriptionView: View {
    static let size = NSSize(width: 720, height: 540)
    static let minimumSize = NSSize(width: 600, height: 460)

    let model: FileTranscriptionModel
    var choose: () -> Void
    var save: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DesignPageHeader(title: "Transcribe an audio file.", summary: "WAV, AIFF or M4A, up to 10 minutes and 512 MB. Your original stays unchanged.", titleSize: 26)
            fileCard
            transcriptCard
            HStack(spacing: 8) {
                Button("Copy", action: model.copy).buttonStyle(.designSecondary)
                    .disabled(!model.hasResult || model.isBusy).accessibilityLabel("Copy transcript").accessibilityIdentifier("file-copy")
                Button("Save Text\u{2026}", action: save).buttonStyle(.designSecondary)
                    .disabled(!model.hasResult || model.isBusy).accessibilityLabel("Save transcript as text").accessibilityIdentifier("file-save")
                Spacer(minLength: 8)
                Text("On your Mac \u{00B7} Nothing is pasted automatically").designEyebrow().fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 28).padding(.top, 40).padding(.bottom, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DesignPalette.bg)
        .font(DesignFont.sans(DesignFont.body))
        .foregroundStyle(DesignPalette.ink)
        .tint(SettingsTheme.control)
    }

    // MARK: File row

    private var hasFile: Bool { model.state != .idle && !(model.state == .failed && !model.hasResult && model.filename.isEmpty) }

    private var fileCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "music.note").font(.system(size: 16, weight: .medium)).foregroundStyle(DesignPalette.accentText)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(DesignPalette.c1)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.filename.isEmpty ? "No file chosen" : model.filename)
                        .font(DesignFont.sans(DesignFont.body, .medium)).foregroundStyle(model.filename.isEmpty ? DesignPalette.ink2 : DesignPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                chip
                if model.isBusy {
                    Button("Cancel", action: model.cancel).buttonStyle(.designSecondary)
                        .disabled(model.state == .cancelling).accessibilityLabel("Cancel transcription").accessibilityIdentifier("file-cancel")
                } else if hasFile {
                    Button("Choose Another\u{2026}", action: choose).buttonStyle(.designSecondary)
                        .accessibilityLabel("Choose another audio file").accessibilityIdentifier("file-choose")
                } else {
                    Button("Choose Audio File\u{2026}", action: choose).buttonStyle(.designPrimary)
                        .accessibilityLabel("Choose an audio file").accessibilityIdentifier("file-choose")
                }
            }.padding(.horizontal, 16).padding(.vertical, 12)
            if model.isBusy {
                ProgressView().progressViewStyle(.linear).tint(DesignPalette.accentMark)
                    .padding(.horizontal, 16).padding(.bottom, 12).accessibilityLabel("Transcribing")
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DesignPalette.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DesignPalette.hair2, lineWidth: 1))
    }

    private var detail: String {
        let parts = [model.duration.map(Self.durationText), model.fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }]
        let text = parts.compactMap { $0 }.joined(separator: " \u{00B7} ")
        return text.isEmpty ? (model.filename.isEmpty ? "Pick one WAV, AIFF or M4A file." : "Length shows when it finishes.") : text
    }

    static func durationText(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded()))
        return whole >= 60 ? "\(whole / 60) min \(whole % 60) s" : "\(whole) s"
    }

    private var chip: some View {
        let tone = chipTone
        return HStack(spacing: 6) {
            Circle().fill(tone.dot).frame(width: 6, height: 6)
            Text(chipText)
        }
        .font(DesignFont.mono(DesignFont.eyebrow)).tracking(0.8).textCase(.uppercase).foregroundStyle(tone.text)
        .fixedSize().accessibilityElement(children: .combine).accessibilityIdentifier("file-status")
    }

    private var chipText: String {
        switch model.state {
        case .idle: "No file"
        case .preparing: "Preparing\u{2026}"
        case .transcribing: "Transcribing\u{2026}"
        case .cancelling: "Cancelling\u{2026}"
        case .finished: "Transcript ready"
        case .empty: "No speech found"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        }
    }

    private var chipTone: (dot: Color, text: Color) {
        switch model.state {
        case .finished, .preparing, .transcribing: (DesignPalette.accentMark, DesignPalette.accentText)
        case .failed: (DesignPalette.danger, DesignPalette.danger)
        case .idle, .cancelling, .empty, .cancelled: (DesignPalette.ink3, DesignPalette.ink3)
        }
    }

    // MARK: Transcript

    private var transcriptCard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.hasResult ? "Transcript \u{00B7} \(model.wordCount) \(model.wordCount == 1 ? "word" : "words")" : "Transcript")
                    .designEyebrow().accessibilityIdentifier("file-count")
                Spacer(minLength: 8)
                Text("Raw \u{00B7} No cleanup").designEyebrow().tracking(0.8)
            }.padding(.horizontal, 16).padding(.vertical, 10)
            DesignHairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let notice {
                        Text(notice.text).font(DesignFont.sans(DesignFont.detail)).foregroundStyle(notice.failed ? DesignPalette.danger : DesignPalette.ink2)
                            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("file-notice")
                    }
                    if model.hasResult {
                        Text(model.text).font(DesignFont.sans(DesignFont.body)).lineSpacing(3).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("file-result")
                    } else if notice?.text == nil {
                        Text(model.isBusy ? "Your transcript appears here when it\u{2019}s done." : "Your transcript appears here. Nothing is pasted automatically.")
                            .font(DesignFont.sans(DesignFont.body)).foregroundStyle(DesignPalette.ink3)
                            .accessibilityIdentifier("file-result")
                    }
                }.frame(maxWidth: .infinity, alignment: .topLeading).padding(.horizontal, 16).padding(.vertical, 14)
            }
        }
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DesignPalette.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DesignPalette.hair2, lineWidth: 1))
    }

    private var notice: (text: String, failed: Bool)? {
        switch model.state {
        case .cancelling: return ("Cancelling. Waiting for current work to finish\u{2026}", false)
        case .empty: return ("No speech found in \(model.filename).", false)
        case .cancelled: return ("Cancelled. Your original file is unchanged.", false)
        case .failed:
            let reason = model.errorMessage ?? "The file could not be transcribed. Your original is unchanged."
            let name = model.failedFilename.map { "Couldn\u{2019}t transcribe \($0). " } ?? ""
            return (name + reason + (model.hasResult ? " The previous transcript is still here." : ""), true)
        case .idle, .preparing, .transcribing, .finished: return nil
        }
    }
}
