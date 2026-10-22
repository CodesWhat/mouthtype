import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

private struct TreeSource: BoundedTextSource {
    var text: String
    var cursor: Int
    func selection() -> NSRange? { NSRange(location: cursor, length: 0) }
    func length() -> Int? { text.utf16.count }
    func slice(location: Int, length: Int) -> String? {
        let units = Array(text.utf16)
        guard location >= 0, location + length <= units.count else { return nil }
        return String(decoding: units[location..<(location + length)], as: UTF16.self)
    }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var _cursor = 0
    private var _flag: [pid_t?] = []
    var cursor: Int { lock.withLock { _cursor } }
    var flagged: [pid_t?] { lock.withLock { _flag } }

    func readers(context: InsertionContext? = nil, delay: TimeInterval = 0) -> ContextNamesGatherer.Readers {
        ContextNamesGatherer.Readers(
            cursorText: { [self] _, _ in
                lock.withLock { _cursor += 1 }
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                return context
            },
            enableManualAccessibility: { [self] pid in lock.withLock { _flag.append(pid) } }
        )
    }
}

@MainActor
@Suite struct ContextNamesGathererTests {
    private func focus(title: String? = nil, secure: Bool = false, bundleID: String? = "com.tinyspeck.slackmacgap") -> FocusSnapshot {
        FocusSnapshot(pid: 7, bundleID: bundleID, appName: "Slack", windowTitle: title, role: "AXTextArea", isSecure: secure)
    }

    @Test func settingDefaultsOff() {
        let defaults = UserDefaults(suiteName: "context-names-\(UUID().uuidString)")!
        #expect(!ContextNamesSetting.isEnabled(defaults))
        ContextNamesSetting.set(true, in: defaults)
        #expect(ContextNamesSetting.isEnabled(defaults))
    }

    @Test func needsTheSwitchAndTheBoost() {
        let calls = Calls()
        #expect(ContextNamesGatherer.start(enabled: false, boostEnabled: true, focus: focus(), readers: calls.readers()) == nil)
        #expect(ContextNamesGatherer.start(enabled: true, boostEnabled: false, focus: focus(), readers: calls.readers()) == nil)
        #expect(calls.cursor == 0 && calls.flagged.isEmpty)
    }

