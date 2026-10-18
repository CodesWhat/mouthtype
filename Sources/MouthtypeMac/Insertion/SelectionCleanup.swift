import AppKit
import ApplicationServices
import MouthtypeCore
import Observation

struct SelectedText: Equatable {
    var pid: pid_t
    var element: FocusedElement?
    var range: NSRange
    var text: String
}

enum SelectionCleanupError: Error { case unavailable }

@MainActor protocol SelectionEditing {
    func capture() throws -> SelectedText
    func replace(_ original: SelectedText, with replacement: String) -> Bool
}

@MainActor final class AccessibilitySelectionEditor: SelectionEditing {
    private let focus: any FocusReading
    private let readRange: (FocusedElement) -> NSRange?
    private let readText: (FocusedElement) -> String?
    private let writeText: (FocusedElement, String) -> Bool

    convenience init() {
        self.init(focus: AccessibilityFocusReader(), readRange: Self.selectedRange,
                  readText: Self.selectedText, writeText: Self.setSelectedText)
    }

    init(focus: any FocusReading, readRange: @escaping (FocusedElement) -> NSRange?,
         readText: @escaping (FocusedElement) -> String?, writeText: @escaping (FocusedElement, String) -> Bool) {
        self.focus = focus
        self.readRange = readRange
        self.readText = readText
        self.writeText = writeText
    }

    func capture() throws -> SelectedText {
        let snapshot = focus.snapshot()
        guard !snapshot.isSecure, !focus.isSecureInputEnabled,
              let pid = snapshot.pid, snapshot.focusedOwnerPID == pid,
              let element = snapshot.element,
              ["AXTextField", "AXTextArea", "AXComboBox"].contains(snapshot.role ?? "") else {
            throw SelectionCleanupError.unavailable
        }
        guard let range = readRange(element), range.location >= 0, (1...16_000).contains(range.length),
              let text = readText(element), !text.isEmpty, text.utf16.count == range.length else {
            throw SelectionCleanupError.unavailable
        }
        return SelectedText(pid: pid, element: element, range: range, text: text)
    }

    func replace(_ original: SelectedText, with replacement: String) -> Bool {
        guard !replacement.isEmpty, replacement.utf16.count <= 16_000,
              (try? capture()) == original, let element = original.element else { return false }
        // The user explicitly accepts this edit. No clipboard paste, keyboard events or retry.
        return writeText(element, replacement)
    }

    private static func selectedRange(_ element: FocusedElement) -> NSRange? {
        AXUIElementSetMessagingTimeout(element.ref, AccessibilityFocusReader.messagingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element.ref, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private static func selectedText(_ element: FocusedElement) -> String? {
        var text: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element.ref, kAXSelectedTextAttribute as CFString, &text) == .success else { return nil }
        return text as? String
    }

    private static func setSelectedText(_ element: FocusedElement, _ replacement: String) -> Bool {
        AXUIElementSetAttributeValue(element.ref, kAXSelectedTextAttribute as CFString, replacement as CFString) == .success
    }
}

@MainActor @Observable final class SelectionCleanupModel {
    private let editor: any SelectionEditing
    private let busy: () -> Bool
    private let changed: () -> Void
    private var captured: SelectedText?
    private(set) var original = ""
    var result = ""
    private(set) var message = ""
    private(set) var submitted = false
    var acceptanceErrorPresented = false
    var hasPreview: Bool { captured != nil }
    var canAccept: Bool { captured != nil && !submitted && !result.isEmpty && result.utf16.count <= 16_000 }

    init(editor: any SelectionEditing, busy: @escaping () -> Bool = { false }, changed: @escaping () -> Void = {}) {
        self.editor = editor
        self.busy = busy
        self.changed = changed
    }

    func prepare() {
        cancel()
        guard !busy() else { message = "Finish the current dictation or file job first."; return }
        do {
            let selection = try editor.capture()
            guard !selection.text.isEmpty, selection.text.utf16.count <= 16_000 else { throw SelectionCleanupError.unavailable }
            let options = TextPipelineOptions(fillers: true, spokenCommands: true, selfCorrection: false, countedLists: false,
                notation: false, numbers: false, dictionary: false, snippets: false, blend: false, whitespace: true)
            let cleaned = TextPipeline().run(TextPipelineInput(text: selection.text, options: options)).text
            guard !cleaned.isEmpty, cleaned.utf16.count <= 16_000 else { throw SelectionCleanupError.unavailable }
            captured = selection
            original = selection.text
            result = cleaned
            message = "Basic cleanup preview. Review it before accepting. Names and numbers aren’t rewritten."
            changed()
        } catch {
            message = "Select up to 16,000 characters in an accessible text field, then try again. Password fields aren’t read."
        }
    }

    func accept() {
        guard let captured, canAccept else { return }
        guard !busy() else {
            message = "Finish the current dictation or file job first."
            acceptanceErrorPresented = true
            return
        }
        guard editor.replace(captured, with: result) else {
            message = "The selection changed or the app refused replacement. Select the original text again and reopen Clean Selected Text, or copy the result."
            acceptanceErrorPresented = true
            return
        }
        acceptanceErrorPresented = false
        submitted = true
        message = "Replacement requested. Check the original field. You can still copy the result."
    }

    func cancel() {
        captured = nil
        original = ""
        result = ""
        message = ""
        submitted = false
        acceptanceErrorPresented = false
        changed()
    }
}
