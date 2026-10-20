import AppKit
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
        daily.add(section: SelectionCleanupMenuSection(cleanUp: {}, applyTone: { _ in }, insertPhrase: { _ in }, editTransforms: {}))
        daily.add(section: FileTranscriptionMenuSection {}, startsGroup: false)
        daily.add(section: HelpMenuSection(onShow: {}), isFooter: true)
        let layout = daily.menu.items.map { $0.isSeparatorItem ? "|" : $0.title }
        #expect(layout == [
            "Open Mouthtype", "Settings…", "|", "Paste Last Take", "Copy Last Take", "|",
            "Clean Up Selection", "Transcribe Audio File…", "|", "How to Use Mouthtype…", "About Mouthtype", "Quit",
        ])
        #expect(daily.menu.items.filter { $0.image != nil }.map(\.title) == [])
        state.microphoneStatus = .denied
        daily.refresh()
        #expect(daily.menu.items.map { $0.isSeparatorItem ? "|" : $0.title }.prefix(3) == ["Microphone access needed…", "|", "Open Mouthtype"])
    }

    @Test func cleanUpSelectionSubmenuListsToneAndPhraseChoices() throws {
        var tones: [StylePreset] = [], phrases: [String] = [], edited = 0, cleaned = 0
        var enabled = true
        let section = SelectionCleanupMenuSection(
            cleanUp: { cleaned += 1 }, applyTone: { tones.append($0) }, insertPhrase: { phrases.append($0.trigger) },
            editTransforms: { edited += 1 },
            phrases: { [Snippet(trigger: "Sign-off", expansion: "Best,\nScott"), Snippet(trigger: "Meeting Link", expansion: "https://x.test")] },
            canAct: { enabled })
        let menu = try #require(section.items.first?.submenu)
        #expect(section.items.first?.title == "Clean Up Selection")
        #expect(menu.items.map { $0.isSeparatorItem ? "|" : $0.title } == [
            "Clean Up", "|", "Formal", "Casual", "Very Casual", "|", "Sign-off", "Meeting Link", "|", "Edit Transforms…",
        ])
        #expect(menu.items.allSatisfy { $0.image == nil })
        for item in menu.items where !item.isSeparatorItem { _ = item.target?.perform(item.action, with: item) }
        #expect(cleaned == 1 && edited == 1 && tones == [.formal, .casual, .veryCasual] && phrases == ["Sign-off", "Meeting Link"])
        enabled = false
        section.refresh()
        let disabled = menu.items.filter { !$0.isSeparatorItem && $0.isEnabled }.map(\.title)
        #expect(disabled == ["Edit Transforms…"])
    }
}
