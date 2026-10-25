import AppKit

@MainActor
enum CleanupModelDownloadConfirmation {
    static func askToDownload(name: String, sizeMB: Int) -> Bool {
        let size = sizeMB >= 1000 ? String(format: "%.1f GB", Double(sizeMB) / 1000) : "\(sizeMB) MB"
        let alert = NSAlert()
        alert.messageText = "Download \(name)?"
        alert.informativeText =
            "It's \(size), fetched from Hugging Face, and runs on this Mac. "
            + "Only the selected cleanup model is downloaded."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}
