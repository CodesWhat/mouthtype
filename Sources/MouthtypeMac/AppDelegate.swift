import AppKit
import MouthtypeCore

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engineHost = EngineHost()
    private let cleanerHost = CleanupSelection(
        fast: CleanerCatalog.makeSmartCleanup(level: .light), thorough: CleanerCatalog.makeSmartCleanup(level: .medium), level: { SmartTestOptions.modelLevel(in: CommandLine.arguments, saved: CleanupSettings.load().level) },
        budget: SmartTestOptions.budget(in: CommandLine.arguments)
    )
    private let dictionary = FileVocabulary()
    private let phrases = FilePhrases()
    private let diagnostics = SettingsDiagnostics()
    private lazy var setupModel = SetupModel(diagnostics: diagnostics, engine: engineHost, microphone: micCapture.preparation)
    private lazy var setupWindow = SetupWindow(model: setupModel, actions: SetupActions(
        refresh: { [weak self] in
            self?.refreshDiagnostics()
            Task { _ = await self?.prepareCapture() }
        },
        poll: { [weak self] in self?.refreshSetupReadiness() },
        microphone: { [weak self] in self?.requestSetupMicrophone() },
        accessibility: { [weak self] in
            self?.accessibility.start()
            NSWorkspace.shared.open(AccessibilityAccess.settingsURL)
        }, retrySpeech: { [weak self] in self?.engineHost.start() },
        inputSettings: { [weak self] in self?.settingsWindow.present(page: .diagnostics) }))
    private let fontChooser = TextFontMenuSection()
    private lazy var appUpdater: AppUpdater = AppUpdater(
        driver: UpdateLaunchPolicy.allows(arguments: CommandLine.arguments, bundleURL: Bundle.main.bundleURL,
            info: Bundle.main.infoDictionary ?? [:]) ? SparkleDriver() : nil,
        activity: { [weak self] in .resolve(phase: self?.dictation?.phase, recovering: self?.recovery?.isRecovering == true,
            transcribingFile: self?.fileTranscriptionModel.isBusy == true, editingSelection: self?.selectionCleanupModel.hasPreview == true) })
    private lazy var selectionCleanupModel = SelectionCleanupModel(editor: AccessibilitySelectionEditor(), busy: { [weak self] in
        guard let self else { return true }
        return self.isTerminating || self.dictation?.phase != .idle || self.fileTranscriptionModel.isBusy || self.recovery?.isRecovering == true || self.appUpdater.blocksNewWork
    }, changed: { [weak self] in self?.appUpdater.refreshActivity() })
    private lazy var selectionCleanupWindow = SelectionCleanupWindow(model: selectionCleanupModel)
    private lazy var fileTranscriptionModel: FileTranscriptionModel = FileTranscriptionModel(
        makeJob: { [weak self] in
            guard let self, case .ready = self.engineHost.state, let engine = self.engineHost.engine else {
                throw CocoaError(.featureUnsupported)
            }
            return AudioFileTranscription(decoder: MacAudioFileDecoder(), engine: engine)
        }, canBegin: { [weak self] in
            guard let self, !self.isTerminating else { return false }
            return self.dictation?.phase == .idle && self.recovery?.isRecovering != true && !self.appUpdater.blocksNewWork
        }, activityChanged: { [weak self] in
            self?.appUpdater.refreshActivity()
            self?.menuBar?.refresh()
        }, copy: { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        })
    private lazy var fileTranscriptionWindow = FileTranscriptionWindow(model: fileTranscriptionModel)
    private lazy var spellingWindow = SpellingEditorWindow(store: dictionary)
    private lazy var phraseWindow = PhraseEditorWindow(store: phrases)
    private lazy var settingsWindow = SettingsWindow(
        model: SettingsModel(onCleanupChanged: { [weak self] in self?.cleanerHost.levelChanged(); self?.refreshDiagnosticModels() },
            onSkinChanged: { [weak self] kind in self?.pill?.setSkin(kind) },
            onRecordingModeChanged: { [weak self] mode in self?.activateRecordingMode(mode) },
            onMicrophoneChanged: { [weak self] in self?.microphoneSelectionChanged() },
            onQuietOtherAudioChanged: { [weak self] enabled in if !enabled { self?.audioQuiet.end() } }),
        actions: SettingsActions(openSetup: { [weak self] in self?.showSetup() }, changeShortcut: { [weak self] in self?.showShortcutEditor() },
            openSpellings: { [weak self] in self?.spellingWindow.present() },
            openPhrases: { [weak self] in self?.phraseWindow.present() }, cleaner: cleanerHost,
            diagnostics: diagnostics, retrySpeech: { [weak self] in self?.engineHost.start() },
            refreshDiagnostics: { [weak self] in self?.refreshDiagnostics() },
            toggleRemap: { [weak self] in self?.toggleRemap() },
            openMicSettings: { NSWorkspace.shared.open(MicrophoneAccess.settingsURL) },
            openAccessibilitySettings: { NSWorkspace.shared.open(AccessibilityAccess.settingsURL) },
            openKeyboardSettings: { NSWorkspace.shared.open(GlobeKeyCheck.settingsURL) },
            editDictionary: { [weak self] in self?.editDictionary() },
            editPhrasesFile: { [weak self] in self?.editPhrasesFile() },
            chooseFont: { [weak self] in self?.fontChooser.presentFontChooser() }, updater: appUpdater))
    private let micCapture = MicCapture()
    private let audioQuiet = RecordingAudioQuiet(output: CoreAudioQuietOutput(), enabled: { QuietAudioPreference.isEnabled() })
    private let microphoneSection = MicrophoneMenuSection()
    private let systemSection = SystemAccessMenuSection()
    private let accessibility = AccessibilityAccess()
    private let fnRemap = FnRemap()
    private lazy var remapCoordinator = FnRemapCoordinator(remap: fnRemap, guardian: FnGuardLauncher())
    private let shortcuts = GlobalShortcuts()
    private var menuBar: MenuBarController?
    private var historySection: HistoryMenuSection?
    private var hotkeyService: HotkeyService?
    private var shortcutWindow: ShortcutRecorderWindow?
    private var hotkeyLogTask: Task<Void, Never>?
    private var pill: PillController?
    private var cardController: DeliveryCardController?
    private var cardPresenter: DeliveryCardPresenter?
    private var inserter: TextInserter?
    private var correctionWatcher: CorrectionWatcher?
    private var dictation: DictationController?
    private var recovery: CrashRecovery?
    private var recoveryChecked = false
    private let launchedAt = Date()
    private var inputStarted = false
    private var isTerminating = false
    private let termination = AppTermination()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("launch \(AppInfo.version, privacy: .public)")
        let arguments = CommandLine.arguments
        FontRegistry.registerBundledFonts()
        // The two file/visual modes need no permissions and touch neither the remap, the mic nor the real database.
        if let demo = PillDemo.options(in: arguments) {
            let pill = PillController(level: { .silence })
            if let skin = demo.skin { pill.setSkin(skin) }
            let cards = DeliveryCardController()
            cards.anchor = { [weak pill] in pill?.cardAnchor() }
            let presenter = DeliveryCardPresenter(surface: cards, clipboard: SystemClipboard(), clock: SystemDictationClock())
            cards.onAction = { [weak presenter] action in presenter?.perform(action) }
            cards.onDismiss = { [weak presenter] in presenter?.userDismissed() }
            self.pill = pill
            cardController = cards
            cardPresenter = presenter
            Task {
                await PillDemo.run(controller: pill, cards: cards, presenter: presenter, options: demo)
                NSApp.terminate(nil)
            }
            return
        }
        if CorrectionSelfTest.isRequested(in: arguments) {
            Task { await CorrectionSelfTest.run() }
            return
        }
        if PasteSelfTest.isRequested(in: arguments) {
            Task { await PasteSelfTest.run() }
            return
        }
        if let options = RecoverySelfTest.options(in: arguments) {
            engineHost.start()
            Task { await RecoverySelfTest.run(options: options, engineHost: engineHost) }
            return
        }
        if let path = PipelineSelfTest.path(in: arguments) {
            engineHost.start()
            cleanerHost.start()
            Task { await PipelineSelfTest.run(path: path, engineHost: engineHost, cleanerHost: cleanerHost) }
            return
        }

        // Undo a Fn remap a previous run died with before anything reads the keyboard.
        _ = fnRemap.restoreIfStale()
        let store = openStore()
        let archive = AudioArchive(supportDirectory: TranscriptStore.defaultURL().deletingLastPathComponent())
        purgeAudio(archive: archive, store: store)

        let level = micCapture.capture
        let pill = PillController(level: { level.reading })
        let inserter = TextInserter(syntheticStamp: SyntheticEvents.stamp, inputGeneration: { [weak self] in self?.hotkeyService?.userInputGeneration })
        if let store {
            do { try inserter.restoreLast(from: store) }
            catch { Log.app.error("last transcript unavailable: \(error.localizedDescription, privacy: .public)") }
        }
        let engine = HostEngine(host: engineHost)
        let sounds = ClickSoundPlayer()
        let cards = DeliveryCardController()
        cards.anchor = { [weak pill] in pill?.cardAnchor() }
        let presenter = DeliveryCardPresenter(surface: cards, clipboard: SystemClipboard(), clock: SystemDictationClock())
        cards.onAction = { [weak presenter] action in presenter?.perform(action) }
        cards.onDismiss = { [weak presenter] in presenter?.userDismissed() }
        cardController = cards
        cardPresenter = presenter
        var pipeline = DictationPipeline(
            store: store.map(TranscriptStoreWriter.init), archive: archive, engine: engine, clock: SystemDictationClock()
        )
        pipeline.vocabulary = SavedVocabulary(words: dictionary, phrases: phrases)
        pipeline.smart = cleanerHost
        let dictation = DictationController(
            capture: micCapture, engine: engine, pipeline: pipeline,
            inserter: inserter, pill: pill, sounds: sounds, clock: SystemDictationClock(), cards: presenter,
            audioQuiet: audioQuiet, previewEnabled: { LivePreviewPreference.isEnabled() }
        )
        self.pill = pill
        self.inserter = inserter
        self.dictation = dictation
        if let store {
            recovery = CrashRecovery(
                store: store, archive: archive, pipeline: pipeline, cards: presenter, pill: pill, clock: SystemDictationClock(),
                launchedAt: launchedAt
            )
        }
        let watcher = CorrectionWatcher(
            reader: AccessibilityFieldReader(), dictionary: dictionary, ledger: CorrectionLedger(),
            store: store.map(CorrectionStoreWriter.init), cards: presenter, clock: SystemDictationClock(),
            input: { [weak self] in self?.hotkeyService?.userInputGeneration },
            canOffer: { [weak dictation] in dictation?.phase == .idle }
        )
        watcher.onNotice = { [weak pill] message in pill?.showMessage(message, duration: 4) }
        dictation.corrections = watcher
        correctionWatcher = watcher

        let menuBar = MenuBarController()
        pill.onLevel = { [weak menuBar] level in menuBar?.setLevel(level) }
        let history = HistoryMenuSection(store: store, onError: { [weak self] error in self?.diagnostics.historyError = error })
        let settingsSection = SettingsMenuSection { [weak self] in self?.settingsWindow.present() }
        menuBar.add(section: AttentionMenuSection(diagnostics: diagnostics, open: { [weak self] in
            guard let self else { return }
            if self.diagnostics.microphoneStatus != .authorized || !self.diagnostics.accessibilityGranted { self.showSetup() }
            else { self.settingsWindow.present(page: .diagnostics) }
        }))
        menuBar.add(section: settingsSection, startsGroup: false)
        NSApp.mainMenu = settingsSection.applicationMenu()
        menuBar.add(section: ActionsMenuSection(
            onPasteLast: { [weak self] in self?.pasteLast() }, onCopyLast: { [weak self] in self?.copyLast() }
        ))
        menuBar.add(section: SelectionCleanupMenuSection { [weak self] in self?.selectionCleanupWindow.present() }, startsGroup: false)
        menuBar.add(section: FileTranscriptionMenuSection { [weak self] in self?.fileTranscriptionWindow.present() }, startsGroup: false)
        if let recovery {
            recovery.canRecover = { [weak self, weak dictation, weak engineHost] in
                guard dictation?.phase == .idle, let engineHost else { return false }
                guard self?.isTerminating != true, self?.appUpdater.blocksNewWork != true, self?.fileTranscriptionModel.isBusy != true else { return false }
                if case .ready = engineHost.state { return true }
                return false
            }
            menuBar.add(section: SavedRecordingsMenuSection(recovery: recovery, canRecover: recovery.canRecover), startsGroup: false)
            recovery.onFinished = { [weak menuBar] in menuBar?.refresh() }
        }
        dictation.canStartRecording = { [weak self] in self?.isTerminating != true && self?.recovery?.isRecovering != true && self?.appUpdater.blocksNewWork != true && self?.fileTranscriptionModel.isBusy != true }
        menuBar.add(section: history, startsGroup: false)
        menuBar.add(section: UpdateMenuSection(updater: appUpdater), isFooter: true)
        menuBar.add(section: HelpMenuSection(), isFooter: true)
        self.menuBar = menuBar
        menuBar.onRefresh = { [weak self] in self?.refreshDiagnostics() }
        microphoneSection.onStatusChanged = { [weak self] status in
            guard let self, status == .authorized, !self.micCapture.isPrepared, !self.micCapture.preparation.isPreparing else { return }
            Task { _ = await self.prepareCapture() }
        }
        historySection = history
        dictation.onAttemptFinished = { [weak menuBar] in menuBar?.refresh() }
        dictation.onHandsFreeChanged = { [weak menuBar] active in menuBar?.setHandsFree(active) }
        dictation.onLockEnded = { [weak self] in self?.hotkeyService?.releaseLock() }
        menuBar.onStopDictation = { [weak dictation] in dictation?.stopHandsFree() }
        menuBar.onCancelDictation = { [weak dictation] in
            guard let dictation else { return }
            Task { await dictation.cancelHandsFree() }
        }
        pill.onControl = { [weak dictation] control in
            guard let dictation else { return }
            switch control {
            case .stop: dictation.stopHandsFree()
            case .cancel: Task { await dictation.cancelHandsFree() }
            }
        }
        systemSection.onToggleRemap = { [weak self] in self?.toggleRemap() }
        systemSection.onChangeShortcut = { [weak self] in self?.showShortcutEditor() }
        systemSection.update(shortcut: ShortcutSettings.load())
        systemSection.update(remapChecked: remapCoordinator.menuChecked)
        registerGlobalShortcuts()
        trackStatus()

        refreshDiagnostics()
        observeDiagnosticModels()
        engineHost.start()
        cleanerHost.start()
        offerRecoveryWhenReady()
        let diagnosticLaunch = CaptureSelfTest.seconds(in: arguments) != nil || InputProbe.mode(in: arguments) != nil
        let showFirstSetup = !diagnosticLaunch && SetupLaunchPolicy.claimPresentation(defaults: .standard,
            microphone: MicrophoneAccess.status, accessibility: accessibility.isGranted)
        Task { await setUpCapture(requestPermission: diagnosticLaunch) }

        accessibility.onChange = { [weak self] granted in self?.accessibilityChanged(granted) }
        accessibility.start(prompt: diagnosticLaunch)
        if showFirstSetup { showSetup() }
        appUpdater.start()
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        guard menuBar != nil else { return }
        refreshDiagnostics()
        guard !micCapture.preparation.isPreparing else { return }
        Task {
            refreshMicrophone()
            _ = await prepareCapture()
        }
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating { return .terminateLater }
        guard appUpdater.allowsTermination else { return .terminateCancel }
        isTerminating = true
        termination.begin(preserve: { [self] in
            await dictation?.prepareForTermination() ?? true
        }, settleClipboard: { [self] in
            await inserter?.prepareForTermination()
        }, reply: { [self] ready in
            if !ready { isTerminating = false }
            sender.reply(toApplicationShouldTerminate: ready)
            if !ready {
                let alert = NSAlert()
                alert.messageText = "Couldn't finish saving the recording"
                alert.informativeText = "Mouthtype stayed open because the recording hasn't been fully saved. Resolve the storage or microphone problem, then try Quit again."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        })
        return .terminateLater
    }

    public func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        audioQuiet.end()
        fileTranscriptionModel.cancel()
        guard menuBar != nil else { return }
        shortcuts.unregisterAll()
        hotkeyService?.stop()
        _ = fnRemap.restore()
    }

    private func openStore() -> TranscriptStore? {
        do {
            return try TranscriptStore()
        } catch {
            Log.app.error("history unavailable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func purgeAudio(archive: AudioArchive, store: TranscriptStore?) {
        guard let store else { return }
        let policy = AudioRetentionPreference.load()
        Task.detached {
            do {
                let removed = try AudioRetentionMaintenance.prune(archive: archive, store: store, policy: policy, now: Date())
                Log.app.info("audio purge removed \(removed.count, privacy: .public) files")
            } catch {
                Log.app.error("audio purge failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func pasteLast() {
        guard !isTerminating else { return }
        guard let inserter, let pill, let cardPresenter else { return }
        Task {
            guard let result = await inserter.pasteLast() else {
                pill.showMessage("Nothing to paste yet")
                return
            }
            if let card = DeliveryCard.forDelivery(result, transcript: inserter.lastDelivered ?? "") { cardPresenter.present(card) }
        }
    }

    private func copyLast() {
        guard let inserter, let pill else { return }
        pill.showMessage(inserter.copyLast() ? "Copied" : "Nothing to copy yet")
    }

    /// Fn-key presence comes from an IOHIDManager enumeration, so the 2 s setup poll reuses the last full check's answer.
    private var cachedFnKeyPresent: Bool?

    private func refreshGlobeCheck(log: Bool = true, reuseFnPresence: Bool = false) {
        let check: GlobeKeyCheck
        if reuseFnPresence, let cached = cachedFnKeyPresent {
            check = GlobeKeyCheck.current(fnKeyPresent: cached)
        } else {
            check = GlobeKeyCheck.current()
            cachedFnKeyPresent = check.fnKeyPresent
        }
        // With the remap on the system never sees the Globe key, so its action can't conflict.
        systemSection.update(globe: remapCoordinator.isActive ? nil : check)
        systemSection.update(remapChecked: remapCoordinator.menuChecked)
        systemSection.update(shortcut: ShortcutSettings.load())
        diagnostics.globe = remapCoordinator.isActive ? nil : check
        diagnostics.remapChecked = remapCoordinator.menuChecked
        diagnostics.shortcut = ShortcutSettings.load()
        guard log else { return }
        Log.permissions.info("globe key action \(String(describing: check.action), privacy: .public), fn key present \(check.fnKeyPresent, privacy: .public), conflict \(check.hasConflict, privacy: .public)")
    }

    private func refreshMicrophone() {
        microphoneSection.refresh()
        diagnostics.microphoneStatus = MicrophoneAccess.status
        Log.permissions.info("microphone status \(MicrophoneAccess.statusText(for: MicrophoneAccess.status), privacy: .public)")
        refreshStatusIcon()
    }

    private func refreshDiagnostics() {
        _ = accessibility.tick()
        setupModel.refreshInstructions()
        refreshDiagnosticModels()
        refreshMicrophone()
        refreshGlobeCheck()
        diagnostics.accessibilityGranted = accessibility.isGranted
        diagnostics.hotkeyHealth = hotkeyService?.health ?? .off
        dictionary.reloadIfChanged()
        if case .error(let message) = dictionary.status { diagnostics.dictionaryError = message }
        else { diagnostics.dictionaryError = nil }
        do { _ = try phrases.all(); diagnostics.phrasesError = nil }
        catch { diagnostics.phrasesError = error.localizedDescription }
    }

    /// The setup poll refreshes only what `SetupReadiness` reads. Engine state and microphone preparation are observed
    /// directly. The Globe conflict is rechecked here too, since the user can change it in System Settings while setup is open.
    private func refreshSetupReadiness() {
        _ = accessibility.tick()
        refreshGlobeCheck(log: false, reuseFnPresence: true)
        diagnostics.microphoneStatus = MicrophoneAccess.status
        diagnostics.accessibilityGranted = accessibility.isGranted
        diagnostics.hotkeyHealth = hotkeyService?.health ?? .off
    }

    private func refreshDiagnosticModels() {
        diagnostics.refreshModels(speech: engineHost.statusText,
            failed: { if case .failed = engineHost.state { true } else { false } }(),
            cleaner: cleanerHost, level: CleanupSettings.load().level)
    }

    private func observeDiagnosticModels() {
        withObservationTracking {
            refreshDiagnosticModels()
        } onChange: { [weak self] in Task { @MainActor in self?.observeDiagnosticModels() } }
    }

    private func editDictionary() {
        do {
            let url = try dictionary.createIfMissing()
            if !NSWorkspace.shared.open(url) { diagnostics.dictionaryError = "The dictionary file could not be opened." }
        } catch { diagnostics.dictionaryError = error.localizedDescription }
    }

    private func editPhrasesFile() {
        guard FileManager.default.fileExists(atPath: phrases.url.path) else {
            diagnostics.phrasesError = "The phrase file no longer exists. Open Phrases to save a new file."
            return
        }
        if !NSWorkspace.shared.open(phrases.url) { diagnostics.phrasesError = "The phrase file could not be opened." }
    }

    private func refreshStatusIcon() {
        guard let menuBar, let dictation else { return }
        var engineFailed = false
        if case .failed = engineHost.state { engineFailed = true }
        if let pinned = StatusIcon.pinned(in: CommandLine.arguments) {
            menuBar.isPinned = true
            menuBar.setIcon(pinned)
            return
        }
        menuBar.setIcon(StatusIcon.resolve(
            phase: dictation.phase, engineFailed: engineFailed,
            microphoneAllowed: MicrophoneAccess.status == .authorized, accessibilityGranted: accessibility.isGranted
        ))
    }

    /// Re-draws the icon whenever the dictation phase or the engine state changes.
    private func trackStatus() {
        refreshStatusIcon()
        withObservationTracking {
            _ = dictation?.phase
            _ = engineHost.state
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackStatus() }
        }
    }

    /// Once the engine is up, offers the dictation a crash cut off. Looks once per launch.
    private func offerRecoveryWhenReady() {
        guard let recovery, !recoveryChecked else { return }
        guard case .ready = engineHost.state else {
            withObservationTracking {
                _ = engineHost.state
            } onChange: { [weak self] in
                Task { @MainActor in self?.offerRecoveryWhenReady() }
            }
            return
        }
        recoveryChecked = true
        Task { await recovery.offerIfNeeded() }
    }

    private func accessibilityChanged(_ granted: Bool) {
        Log.permissions.info("accessibility \(granted ? "allowed" : "needed", privacy: .public)")
        systemSection.update(accessibilityGranted: granted)
        diagnostics.accessibilityGranted = granted
        refreshStatusIcon()
        if granted { startInput() }
    }

    private func startInput() {
        guard !inputStarted, shortcutWindow == nil else { return }
        inputStarted = true
        if let mode = InputProbe.mode(in: CommandLine.arguments) {
            Task { await InputProbe.run(mode, remap: fnRemap) }
            return
        }

        let source = ShortcutSettings.load().map(HotkeySource.shortcut) ?? remapCoordinator.initialSource()
        let service = hotkeyService ?? HotkeyService(options: .init(source: source, configuration: .init(recordingMode: RecordingModePreference.current())))
        service.onHealthChange = { [weak self] health in
            Log.hotkey.info("health \(health.statusText, privacy: .public)")
            self?.systemSection.update(hotkeyHealth: health)
            self?.diagnostics.hotkeyHealth = health
        }
        do {
            try service.switchSource(source)
            try service.start()
        } catch {
            Log.hotkey.error("hotkey not started: \(String(describing: error), privacy: .public)")
            // With no tap there is nothing to swallow F19, so don't leave Fn remapped.
            remapCoordinator.deactivate()
            refreshGlobeCheck()
            inputStarted = false
            return
        }
        Log.hotkey.info("hotkey source \(String(describing: service.source), privacy: .public)")
        refreshGlobeCheck()
        hotkeyService = service
        systemSection.update(hotkeyHealth: service.health)
        diagnostics.hotkeyHealth = service.health
        guard hotkeyLogTask == nil, let dictation else { return }
        hotkeyLogTask = Task { await dictation.consume(service.events) }
    }

    private func toggleRemap() {
        guard ShortcutSettings.load() == nil else { return }
        let enable = !remapCoordinator.menuChecked
        let source = remapCoordinator.setEnabled(enable)
        if let service = hotkeyService {
            do {
                try service.switchSource(source)
            } catch {
                Log.hotkey.error("hotkey source switch failed: \(String(describing: error), privacy: .public)")
            }
        }
        let state = remapCoordinator.isActive ? "on" : "off"
        Log.hotkey.info("fn remap \(state, privacy: .public)")
        refreshGlobeCheck()
    }

    private func registerGlobalShortcuts() {
        shortcuts.unregisterAll()
        let shortcut = ShortcutSettings.load()
        if shortcut?.claimsLastAction(keyCode: GlobalShortcuts.Shortcut.pasteLast.keyCode) != true {
            shortcuts.register(.pasteLast) { [weak self] in self?.pasteLast() }
        }
        if shortcut?.claimsLastAction(keyCode: GlobalShortcuts.Shortcut.copyLast.keyCode) != true {
            shortcuts.register(.copyLast) { [weak self] in self?.copyLast() }
        }
    }

    private func activateShortcut(_ shortcut: DictationShortcut?) -> String? {
        guard let service = hotkeyService else { return nil }
        let source: HotkeySource
        if let shortcut {
            guard remapCoordinator.deactivate() else { return "Fn could not be restored. Try again." }
            source = .shortcut(shortcut)
        } else { source = remapCoordinator.initialSource() }
        do {
            try service.switchSource(source)
            try service.start()
            return nil
        } catch {
            service.stop()
            remapCoordinator.deactivate()
            return "The input listener could not start. Check Accessibility access, then try again. Your previous shortcut is still saved."
        }
    }

    private func activateRecordingMode(_ mode: RecordingMode) -> String? {
        guard shortcutWindow == nil else { return "Finish changing the shortcut before changing recording behavior." }
        guard let service = hotkeyService else { return nil }
        let source = ShortcutSettings.load().map(HotkeySource.shortcut) ?? remapCoordinator.initialSource()
        do {
            try service.switchRecordingMode(mode, source: source)
            try service.start()
            inputStarted = true
            return nil
        } catch {
            service.stop()
            inputStarted = false
            // The stopped service can restore the saved behavior without installing taps.
            try? service.switchRecordingMode(RecordingModePreference.current())
            remapCoordinator.deactivate()
            refreshGlobeCheck()
            return "The input listener could not start. Check Accessibility access, then try again. Your previous recording behavior is still saved."
        }
    }

    private func showShortcutEditor() {
        if let shortcutWindow { shortcutWindow.present(); return }
        guard dictation?.phase == .idle else {
            pill?.showMessage("Finish or cancel this dictation before changing its shortcut")
            return
        }
        guard remapCoordinator.deactivate() else {
            pill?.showMessage("Fn could not be restored. Try changing the shortcut again.")
            return
        }
        hotkeyService?.stop()
        shortcuts.unregisterAll()
        let window = ShortcutRecorderWindow(saved: ShortcutSettings.load(), apply: { [weak self] shortcut in
            guard let self else { return "Mouthtype is closing." }
            return ShortcutSettings.apply(shortcut, activate: self.activateShortcut)
        }, onClose: { [weak self] in
            guard let self else { return }
            self.shortcutWindow = nil
            guard !self.isTerminating else { return }
            if let error = self.activateShortcut(ShortcutSettings.load()) {
                self.pill?.showMessage(error)
                self.hotkeyLogTask?.cancel()
                self.hotkeyLogTask = nil
                self.hotkeyService = nil
                self.inputStarted = false
            }
            if self.accessibility.isGranted { self.startInput() }
            self.registerGlobalShortcuts()
            self.refreshGlobeCheck()
        })
        shortcutWindow = window
        window.present()
    }

    private func showSetup() {
        guard dictation?.phase == .idle, recovery?.isRecovering != true else {
            pill?.showMessage("Finish or cancel this dictation before opening setup")
            return
        }
        setupWindow.present()
    }

    private func requestSetupMicrophone() {
        switch MicrophoneAccess.status {
        case .denied, .restricted:
            NSWorkspace.shared.open(MicrophoneAccess.settingsURL)
        default:
            Task {
                await MicrophoneAccess.requestIfUndetermined()
                refreshMicrophone()
                _ = await prepareCapture()
            }
        }
    }

    private func microphoneSelectionChanged() {
        micCapture.invalidatePreparation()
        guard dictation?.phase == .idle, !isTerminating else { return }
        Task { _ = await prepareCapture() }
    }

    private func prepareCapture() async -> Bool {
        guard MicrophoneAccess.status == .authorized else {
            micCapture.invalidatePreparation()
            return false
        }
        guard !micCapture.preparation.isPreparing, !isTerminating else { return false }
        guard dictation?.phase != .recording else { return false }
        do {
            let ready = try await micCapture.prepare()
            Log.capture.info("microphone prepared: \(ready, privacy: .public)")
            return ready
        } catch {
            Log.capture.error("capture not prepared: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func setUpCapture(requestPermission: Bool) async {
        if requestPermission { await MicrophoneAccess.requestIfUndetermined() }
        refreshMicrophone()
        let selfTestSeconds = CaptureSelfTest.seconds(in: CommandLine.arguments)

        guard await prepareCapture() else {
            if selfTestSeconds != nil { NSApp.terminate(nil) }
            return
        }
        if let seconds = selfTestSeconds {
            await CaptureSelfTest.run(capture: micCapture.capture, seconds: seconds)
            NSApp.terminate(nil)
        }
    }
}
