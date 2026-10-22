import AppKit
import SwiftUI

/// The Transcribe Audio File window. It is its own window because the menu bar opens it when no Mouthtype window is up.
/// Closing it cancels a running transcription, as closing the old window did; the choose and save panels attach to it.
@MainActor final class FileTranscriptionWindow: NSWindowController, NSWindowDelegate {
    let model: FileTranscriptionModel

    init(model: FileTranscriptionModel) {
        self.model = model
        let window = TranscribeNSWindow(
            contentRect: NSRect(origin: .zero, size: FileTranscriptionView.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Transcribe Audio File"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentMinSize = FileTranscriptionView.minimumSize
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        super.init(window: window)
        let hosting = NSHostingView(
            rootView: FileTranscriptionView(
                model: model,
                choose: { [weak self] in FileTranscriptionPanels.chooseFile(model: model, over: self?.window) },
                save: { [weak self] in FileTranscriptionPanels.saveText(model: model, over: self?.window) }))
        hosting.sizingOptions = []
        window.contentView = hosting
        window.setContentSize(FileTranscriptionView.size)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    /// Opens the window, or brings it forward if it is already up.
    func present() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { model.cancel() }
}

/// The app runs without a main menu, so nothing supplies Cmd-W; handle it here.
final class TranscribeNSWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown, flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
