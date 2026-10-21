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

enum SelectionCleanupError: Error { case unavailable, timedOut }

@MainActor protocol SelectionEditing {
    func capture() throws -> SelectedText
    /// A capture that gives up once `budget` seconds have passed, for callers that can't block (the menu).
    func capture(budget: TimeInterval) throws -> SelectedText
    func replace(_ original: SelectedText, with replacement: String) -> Bool
}

extension SelectionEditing {
    func capture(budget: TimeInterval) throws -> SelectedText { try capture() }
}

/// What the menu-open capture found.
enum MenuCapture: Equatable { case ready, unavailable, timedOut }

@MainActor final class AccessibilitySelectionEditor: SelectionEditing {
    private let focus: any FocusReading
    private let readRange: (FocusedElement) -> NSRange?
    private let readText: (FocusedElement) -> String?
    private let writeText: (FocusedElement, String) -> Bool
    private let setTimeout: (FocusedElement, Float) -> Void

    convenience init() {
        self.init(focus: AccessibilityFocusReader(), readRange: Self.selectedRange,
                  readText: Self.selectedText, writeText: Self.setSelectedText)
    }

    init(focus: any FocusReading, readRange: @escaping (FocusedElement) -> NSRange?,
         readText: @escaping (FocusedElement) -> String?, writeText: @escaping (FocusedElement, String) -> Bool,
         setTimeout: @escaping (FocusedElement, Float) -> Void = { AXUIElementSetMessagingTimeout($0.ref, $1) }) {
        self.setTimeout = setTimeout
        self.focus = focus
        self.readRange = readRange
        self.readText = readText
        self.writeText = writeText
    }

    func capture(budget: TimeInterval) throws -> SelectedText {
        AccessibilityFocusReader.deadline = Date().addingTimeInterval(budget)
        defer { AccessibilityFocusReader.deadline = nil }
        return try capture()
    }

    func capture() throws -> SelectedText {
        let snapshot = focus.snapshot()
        if AccessibilityFocusReader.deadlinePassed { throw SelectionCleanupError.timedOut }
        guard !snapshot.isSecure, !focus.isSecureInputEnabled,
              let pid = snapshot.pid, snapshot.focusedOwnerPID == pid,
              let element = snapshot.element,
              ["AXTextField", "AXTextArea", "AXComboBox"].contains(snapshot.role ?? "") else {
            throw SelectionCleanupError.unavailable
        }
        let range = readRange(element)
        if AccessibilityFocusReader.deadlinePassed { throw SelectionCleanupError.timedOut }
        guard let range, range.location >= 0, (1...16_000).contains(range.length),
              let text = readText(element), !text.isEmpty, text.utf16.count == range.length else {
            throw SelectionCleanupError.unavailable
        }
        return SelectedText(pid: pid, element: element, range: range, text: text)
    }

    func replace(_ original: SelectedText, with replacement: String) -> Bool {
        guard !replacement.isEmpty, replacement.utf16.count <= 16_000,
              (try? capture()) == original, let element = original.element else { return false }
        // The captured reference kept the capture's shortened timeout. 0 restores the system default the insertion path uses.
        setTimeout(element, 0)
        // The user explicitly accepts this edit. No clipboard paste, keyboard events or retry.
        return writeText(element, replacement)
    }

