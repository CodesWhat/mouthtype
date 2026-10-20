import AppKit
import MouthtypeCore
import Observation
import UniformTypeIdentifiers

@MainActor @Observable final class SettingsModel {
    private let defaults: UserDefaults
    private let loginItem: LoginItem
    private let onCleanupChanged: @MainActor () -> Void
    private let onSkinChanged: @MainActor (PillSkinKind) -> Void
    private let onRecordingModeChanged: @MainActor (RecordingMode) -> String?
    private let onQuietOtherAudioChanged: @MainActor (Bool) -> Void
    private let onBoostSavedWordsChanged: @MainActor (Bool) -> Void
    private var capsLockShortcut = false
    private var escapeShortcut = false
    let microphone: MicrophoneSettingsModel
    let home: HomeLogModel
    let stats: StatsModel
    /// The editors behind the Saved spellings and Phrases pages. Nil where a model is built without a library, as in most tests.
    let spellings: SpellingEditor?
    let spellingSuggestions: SpellingSuggestionsModel?
    let phrases: PhraseEditor?
    /// Asks whether to throw away an unsaved draft. Injectable so tests can answer without a modal alert.
    @ObservationIgnored var confirmDiscard: @MainActor (DraftExit, DraftKind) -> Bool = SettingsModel.askToDiscard
    var page = SettingsPage.general
    var previewWallpaper = PreviewWallpaper.dark
    var previewStatus: PreviewStatus?
    var websiteDomain = ""
    var websiteTone: StylePreset? = .formal
    var websiteLevel: CleanupLevel?
    private(set) var cleanup: CleanupSettings
    private(set) var livePreview = false
    private(set) var audioRetention = AudioRetentionPolicy()
    private(set) var sounds: Bool
    private(set) var quietOtherAudio = true
    private(set) var skin: PillSkinKind
    private(set) var pillSize: PillSize
    private(set) var readoutColour: PillReadoutColour
    private(set) var fontOverrides: TextFontOverrides
    private(set) var fontFamilies: [String] = []
    private(set) var font: TextFontChoice
    private(set) var recordingMode: RecordingMode
    private(set) var recordingModeError: String?
    private(set) var loginState: NSControl.StateValue = .off
    private(set) var shortcut = "Fn"
    private(set) var learnCorrections = true
    private(set) var boostSavedWords = false
    private(set) var boostStatus = VocabularyBoostStatusCenter.current
    private(set) var chunkedTerminals: Set<String> = []
    private(set) var appStyles = AppCleanupStyles()
    private(set) var appStylesError: String?

