import AppKit
import Foundation
import MouthtypeCore
import Testing
@testable import MouthtypeMac

/// The counters, with fakes and isolated defaults: a count lands only for a completed Accept.

@MainActor private func isolated() -> (UserDefaults, () -> Void) {
    let name = "mouthtype-counting-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    return (defaults, { defaults.removePersistentDomain(forName: name) })
}

@MainActor private final class CountingEditor: SelectionEditing {
    var selected = SelectedText(pid: 7, element: nil, range: NSRange(location: 0, length: 15), text: "me and him goes")
    var current: SelectedText?
    var accepts = true
    var replaced: [String] = []
    func capture() throws -> SelectedText { current ?? selected }
    func replace(_ original: SelectedText, with replacement: String) -> Bool {
        guard accepts, original == (current ?? selected) else { return false }
        replaced.append(replacement)
        return true
    }
}

@MainActor private final class CountingTransformer: SelectionTransforming {
    var transformUnavailableReason: String? { nil }
    func transform(_ transform: TextTransform, text: String) async throws -> String { "He and I go." }
}

@MainActor @Suite struct AchievementCountingTests {
    @Test func recordCountsOncePostsAndStaysLocal() {
        let (defaults, cleanup) = isolated()
        defer { cleanup() }
        var posts = 0
        let counting = AchievementCounting(
            defaults: defaults, now: { Date(timeIntervalSince1970: 1_793_000_000) }, timeZone: { TimeZone(identifier: "UTC")! },
            post: { posts += 1 })
        #expect(counting.record(.voiceEdits))
        #expect(counting.store.count(.voiceEdits) == 1 && posts == 1)
        #expect(counting.store.counterDays["voiceEdits:1"] == "2026-10-26")
        #expect(defaults.object(forKey: AchievementStore.Counter.voiceEdits.key) is Int)
    }

    @Test func offCountsNothingAndPostsNothing() {
        let (defaults, cleanup) = isolated()
        defer { cleanup() }
        AchievementStore(defaults: defaults).setEnabled(false)
        var posts = 0
        let counting = AchievementCounting(defaults: defaults, post: { posts += 1 })
        #expect(!counting.record(.transforms))
        #expect(counting.store.count(.transforms) == 0 && posts == 0)
    }

    @Test func aTransformThePanelAcceptsCountsOnce() async {
        let (defaults, cleanup) = isolated()
        defer { cleanup() }
        let counting = AchievementCounting(defaults: defaults, post: {})
        let editor = CountingEditor()
        let box = ModelBox()
        let model = SelectionCleanupModel(
            editor: counting.counting(editor, as: .transforms) { box.model?.transform != nil }, transformer: CountingTransformer())
        box.model = model
        await model.prepare(transform: .fixGrammar)
        for _ in 0..<200 where model.isTransforming { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(counting.store.count(.transforms) == 0)  // a preview alone is not a count
        model.accept()
        model.accept()
        #expect(editor.replaced.count == 1 && counting.store.count(.transforms) == 1)
        #expect(counting.store.count(.voiceEdits) == 0)
    }

    @Test func basicCleanupRefusalAndCancelNeverCount() async {
        let (defaults, cleanup) = isolated()
        defer { cleanup() }
        let counting = AchievementCounting(defaults: defaults, post: {})
        let editor = CountingEditor()
        let box = ModelBox()
        let model = SelectionCleanupModel(
            editor: counting.counting(editor, as: .transforms) { box.model?.transform != nil }, transformer: CountingTransformer())
        box.model = model
        // Basic cleanup is not a rewrite.
        await model.prepare()
        model.accept()
        #expect(editor.replaced.count == 1 && counting.store.count(.transforms) == 0)

        // The app refuses the write.
        editor.accepts = false
        await model.prepare(transform: .shorter)
        for _ in 0..<200 where model.isTransforming { try? await Task.sleep(for: .milliseconds(5)) }
        model.accept()
        #expect(model.refused && counting.store.count(.transforms) == 0)

        // Cancel before Accept.
        editor.accepts = true
        model.cancel()
        await model.prepare(transform: .shorter)
        for _ in 0..<200 where model.isTransforming { try? await Task.sleep(for: .milliseconds(5)) }
        model.cancel()
        #expect(counting.store.count(.transforms) == 0)
    }

    @MainActor private final class ModelBox {
        var model: SelectionCleanupModel?
    }

    @Test func theReportingEditorPassesReadsThroughAndReportsOnlyTakenWrites() throws {
        let editor = CountingEditor()
        var reports = 0
        let wrapped = ReplacementReportingEditor(base: editor) { reports += 1 }
        #expect(try wrapped.capture() == editor.selected)
        #expect(wrapped.replace(editor.selected, with: "x") && reports == 1)
        editor.accepts = false
        #expect(!wrapped.replace(editor.selected, with: "y") && reports == 1)
    }
}