    @Test func extractsNamesFromAFakeFieldAndTheTitle() async throws {
        let calls = Calls()
        let context = InsertionContext(before: "so loop in Saoirse Whitlock and ", after: " for review")
        let task = try #require(
            ContextNamesGatherer.start(
                enabled: true, boostEnabled: true, focus: focus(title: "Slack | Acme Launch"),
                readers: calls.readers(context: context), deadline: .seconds(60), readGate: EditorHints.ReadGate()))
        let names = await task.value.map(\.text)
        #expect(names == ["Whitlock", "Saoirse", "Acme", "Launch"])
        #expect(calls.cursor == 1)
    }

    @Test func secureFieldsAreNeverReadOrGathered() async {
        let calls = Calls()
        let task = ContextNamesGatherer.start(
            enabled: true, boostEnabled: true, focus: focus(title: "Vault Maya", secure: true), readers: calls.readers(),
            readGate: EditorHints.ReadGate())
        #expect(task == nil)
        let direct = await ContextNamesGatherer.gather(
            focus: focus(title: "Vault", secure: true), readers: calls.readers(), deadline: .seconds(1), readGate: EditorHints.ReadGate())
        #expect(direct.isEmpty)
        #expect(calls.cursor == 0 && calls.flagged.isEmpty)
    }

    @Test func terminalsAreSkipped() {
        let calls = Calls()
        let task = ContextNamesGatherer.start(
            enabled: true, boostEnabled: true, focus: focus(bundleID: "com.apple.Terminal"), readers: calls.readers(),
            readGate: EditorHints.ReadGate())
        #expect(task == nil)
        #expect(calls.cursor == 0)
    }

    @Test func aSlowAppCostsItsOwnReadNotTheDictation() async {
        let calls = Calls()
        let started = ContinuousClock.now
        let names = await ContextNamesGatherer.gather(
            focus: focus(title: "Slack | Acme Launch"),
            readers: calls.readers(context: InsertionContext(before: "Maya Okonkwo", after: nil), delay: 1.5),
            deadline: .milliseconds(100), readGate: EditorHints.ReadGate())
        #expect(ContinuousClock.now - started < .milliseconds(800))
        #expect(names.map(\.text) == ["Acme", "Launch"])
    }

    @Test func aBusyGateSkipsTheReadAndKeepsTheTitle() async {
        let calls = Calls()
        let gate = EditorHints.ReadGate()
        #expect(gate.acquire())
        let names = await ContextNamesGatherer.gather(
            focus: focus(title: "Slack | Acme"), readers: calls.readers(context: InsertionContext(before: "Maya Okonkwo", after: nil)),
            deadline: .seconds(1), readGate: gate)
        #expect(names.map(\.text) == ["Acme"])
        #expect(calls.cursor == 0)
    }

    @Test func theWideWindowReadsAboutTwoThousandCharactersAroundTheCursor() throws {
        let filler = String(repeating: "x ", count: 1_500)
        let text = "Wendeline " + filler + "Okonkwo | Priya " + filler
        let cursor = ("Wendeline " + filler + "Okonkwo | ").utf16.count
        let context = try #require(
            EditorAccessibility.context(
                from: TreeSource(text: text, cursor: cursor), contextBefore: EditorAccessibility.namesBefore,
                contextAfter: EditorAccessibility.namesAfter))
        #expect(context.before?.utf16.count == EditorAccessibility.namesBefore)
        #expect(context.after?.utf16.count == EditorAccessibility.namesAfter)
        #expect(context.before?.contains("Okonkwo") == true)
        #expect(context.after?.contains("Priya") == true)
        #expect(context.before?.contains("Wendeline") == false)
        // The existing cleanup window is untouched.
        #expect(EditorAccessibility.context(from: TreeSource(text: text, cursor: cursor))?.before?.utf16.count == 300)
    }

    @Test func mergeKeepsEditorNamesFirstWithoutDuplicates() async throws {
        let editor = Task { [VocabularyBias.Term(text: "applyTheme"), VocabularyBias.Term(text: "Maya")] }
        let names = Task { [VocabularyBias.Term(text: "maya"), VocabularyBias.Term(text: "Priya")] }
        let merged = try #require(ContextNamesGatherer.merge(editor, names))
        #expect(await merged.value.map(\.text) == ["applyTheme", "Maya", "Priya"])
        #expect(ContextNamesGatherer.merge(nil, nil) == nil)
    }
}

@Suite struct ElectronAccessibilityTests {
    @Test func flagIsSetOncePerElectronApp() {
        let counter = Counter()
        let enabler = ElectronAccessibility(isElectron: { $0 != 99 }, setFlag: { _ in counter.bump(); return true })
        #expect(enabler.enableIfNeeded(pid: 10))
        #expect(!enabler.enableIfNeeded(pid: 10))
        #expect(enabler.enableIfNeeded(pid: 11))
        #expect(counter.value == 2)
    }

    @Test func nonElectronAppsAreNeverTouched() {
        let counter = Counter()
        let enabler = ElectronAccessibility(isElectron: { _ in false }, setFlag: { _ in counter.bump(); return true })
        #expect(!enabler.enableIfNeeded(pid: 5))
        #expect(!enabler.enableIfNeeded(pid: nil))
        #expect(counter.value == 0)
    }

    @Test func aTimedOutAppIsRetriedNextTime() {
        let counter = Counter()
        let enabler = ElectronAccessibility(isElectron: { _ in true }, setFlag: { _ in counter.bump(); return counter.value > 1 })
        #expect(!enabler.enableIfNeeded(pid: 3))
        #expect(enabler.enableIfNeeded(pid: 3))
        #expect(!enabler.enableIfNeeded(pid: 3))
        #expect(counter.value == 2)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func bump() { lock.withLock { count += 1 } }
}