    init(defaults: UserDefaults = .standard, loginItem: LoginItem = LoginItem(),
         onCleanupChanged: @escaping @MainActor () -> Void = {},
         onSkinChanged: @escaping @MainActor (PillSkinKind) -> Void = { _ in },
         onRecordingModeChanged: @escaping @MainActor (RecordingMode) -> String? = { _ in nil },
         microphone: MicrophoneSettingsModel? = nil, onMicrophoneChanged: @escaping @MainActor () -> Void = {},
         onQuietOtherAudioChanged: @escaping @MainActor (Bool) -> Void = { _ in },
         onBoostSavedWordsChanged: @escaping @MainActor (Bool) -> Void = { _ in },
         home: HomeLogModel = HomeLogModel(observing: false),
         stats: StatsModel = StatsModel(observing: false),
         spellings: SpellingEditor? = nil, spellingSuggestions: SpellingSuggestionsModel? = nil, phrases: PhraseEditor? = nil) {
        self.home = home
        self.stats = stats
        self.spellings = spellings
        self.spellingSuggestions = spellingSuggestions
        self.phrases = phrases
        if let spellings, let spellingSuggestions {
            spellingSuggestions.onRulesChanged = { [weak spellings] in spellings?.reload() }
            spellings.onLibraryChanged = { [weak spellingSuggestions] in spellingSuggestions?.libraryChanged() }
        }
        self.defaults = defaults
        self.microphone = microphone ?? MicrophoneSettingsModel(defaults: defaults, onChanged: onMicrophoneChanged)
        self.loginItem = loginItem
        self.onCleanupChanged = onCleanupChanged
        self.onSkinChanged = onSkinChanged
        self.onRecordingModeChanged = onRecordingModeChanged
        self.onQuietOtherAudioChanged = onQuietOtherAudioChanged
        self.onBoostSavedWordsChanged = onBoostSavedWordsChanged
        recordingMode = RecordingModePreference.current(defaults)
        cleanup = CleanupSettings.load(defaults)
        sounds = SoundPreference.isEnabled(defaults)
        quietOtherAudio = QuietAudioPreference.isEnabled(defaults)
        skin = PillSkinPreference.current(defaults)
        pillSize = PillSizePreference.current(defaults)
        readoutColour = PillReadoutPreference.current(defaults)
        font = TextFontPreference.current(defaults)
        fontOverrides = TextFontOverrides.load(defaults)
        refresh()
        NotificationCenter.default.addObserver(forName: .vocabularyBoostStatusChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.boostStatus = VocabularyBoostStatusCenter.current }
        }
    }

    enum DraftExit { case leaving, closing, quitting }
    enum DraftKind { case spelling, phrase }

    /// The draft on the current page that has unsaved edits, if any.
    var unsavedDraft: DraftKind? {
        switch page {
        case .savedSpellings: spellings?.isDirty == true ? .spelling : nil
        case .phrases: phrases?.isDirty == true ? .phrase : nil
        default: nil
        }
    }

    /// Moves to `target`. An unsaved spelling or phrase draft asks first: Keep Editing stays put and keeps the draft,
    /// Discard drops it and moves on. Returns whether the page changed.
    @discardableResult func select(_ target: SettingsPage) -> Bool {
        guard target != page else { return true }
        guard resolveDraft(.leaving) else { return false }
        page = target
        return true
    }

    /// True when it is fine to leave the current page or close the window: there is no unsaved draft, or the user chose to discard it.
    func resolveDraft(_ exit: DraftExit) -> Bool {
        guard let kind = unsavedDraft else { return true }
        guard confirmDiscard(exit, kind) else { return false }
        switch kind {
        case .spelling: spellings?.cancel()
        case .phrase: phrases?.cancel()
        }
        return true
    }

    static func askToDiscard(_ exit: DraftExit, _ kind: DraftKind) -> Bool {
        let alert = NSAlert()
        alert.messageText = kind == .spelling ? "Discard this unsaved spelling?" : "Discard this unsaved phrase?"
        switch exit {
        case .closing: alert.informativeText = "Save it before closing, or discard the draft."
        case .quitting: alert.informativeText = "Save it before quitting, or discard the draft."
        case .leaving: alert.informativeText = "Save it before leaving this page, or discard the draft."
        }
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard")
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// The word lists are read, and the spelling suggestions watched, only while their page is showing in an open window.
    func syncWords() {
        if page == .savedSpellings {
            spellings?.reload()
            spellingSuggestions?.activate()
        } else {
            spellingSuggestions?.deactivate()
        }
        if page == .phrases { phrases?.reload() }
    }

    func deactivateWords() { spellingSuggestions?.deactivate() }

    func setLivePreview(_ enabled: Bool) {
        LivePreviewPreference.set(enabled, in: defaults)
        livePreview = enabled
    }

    func refresh() {
        microphone.refresh()
        audioRetention = AudioRetentionPreference.load(defaults)
        livePreview = LivePreviewPreference.isEnabled(defaults)
        cleanup = CleanupSettings.load(defaults)
        sounds = SoundPreference.isEnabled(defaults)
        quietOtherAudio = QuietAudioPreference.isEnabled(defaults)
        skin = PillSkinPreference.current(defaults)
        pillSize = PillSizePreference.current(defaults)
        readoutColour = PillReadoutPreference.current(defaults)
        font = TextFontPreference.current(defaults)
        recordingMode = RecordingModePreference.current(defaults)
        fontOverrides = TextFontOverrides.load(defaults)
        FontRegistry.registerBundledFonts()
        fontFamilies = Array(Set(NSFontManager.shared.availableFontFamilies)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let savedShortcut = ShortcutSettings.load(defaults)
        shortcut = savedShortcut?.displayName ?? "Fn"
        capsLockShortcut = savedShortcut?.isCapsLock == true
        escapeShortcut = savedShortcut?.keyCode == 53
        loginState = loginItem.menuState
        learnCorrections = CorrectionSettings.isEnabled(defaults)
        boostSavedWords = VocabularyBoostSetting.isEnabled(defaults)
        chunkedTerminals = Set(PasteSettings.supportedTerminals.filter { PasteSettings.chunksEnabled($0.bundleID, defaults: defaults) }.map(\.bundleID))
        do { appStyles = try AppCleanupStyles.load(defaults); appStylesError = nil }
        catch { appStylesError = error.localizedDescription }
    }

    var recordingInstructions: String {
        let cancel = escapeShortcut ? "Use Cancel Dictation in the menu to cancel." : "Escape cancels. You can also stop or cancel from the pill or menu."
        if capsLockShortcut {
            return "Press your shortcut once to start and again to finish. Caps Lock always uses a toggle; its system state may also change. " + cancel
        }
        if recordingMode == .toggle {
            return "Press your shortcut once to start. Release it while you speak, then press it again to finish. " + cancel
        }
        return "Hold your shortcut while you speak, then release to finish. Use How to Use Mouthtype in the menu for the gestures available with your chosen key."
    }

    func setRecordingMode(_ value: RecordingMode) {
        if let error = onRecordingModeChanged(value) {
            recordingModeError = error
            return
        }
        RecordingModePreference.set(value, in: defaults)
        recordingMode = value
        recordingModeError = nil
    }

    private func updateAppStyles(_ change: (inout AppCleanupStyles) throws -> Void) {
        do {
            var current = try AppCleanupStyles.load(defaults)
            try change(&current)
            try current.save(to: defaults)
            appStyles = current
            appStylesError = nil
        } catch { appStylesError = error.localizedDescription }
    }

    /// Setting the tone keeps the rule's cleanup level; nil is "Use default" and drops the rule once neither is set.
    func setAppStyle(bundleID: String, appName: String, tone: StylePreset?) {
        updateAppStyles {
            let level = $0.entries.first { $0.bundleID == bundleID }?.level
            try $0.set(bundleID: bundleID, appName: appName, style: tone?.options, level: level)
        }
    }

    func setAppCleanupLevel(bundleID: String, appName: String, level: CleanupLevel?) {
        updateAppStyles {
            let style = $0.entries.first { $0.bundleID == bundleID }?.style
            try $0.set(bundleID: bundleID, appName: appName, style: style, level: level)
        }
    }

    func setWebsiteStyle(domain: String, tone: StylePreset?) {
        updateAppStyles {
            let level = $0.websiteRule(domain: domain)?.level
            try $0.setWebsite(domain: domain, style: tone?.options, level: level)
        }
    }

    /// The add form sets tone and level together, replacing any rule already on that domain.
    func addWebsiteRule(domain: String, tone: StylePreset?, level: CleanupLevel?) {
        updateAppStyles { try $0.setWebsite(domain: domain, style: tone?.options, level: level) }
    }

    func setWebsiteCleanupLevel(domain: String, level: CleanupLevel?) {
        updateAppStyles {
            let style = $0.websiteRule(domain: domain)?.style
            try $0.setWebsite(domain: domain, style: style, level: level)
        }
    }
    func removeWebsiteStyle(domain: String) { updateAppStyles { $0.removeWebsite(domain: domain) } }

    func removeAppStyle(bundleID: String) { updateAppStyles { $0.remove(bundleID: bundleID) } }

    func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose an application"
        panel.prompt = "Add application"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.addApplication(at: url)
        }
    }

    func addApplication(at url: URL) {
        guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else {
            appStylesError = "That application has no readable bundle identifier."
            return
        }
        let appName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        let style = CleanupSettings.load(defaults).style
        updateAppStyles {
            guard !$0.entries.contains(where: { $0.bundleID == bundleID }) else { return }
            try $0.set(bundleID: bundleID, appName: appName, style: style)
        }
    }

    private func update(_ change: (inout CleanupSettings) -> Void) {
        var current = CleanupSettings.load(defaults)
        change(&current)
        current.save(to: defaults)
        cleanup = current
        onCleanupChanged()
    }

    func setLearnCorrections(_ enabled: Bool) {
        CorrectionSettings.set(enabled, in: defaults)
        learnCorrections = enabled
    }

    func setBoostSavedWords(_ enabled: Bool) {
        VocabularyBoostSetting.set(enabled, in: defaults)
        boostSavedWords = enabled
        onBoostSavedWordsChanged(enabled)
    }

    func setAudioRetentionAge(_ value: AudioRetentionAge) {
        AudioRetentionPreference.setAge(value, in: defaults)
        audioRetention = AudioRetentionPreference.load(defaults)
    }

    func setAudioRetentionSize(_ value: AudioRetentionSize) {
        AudioRetentionPreference.setSize(value, in: defaults)
        audioRetention = AudioRetentionPreference.load(defaults)
    }
    func setLowercaseStarts(_ enabled: Bool) { update { $0.style.capitalisation = enabled ? .lowercase : .sentence } }
    func setDropFinalStop(_ enabled: Bool) { update { $0.style.endingPunctuation = enabled ? .dropFinalFullStop : .keep } }
    func setChunks(_ enabled: Bool, bundleID: String) {
        PasteSettings.setChunks(enabled, bundleID: bundleID, defaults: defaults)
        chunkedTerminals = Set(PasteSettings.supportedTerminals.filter { PasteSettings.chunksEnabled($0.bundleID, defaults: defaults) }.map(\.bundleID))
    }

    func setLevel(_ level: CleanupLevel) { update { $0.level = level } }
    func setTone(_ tone: StylePreset) { update { $0.style = tone.options } }
    func setFillers(_ value: Bool) { update { $0.fillers = value } }
    func setSpokenCommands(_ value: Bool) { update { $0.spokenCommands = value } }
    func setNumbers(_ value: Bool) { update { $0.numbers = value } }
    func setQuietOtherAudio(_ value: Bool) {
        QuietAudioPreference.set(value, in: defaults)
        quietOtherAudio = value
        onQuietOtherAudioChanged(value)
    }
    func setSounds(_ value: Bool) { SoundPreference.set(value, in: defaults); sounds = value }
    func toggleLogin() { loginItem.toggle(); loginState = loginItem.menuState }
    func setSkin(_ value: PillSkinKind) {
        PillSkinPreference.set(value, in: defaults)
        skin = value
        onSkinChanged(value)
    }
    func setPillSize(_ value: PillSize) {
        PillSizePreference.set(value, in: defaults)
        pillSize = value
        onSkinChanged(skin)
    }
    func setReadoutColour(_ value: PillReadoutColour) {
        PillReadoutPreference.set(value, in: defaults)
        readoutColour = value
        onSkinChanged(skin)
    }
    func setFont(_ value: TextFontChoice) {
        TextFontPreference.set(value, in: defaults)
        font = value
    }
    var canResetFonts: Bool { font != .systema || fontOverrides.enabled || !fontOverrides.families.isEmpty }

    func setFontOverridesEnabled(_ value: Bool) {
        TextFontOverrides.setEnabled(value, in: defaults)
        fontOverrides = TextFontOverrides.load(defaults)
    }
    func setFontFamily(_ family: String?, for group: FontGroup) {
        TextFontOverrides.setFamily(family, for: group, in: defaults)
        fontOverrides = TextFontOverrides.load(defaults)
    }
    func resetFonts() {
        TextFontOverrides.reset(in: defaults)
        font = TextFontPreference.current(defaults)
        fontOverrides = TextFontOverrides.load(defaults)
    }

}
