import AppKit
import os
import AVFoundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@MainActor @Suite struct MenuCleanTests {
    private func healthy() -> SettingsDiagnostics {
        let state = SettingsDiagnostics()
        state.engineStatus = "Parakeet ready"
        state.microphoneStatus = .authorized
        state.accessibilityGranted = true
        state.hotkeyHealth = .listening
        return state
    }

    @Test func healthyMenuHasNoDiagnosticHeaderAndHiddenGroupsLeaveNoSeparators() {
        let state = healthy()
        let daily = DailyMenu()
        daily.add(section: AttentionMenuSection(diagnostics: state, open: {}))
        daily.add(section: SettingsMenuSection {})
        daily.add(section: ActionsMenuSection(onPasteLast: {}, onCopyLast: {}))
        daily.add(section: HistoryMenuSection(store: nil), startsGroup: false)
        daily.add(section: HelpMenuSection(onShow: {}), isFooter: true)
        #expect(daily.menu.items.filter { !$0.isSeparatorItem }.map(\.title) == [
            "Open Mouthtype", "Settings…", "Paste Last Take", "Copy Last Take", "How to Use Mouthtype…", "About Mouthtype", "Quit",
        ])
        #expect(daily.menu.items.map { $0.isSeparatorItem ? "|" : $0.title } == [
            "Open Mouthtype", "Settings…", "|", "Paste Last Take", "Copy Last Take", "|", "How to Use Mouthtype…", "About Mouthtype", "Quit",
        ])
        #expect(daily.menu.items.first?.isSeparatorItem == false)
        #expect(daily.menu.items.last?.isSeparatorItem == false)
        #expect(!zip(daily.menu.items, daily.menu.items.dropFirst()).contains { $0.isSeparatorItem && $1.isSeparatorItem })
        var stopped = 0, cancelled = 0
        daily.onStopDictation = { stopped += 1 }
        daily.onCancelDictation = { cancelled += 1 }
        daily.setHandsFree(true)
        #expect(daily.menu.items.prefix(2).map(\.title) == ["Stop Dictation", "Cancel Dictation"])
        for item in daily.menu.items.prefix(2) { _ = item.target?.perform(item.action, with: item) }
        #expect(stopped == 1 && cancelled == 1)
        daily.setHandsFree(false)
        #expect(daily.menu.items.first?.title == "Open Mouthtype")
    }

    @Test func attentionIsSpecificRoutesToDiagnosticsAndDisappearsWhenRepaired() throws {
        let state = healthy()
        var opened = 0, refreshed = 0
        let attention = AttentionMenuSection(diagnostics: state) { opened += 1 }
        let daily = DailyMenu()
        daily.onRefresh = { refreshed += 1 }
        daily.add(section: attention)
        #expect(attention.items.isEmpty)
        state.microphoneStatus = .denied
        daily.refresh()
        let item = try #require(attention.items.first)
        #expect(item.title == "Microphone access needed…")
        _ = item.target?.perform(item.action, with: item)
        #expect(opened == 1 && refreshed == 1)
        state.microphoneStatus = .authorized
        state.engineFailed = true
        daily.refresh()
        #expect(attention.items.first?.title == "Speech model needs attention…")
        state.engineFailed = false
        daily.refresh()
        #expect(attention.items.isEmpty)
    }

    @Test func historyFailureAppearsInTheSameMenuRefresh() {
        let state = healthy()
        let daily = DailyMenu()
        let attention = AttentionMenuSection(diagnostics: state, open: {})
        daily.add(section: attention)
        daily.add(section: HistoryMenuSection(store: nil, onError: { state.historyError = $0 }))
        state.historyError = nil
        daily.refresh()
        #expect(attention.items.first?.title == "Recent takes unavailable…")
    }

    @Test func customShortcutDoesNotOfferFnRemappingOrGlobeConflict() {
        let state = healthy()
        state.globe = GlobeKeyCheck(action: .showEmoji, fnKeyPresent: true)
        #expect(state.attentionText != nil && state.canRemapFn)
        state.shortcut = DictationShortcut(keyCode: 58, keyName: "Option")
        #expect(state.attentionText == nil && !state.canRemapFn)
        state.hotkeyHealth = .secureInputOn
        #expect(state.attentionText == "Dictation is paused by Secure Input…")
    }

    @Test func repeatedRecentRefreshKeepsFullCopyAndExcludesSecureText() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MenuRecent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TranscriptStore(url: directory.appendingPathComponent("history.sqlite"))
        let start = Date()
        let wanted = "First line\nSecond line with all the original spacing."
        let ordinary = try store.begin(DictationStart(startedAt: start))
        try store.recordInsertion(ordinary, InsertionRecord(finalText: wanted))
        let secure = try store.begin(DictationStart(startedAt: start.addingTimeInterval(1)))
        try store.recordInsertion(secure, InsertionRecord(finalText: "Private text", target: DictationTarget(isSecure: true)))
        var copied: String?
        let section = HistoryMenuSection(store: store, copy: { copied = $0 })
        for _ in 0..<3 { section.refresh() }
        let items = try #require(section.items.first?.submenu?.items)
        #expect(items.count == 2)
        let item = try #require(items.last)
        _ = item.target?.perform(item.action, with: item)
        #expect(copied == wanted)
    }

    @Test func footerStaysSeparateWhenHelpAndHistoryAreAbsent() {
        let daily = DailyMenu()
        daily.add(section: SettingsMenuSection {})
        daily.add(section: HistoryMenuSection(store: nil), startsGroup: false)
        #expect(daily.menu.items.map { $0.isSeparatorItem ? "|" : $0.title } == [
            "Open Mouthtype", "Settings…", "|", "About Mouthtype", "Quit",
        ])
    }

    @Test func absentCleanupAttentionClearsWhenLevelNoLongerNeedsModel() {
        let state = healthy()
        let cleaner = CleanerHost(model: FakeSmartModel(downloaded: false), level: { .light })
        state.refreshModels(speech: "Ready", failed: false, cleaner: cleaner, level: .light)
        #expect(state.cleanupNeedsAttention)
        state.refreshModels(speech: "Ready", failed: false, cleaner: cleaner, level: .basic)
        #expect(!state.cleanupNeedsAttention && state.attentionText == nil)
        state.refreshModels(speech: "Ready", failed: false, cleaner: cleaner, level: .medium)
        #expect(state.cleanupNeedsAttention)
        state.refreshModels(speech: "Ready", failed: false, cleaner: cleaner, level: .off)
        #expect(!state.cleanupNeedsAttention)
    }

    @Test func advancedPreferencesKeepCustomToneLearningAndTerminalFlags() {
        let name = "MenuCleanTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = SettingsModel(defaults: defaults)
        #expect(model.learnCorrections && model.chunkedTerminals.isEmpty)
        model.setLowercaseStarts(true)
        #expect(model.cleanup.style.preset == nil)
        model.setDropFinalStop(true)
        #expect(model.cleanup.style == StylePreset.veryCasual.options)
        model.setLearnCorrections(false)
        #expect(!CorrectionSettings.isEnabled(defaults))
        model.setChunks(true, bundleID: "com.mitchellh.ghostty")
        model.setChunks(true, bundleID: "com.apple.TextEdit")
        #expect(model.chunkedTerminals == ["com.mitchellh.ghostty"])
        model.setChunks(false, bundleID: "com.mitchellh.ghostty")
        #expect(!PasteSettings.chunksEnabled("com.mitchellh.ghostty", defaults: defaults))
        #expect(Set(PasteSettings.supportedTerminals.map(\.bundleID)).count == 5)
    }

    @Test func fullMenuMatchesTheTargetLayoutWithNoIcons() throws {
        let state = healthy()
        let daily = DailyMenu()
        daily.add(section: AttentionMenuSection(diagnostics: state, open: {}))
        daily.add(section: SettingsMenuSection {})
        daily.add(section: ActionsMenuSection(onPasteLast: {}, onCopyLast: {}))
        daily.add(section: HistoryMenuSection(store: nil), startsGroup: false)
        daily.add(section: TransformSelectionMenuSection(open: { _ in }, editTransforms: {}))
        daily.add(section: FileTranscriptionMenuSection {}, startsGroup: false)
        daily.add(section: HelpMenuSection(onShow: {}), isFooter: true)
        let layout = daily.menu.items.map { $0.isSeparatorItem ? "|" : $0.title }
        #expect(layout == [
            "Open Mouthtype", "Settings…", "|", "Paste Last Take", "Copy Last Take", "|",
            "Transform Selection", "Transcribe Audio File…", "|", "How to Use Mouthtype…", "About Mouthtype", "Quit",
        ])
        #expect(daily.menu.items.filter { $0.image != nil }.map(\.title) == [])
        state.microphoneStatus = .denied
        daily.refresh()
        #expect(daily.menu.items.map { $0.isSeparatorItem ? "|" : $0.title }.prefix(3) == ["Microphone access needed…", "|", "Open Mouthtype"])
    }

    @Test func transformSelectionSubmenuListsTheFiveTransforms() async throws {
        var opened: [TextTransform?] = [], edited = 0
        var state = MenuCapture.ready
        var reason: String?
        let section = TransformSelectionMenuSection(
            open: { opened.append($0) }, editTransforms: { edited += 1 }, aiUnavailableReason: { reason }, capture: { state })
        let menu = try #require(section.items.first?.submenu)
        #expect(section.items.first?.title == "Transform Selection")
        #expect(menu.items.map { $0.isSeparatorItem ? "|" : $0.title } == [
            "Clean up", "Fix grammar", "Make shorter", "More formal", "More casual", "|", "Edit Transforms…",
        ])
        #expect(menu.items.allSatisfy { $0.image == nil })
        for item in menu.items where !item.isSeparatorItem { _ = item.target?.perform(item.action, with: item) }
        #expect(edited == 1 && opened == [nil, .fixGrammar, .shorter, .moreFormal, .moreCasual])
        state = .unavailable
        section.prepareForMenuOpen()
        await section.pendingCapture?.value
        #expect(menu.items.filter { !$0.isSeparatorItem && $0.isEnabled }.map(\.title) == ["Edit Transforms…"])
        state = .ready
        reason = "AI transforms need the model."
        section.prepareForMenuOpen()
        await section.pendingCapture?.value
        #expect(menu.items.filter { !$0.isSeparatorItem && $0.isEnabled }.map(\.title) == ["Clean up", "Edit Transforms…"])
        #expect(menu.items.first { $0.title == "Fix grammar" }?.toolTip == reason)
    }

    @Test func selectionIsReadOncePerMenuOpenBeforeTrackingNotOnRefreshOrSubmenuOpen() async throws {
        var captures = 0
        let section = TransformSelectionMenuSection(
            open: { _ in }, editTransforms: {}, capture: { captures += 1; return .ready })
        let daily = DailyMenu()
        daily.add(section: SettingsMenuSection {})
        daily.add(section: section)
        daily.refresh()
        #expect(captures == 0)
        daily.menuNeedsUpdate(daily.menu)
        await section.pendingCapture?.value
        #expect(captures == 1)
        let submenu = try #require(section.items.first?.submenu)
        section.menuNeedsUpdate(submenu)
        #expect(captures == 1)
        #expect(submenu.items.first { $0.title == "Clean up" }?.isEnabled == true)
    }

    @Test func slowReaderTimesOutOffMainAndDisablesItems() async throws {
        let readFinished = OSAllocatedUnfairLock(initialState: false)
        let releaseRead = DispatchSemaphore(value: 0)
        let editor = AccessibilitySelectionEditor(
            focus: SnapshotOnlyFocus(), readRange: { _ in nil }, readText: { _ in nil }, writeText: { _, _ in false },
            offMainRead: { _, _, _ in
                // Blocked until the test has checked the result landed on the budget; the cap only bounds a hang.
                _ = releaseRead.wait(timeout: .now() + 60)
                readFinished.withLock { $0 = true }
                return .failure(.unavailable)
            })
        let model = SelectionCleanupModel(editor: editor)
        let section = TransformSelectionMenuSection(
            open: { _ in }, editTransforms: {}, capture: { await model.captureForMenuOffMain(budget: 0.05) })
        let submenu = try #require(section.items.first?.submenu)
        section.prepareForMenuOpen()
        await section.pendingCapture?.value
        // The result landed on the budget while the read was still blocked, so nothing waited on it.
        #expect(!readFinished.withLock { $0 })
        releaseRead.signal()
        #expect(submenu.items.first?.title == "Couldn’t read the selection")
        #expect(submenu.items.filter { !$0.isSeparatorItem && $0.isEnabled }.map(\.title) == ["Edit Transforms…"])
    }

    @Test func menuOpensImmediatelyDisabledAndEnablesWhenTheReadLands() async throws {
        let gate = AsyncGate()
        let section = TransformSelectionMenuSection(
            open: { _ in }, editTransforms: {}, capture: { await gate.wait(); return .ready })
        let submenu = try #require(section.items.first?.submenu)
        section.prepareForMenuOpen()
        #expect(submenu.items.filter { !$0.isSeparatorItem && $0.isEnabled }.map(\.title) == ["Edit Transforms…"])
        gate.open()
        await section.pendingCapture?.value
        #expect(submenu.items.filter { !$0.isSeparatorItem && $0.isEnabled }.map(\.title) == [
            "Clean up", "Fix grammar", "Make shorter", "More formal", "More casual", "Edit Transforms…"])
    }

    @Test func aReadThatLandsAfterTheMenuClosedOrReopenedIsDropped() async throws {
        let gate = AsyncGate()
        var results: [MenuCapture] = [.ready, .unavailable]
        let section = TransformSelectionMenuSection(
            open: { _ in }, editTransforms: {}, capture: { await gate.wait(); return results.removeFirst() })
        let submenu = try #require(section.items.first?.submenu)
        section.prepareForMenuOpen()
        let first = section.pendingCapture
        section.menuDidClose()
        section.prepareForMenuOpen()
        gate.open()
        await first?.value
        await section.pendingCapture?.value
        // The first open's .ready never applied; the second open's .unavailable did.
        #expect(submenu.items.filter { !$0.isSeparatorItem && $0.isEnabled }.map(\.title) == ["Edit Transforms…"])
    }
}

@MainActor private final class SnapshotOnlyFocus: FocusReading {
    var isSecureInputEnabled = false
    func snapshot() -> FocusSnapshot { FocusSnapshot(pid: 100) }
    func textBeforeCursor(of element: FocusedElement) -> TextBeforeCursor { .unknown }
}

@MainActor private final class AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
