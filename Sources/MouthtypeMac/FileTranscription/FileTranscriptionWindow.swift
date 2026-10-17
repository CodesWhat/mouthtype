import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class FileTranscriptionWindow: NSWindowController, NSWindowDelegate {
    let model: FileTranscriptionModel

    init(model: FileTranscriptionModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Transcribe Audio File"
        window.minSize = NSSize(width: 560, height: 440)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: FileTranscriptionView(model: model, choose: { [weak self] in self?.chooseFile() }, save: { [weak self] in self?.saveText() }))
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func present() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) { model.cancel() }

    private func chooseFile() {
        guard !model.isBusy, let window else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose an audio file"
        panel.prompt = "Transcribe"
        panel.message = "WAV, AIFF or M4A. Up to 10 minutes and 512 MB. Your original stays unchanged."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = MacAudioFileDecoder.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let source = panel.url else { return }
            self?.model.start(source)
        }
    }

    private func saveText() {
        guard !model.isBusy, model.hasResult, let window else { return }
        let panel = NSSavePanel()
        panel.title = "Save transcript"
        panel.allowedContentTypes = [.utf8PlainText]
        panel.allowsOtherFileTypes = false
        panel.nameFieldStringValue = (model.filename as NSString).deletingPathExtension + ".txt"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do { try self.model.save(to: url) }
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
        VStack(alignment: .leading, spacing: 18) {
            Text("Transcribe an audio file.").font(.largeTitle)
            Text("WAV, AIFF or M4A. Up to 10 minutes and 512 MB.").foregroundStyle(.secondary)
            HStack {
                Button("Choose Audio File…", action: choose).disabled(model.isBusy).accessibilityIdentifier("file-choose")
                Spacer()
                if model.isBusy {
                    ProgressView().controlSize(.small)
                    Button("Cancel", action: model.cancel).disabled(model.state == .cancelling).accessibilityIdentifier("file-cancel")
                }
            }
            Text(status).foregroundStyle(model.state == .failed ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("file-status")
            ScrollView {
                Text(model.hasResult ? model.text : "Your transcript appears here. Nothing is pasted automatically.")
                    .textSelection(.enabled).foregroundStyle(model.hasResult ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(14).accessibilityIdentifier("file-result")
            }.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            HStack {
                Button("Copy", action: model.copy).disabled(!model.hasResult || model.isBusy).accessibilityIdentifier("file-copy")
                Button("Save Text…", action: save).disabled(!model.hasResult || model.isBusy).accessibilityIdentifier("file-save")
                Spacer()
                Text("Raw transcript · On your Mac").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(26).frame(minWidth: 510, minHeight: 360)
            .background(Color(nsColor: .windowBackgroundColor))
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