    private static func selectedRange(_ element: FocusedElement) -> NSRange? {
        AXUIElementSetMessagingTimeout(element.ref, AccessibilityFocusReader.callTimeout())
        return AccessibilityFocusReader.selectedRange(element.ref)
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
    private let transformer: (any SelectionTransforming)?
    private let busy: () -> Bool
    private let changed: () -> Void
    private let styleFor: (SelectedText) -> StyleOptions
    private let appName: (pid_t) -> String?
    private let captureBudget: TimeInterval
    private var captured: SelectedText?
    /// The tone behind the deterministic cleanup of the captured selection.
    @ObservationIgnored private var style = StyleOptions.formal
    @ObservationIgnored private var transformTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    private(set) var original = ""
    var result = ""
    private(set) var message = ""
    private(set) var submitted = false
    /// The name of the app that owns the captured selection.
    private(set) var sourceApp: String?
    /// True once Accept was refused because the selection changed or the app wouldn't take the write.
    private(set) var refused = false
    var refusalTitle: String {
        "The selection changed, or \(sourceApp ?? "the app") refused the replacement."
    }
    var refusalDetail: String {
        "Select the text again and reopen Transform Selection, or copy the result and paste it yourself."
    }
    /// The AI transform behind the current preview, or nil for Basic cleanup.
    private(set) var transform: TextTransform?
    private(set) var isTransforming = false
    var hasPreview: Bool { captured != nil }
    var canAccept: Bool {
        captured != nil && !submitted && !refused && !isTransforming && !result.isEmpty && result.utf16.count <= 16_000
    }
    /// The preview can be edited once a result exists and nothing is generating, so a late result can't overwrite edits.
    var isEditable: Bool { captured != nil && !submitted && !isTransforming }
    var canRetry: Bool { captured != nil && transform != nil && !submitted && !isTransforming }
    /// Why the AI transforms are disabled, or nil when they can run.
    var transformUnavailableReason: String? {
        guard let transformer else { return "AI transforms aren’t available in this build." }
        return transformer.transformUnavailableReason
    }
    var canChooseTransform: Bool { captured != nil && !submitted && !isTransforming && transformUnavailableReason == nil }
    var canChooseBasic: Bool { captured != nil && !submitted && !isTransforming && transform != nil }

    init(editor: any SelectionEditing, transformer: (any SelectionTransforming)? = nil,
         busy: @escaping () -> Bool = { false }, changed: @escaping () -> Void = {},
         styleFor: @escaping (SelectedText) -> StyleOptions = { _ in .formal },
         appName: @escaping (pid_t) -> String? = { NSRunningApplication(processIdentifier: $0)?.localizedName },
         captureBudget: TimeInterval = 0.15) {
        self.styleFor = styleFor
        self.appName = appName
        self.captureBudget = captureBudget
        self.editor = editor
        self.transformer = transformer
        self.busy = busy
        self.changed = changed
    }

    /// Reads the selection as the menu opens, so the menu can enable its items.
    /// Time-boxed: the AX calls each get a shrinking timeout, and a capture that still ran past `budget` is discarded.
    func captureForMenu(budget: TimeInterval = 0.15) -> MenuCapture {
        let start = ContinuousClock.now
        do { _ = try editor.capture(budget: budget) }
        catch SelectionCleanupError.timedOut { return .timedOut }
        catch { return .unavailable }
        if start.duration(to: .now) > .seconds(budget) { return .timedOut }
        return .ready
    }

    /// Captures the selection (time-boxed like the menu read) and previews either Basic cleanup or, when `requested` is set,
    /// an AI transform. Basic cleanup runs the pipeline with the focused app's tone.
    func prepare(transform requested: TextTransform? = nil) {
        cancel()
        guard !busy() else { message = "Finish the current dictation or file job first."; return }
        if requested != nil, let reason = transformUnavailableReason {
            message = reason
            return
        }
        do {
            let selection: SelectedText
            do { selection = try editor.capture(budget: captureBudget) }
            catch SelectionCleanupError.timedOut {
                message = "Couldn’t read the selection in time. Try again."
                return
            }
            guard !selection.text.isEmpty, selection.text.utf16.count <= 16_000 else { throw SelectionCleanupError.unavailable }
            style = styleFor(selection)
            if let requested {
                captured = selection
                sourceApp = appName(selection.pid)
                original = selection.text
                changed()
                begin(requested)
                return
            }
            let cleaned = Self.basicCleanup(selection.text, style: style)
            guard !cleaned.isEmpty, cleaned.utf16.count <= 16_000 else { throw SelectionCleanupError.unavailable }
            captured = selection
            sourceApp = appName(selection.pid)
            original = selection.text
            result = cleaned
            message = Self.basicMessage
            changed()
        } catch {
            message = "Select up to 16,000 characters in an accessible text field, then try again. Password fields aren’t read."
        }
    }

    /// Runs another transform on the same captured selection. Accept still checks the original selection.
    func choose(_ kind: TextTransform) {
        guard captured != nil, !submitted, !isTransforming else { return }
        if let reason = transformUnavailableReason { message = reason; return }
        begin(kind)
    }

    /// Back to the deterministic Basic cleanup of the same captured selection.
    func chooseBasic() {
        guard canChooseBasic else { return }
        generation += 1
        transformTask?.cancel()
        transform = nil
        let cleaned = Self.basicCleanup(original, style: style)
        result = cleaned
        message = cleaned.isEmpty ? "Basic cleanup left nothing. Pick a transform or cancel." : Self.basicMessage
    }

    func retry() {
        guard canRetry, let transform else { return }
        begin(transform)
    }

    private func begin(_ kind: TextTransform) {
        guard let transformer, captured != nil else { return }
        transformTask?.cancel()
        generation += 1
        let id = generation
        transform = kind
        isTransforming = true
        result = ""
        message = "\(kind.title) is running on the local model. Nothing leaves this Mac."
        let text = original
        transformTask = Task { [weak self] in
            do {
                let output = try await transformer.transform(kind, text: text)
                self?.finish(id, kind, .success(output))
            } catch {
                self?.finish(id, kind, .failure(error))
            }
        }
    }

    private func finish(_ id: Int, _ kind: TextTransform, _ outcome: Result<String, Error>) {
        guard id == generation, captured != nil else { return }
        isTransforming = false
        switch outcome {
        case let .success(output):
            let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                message = "The model returned nothing. Retry, pick another transform, or cancel."
            } else if text.utf16.count > 16_000 {
                message = "The result is over 16,000 characters. Retry or cancel."
            } else {
                result = text
                message = "\(kind.title) preview from the local model. Review and edit it before accepting."
            }
        case let .failure(error):
            if let cleaner = error as? CleanerError, case let .unavailable(reason) = cleaner {
                message = reason
            } else if let cleaner = error as? CleanerError, cleaner == .outputTruncated || cleaner == .outputTooLong {
                message = cleaner == .outputTruncated
                    ? "\(kind.title) ran past the model's length limit, so the result was cut off and can't be used. Try a shorter selection, or cancel."
                    : "\(kind.title) returned far more text than the selection, so the result can't be used. Retry, or cancel."
            } else {
                message = "\(kind.title) failed. Retry, or cancel."
            }
        }
        changed()
    }

