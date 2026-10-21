import ApplicationServices
import Foundation
import Testing
@testable import MouthtypeMac

@MainActor private final class SelectionFocus: FocusReading {
    var current = FocusSnapshot(pid: 100, role: "AXTextArea",
        element: FocusedElement(AXUIElementCreateApplication(100)), focusedOwnerPID: 100)
    var isSecureInputEnabled = false
    func snapshot() -> FocusSnapshot { current }
    func textBeforeCursor(of element: FocusedElement) -> TextBeforeCursor { .unknown }
}

@MainActor private final class MenuTrackingFocus: FocusReading {
    var isSecureInputEnabled = false
    func snapshot() -> FocusSnapshot { FocusSnapshot(pid: 100) }
    func selectionSnapshot() -> FocusSnapshot {
        FocusSnapshot(pid: 100, role: "AXTextArea", element: FocusedElement(AXUIElementCreateApplication(100)), focusedOwnerPID: 100)
    }
    func textBeforeCursor(of element: FocusedElement) -> TextBeforeCursor { .unknown }
}

@MainActor private final class SelectionBoundary {
    let focus = SelectionFocus()
    var range: NSRange? = NSRange(location: 4, length: 9)
    var text: String? = "hi 👩🏽‍💻"
    var rangeReads = 0
    var textReads = 0
    var writes: [(FocusedElement, String)] = []
    var acceptsWrite = true
    var events: [String] = []

    func editor() -> AccessibilitySelectionEditor {
        AccessibilitySelectionEditor(focus: focus, readRange: { element in
            self.rangeReads += 1
            return self.range
        }, readText: { element in
            self.textReads += 1
            return self.text
        }, writeText: { element, text in
            self.events.append("write")
            self.writes.append((element, text))
            return self.acceptsWrite
        }, setTimeout: { _, seconds in
            self.events.append("timeout=\(seconds)")
        })
    }
}

@MainActor @Suite struct AccessibilitySelectionEditorTests {
    @Test func captureReadsTheAppFocusWhenTheSystemWideElementIsEmpty() throws {
        let editor = AccessibilitySelectionEditor(focus: MenuTrackingFocus(), readRange: { _ in NSRange(location: 0, length: 5) },
            readText: { _ in "hello" }, writeText: { _, _ in true }, setTimeout: { _, _ in })
        let selected = try editor.capture()
        #expect(selected.text == "hello")
        #expect(selected.pid == 100)
    }

    @Test func unchangedUnicodeSelectionWritesExactlyOnceThroughTheRealAdapter() throws {
        let fixture = SelectionBoundary()
        fixture.range?.length = fixture.text!.utf16.count
        let editor = fixture.editor()
        let selected = try editor.capture()
        #expect(fixture.writes.isEmpty)
        #expect(editor.replace(selected, with: "Hello 👩🏽‍💻"))
        #expect(fixture.writes.count == 1)
        #expect(fixture.writes.first?.0 == selected.element)
        #expect(fixture.writes.first?.1 == "Hello 👩🏽‍💻")
    }

    @Test(arguments: ["field", "app", "range", "text"])
    func changedSelectionAtAcceptNeverCallsTheSetter(change: String) throws {
        let fixture = SelectionBoundary()
        fixture.range?.length = fixture.text!.utf16.count
        let editor = fixture.editor()
        let original = try editor.capture()
        switch change {
        case "field": fixture.focus.current.element = FocusedElement(AXUIElementCreateApplication(101))
        case "app": fixture.focus.current.pid = 101; fixture.focus.current.focusedOwnerPID = 101
        case "range": fixture.range?.location += 1
        default: fixture.text = "Hi 👩🏽‍💻"
        }
        #expect(!editor.replace(original, with: "result"))
        #expect(fixture.writes.isEmpty)
    }

    @Test(arguments: ["secure", "secureInput", "owner", "role", "missingPID", "missingElement"])
    func forbiddenTargetsNeverReadSelectedTextOrCallTheSetter(change: String) throws {
        let fixture = SelectionBoundary()
        fixture.range?.length = fixture.text!.utf16.count
        let editor = fixture.editor()
        let original = try editor.capture()
        let priorRanges = fixture.rangeReads, priorTexts = fixture.textReads
        switch change {
        case "secure": fixture.focus.current.isSecure = true
        case "secureInput": fixture.focus.isSecureInputEnabled = true
        case "owner": fixture.focus.current.focusedOwnerPID = 101
        case "role": fixture.focus.current.role = "AXButton"
        case "missingPID": fixture.focus.current.pid = nil
        default: fixture.focus.current.element = nil
        }
        #expect(!editor.replace(original, with: "result"))
        #expect(fixture.rangeReads == priorRanges && fixture.textReads == priorTexts)
        #expect(fixture.writes.isEmpty)
    }

    @Test(arguments: ["missingRange", "negativeLocation", "emptyRange", "oversizedRange", "missingText", "emptyText", "wrongUTF16"])
    func invalidSelectionDataNeverCallsTheSetter(change: String) {
        let fixture = SelectionBoundary()
        switch change {
        case "missingRange": fixture.range = nil
        case "negativeLocation": fixture.range?.location = -1
        case "emptyRange": fixture.range?.length = 0
        case "oversizedRange": fixture.range?.length = 16_001
        case "missingText": fixture.text = nil
        case "emptyText": fixture.text = ""
        default: fixture.range?.length = fixture.text!.count
        }
        #expect(throws: SelectionCleanupError.self) { try fixture.editor().capture() }
        #expect(fixture.writes.isEmpty)
    }

    @Test func invalidReplacementIsRejectedBeforeReadingAndSetterFailureIsReturned() throws {
        let fixture = SelectionBoundary()
        fixture.range?.length = fixture.text!.utf16.count
        let editor = fixture.editor()
        let original = try editor.capture()
        let reads = fixture.rangeReads
        #expect(!editor.replace(original, with: ""))
        #expect(!editor.replace(original, with: String(repeating: "x", count: 16_001)))
        #expect(fixture.rangeReads == reads && fixture.writes.isEmpty)
        fixture.acceptsWrite = false
        #expect(!editor.replace(original, with: "result"))
        #expect(fixture.writes.count == 1)
    }

    @Test func writeResetsTheShortenedTimeoutBeforeWritingThroughTheOriginalReference() throws {
        let fixture = SelectionBoundary()
        fixture.range?.length = fixture.text!.utf16.count
        let editor = fixture.editor()
        let original = try editor.capture()
        fixture.events = []
        #expect(editor.replace(original, with: "result"))
        #expect(fixture.events == ["timeout=0.0", "write"])
    }

    @Test func aBudgetedCaptureLeavesNoDeadlineBehind() throws {
        let fixture = SelectionBoundary()
        fixture.range?.length = fixture.text!.utf16.count
        let editor = fixture.editor()
        _ = try editor.capture(budget: 5)
        #expect(AccessibilityFocusReader.deadline == nil)
        fixture.range = nil
        #expect(throws: SelectionCleanupError.self) { try editor.capture(budget: 5) }
        #expect(AccessibilityFocusReader.deadline == nil)
        #expect(throws: SelectionCleanupError.timedOut) { try editor.capture(budget: -1) }
        #expect(AccessibilityFocusReader.deadline == nil)
    }
}