    private static let basicMessage = "Basic cleanup: fillers and spoken commands only. Names and numbers aren’t rewritten."

    /// Cleanup and the model both trim their output, so put the selection's own leading and trailing whitespace back.
    /// Without it a selection ending in a space or newline would run into whatever follows it.
    static func restoringBoundaryWhitespace(of original: String, in result: String) -> String {
        let leading = original.prefix(while: \.isWhitespace)
        let trailing = original.reversed().prefix(while: \.isWhitespace).reversed()
        return leading + result.trimmingCharacters(in: .whitespacesAndNewlines) + String(trailing)
    }

    /// The deterministic stages plus the tone pass. Formal also softens swearing; the other tones leave it as written.
    private static func basicCleanup(_ text: String, style: StyleOptions) -> String {
        let options = TextPipelineOptions(fillers: true, spokenCommands: true, selfCorrection: false, countedLists: false,
            notation: false, numbers: false, dictionary: false, snippets: false, blend: false, whitespace: true,
            profanity: true, style: style)
        return TextPipeline().run(TextPipelineInput(text: text, options: options)).text
    }

    func accept() {
        guard let captured, canAccept else { return }
        guard !busy() else {
            message = "Finish the current dictation or file job first."
            return
        }
        let replacement = Self.restoringBoundaryWhitespace(of: captured.text, in: result)
        guard editor.replace(captured, with: replacement) else {
            refused = true
            return
        }
        submitted = true
        message = transform == nil
            ? "Replacement requested. Check the original field. You can still copy the result."
            : "Replacement requested. Check the original field. To undo, press Cmd-Z in that app, or copy the original text from here."
    }

    func cancel() {
        generation += 1
        transformTask?.cancel()
        transformTask = nil
        captured = nil
        original = ""
        result = ""
        message = ""
        submitted = false
        transform = nil
        sourceApp = nil
        refused = false
        isTransforming = false
        changed()
    }
}

extension TextTransform {
    /// The label on the panel's chip and the menu item.
    var chipTitle: String {
        switch self {
        case .fixGrammar: "Fix grammar"
        case .shorter: "Make shorter"
        case .moreFormal: "More formal"
        case .moreCasual: "More casual"
        }
    }
}
