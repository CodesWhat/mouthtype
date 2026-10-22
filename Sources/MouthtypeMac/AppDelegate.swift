import AppKit
import MouthtypeCore

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engineHost = EngineHost()
    private let cleanerHost = CleanupSelection(
        fast: CleanerCatalog.makeSmartCleanup(level: .light), thorough: CleanerCatalog.makeSmartCleanup(level: .medium),
        level: { SmartTestOptions.modelLevel(in: CommandLine.arguments, saved: CleanupSettings.load().level) },
        budget: SmartTestOptions.budget(in: CommandLine.arguments)
    )
    private let dictionary = FileVocabulary()
    private let phrases = FilePhrases()
    private let diagnostics = SettingsDiagnostics()
    private lazy var setupModel = SetupModel(diagnostics: diagnostics, engine: engineHost, microphone: micCapture.preparation, cleanup: cleanerHost)
    private lazy var setupWindow = SetupWindow(
        model: setupModel,
        actions: SetupActions(
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
            inputSettings: { [weak self] in self?.settingsWindow.present(destination: .settings(.health)) }))
    private let fontChooser = TextFontMenuSection()
    private lazy var appUpdater: AppUpdater = AppUpdater(
        driver: UpdateLaunchPolicy.allows(
            arguments: CommandLine.arguments, bundleURL: Bundle.main.bundleURL,
            info: Bundle.main.infoDictionary ?? [:]) ? SparkleDriver() : nil,
        activity: { [weak self] in
            .resolve(
                phase: self?.dictation?.phase, recovering: self?.recovery?.isRecovering == true,
                transcribingFile: self?.fileTranscriptionModel.isBusy == true, editingSelection: self?.selectionCleanupModel.hasPreview == true)
        })
    private lazy var selectionCleanupModel = SelectionCleanupModel(
        editor: AccessibilitySelectionEditor(), transformer: cleanerHost,
        busy: { [weak self] in
            guard let self else { return true }
            return self.isTerminating || self.dictation?.phase != .idle || self.fileTranscriptionModel.isBusy || self.recovery?.isRecovering == true || self.appUpdater.blocksNewWork
        }, changed: { [weak self] in self?.appUpdater.refreshActivity() },
        styleFor: { selection in
            // The tone that applies to the focused app: its rule, else the global default.
            let styles = (try? AppCleanupStyles.load()) ?? AppCleanupStyles()
            return styles.resolve(
                bundleID: NSRunningApplication(processIdentifier: selection.pid)?.bundleIdentifier,
                fallback: CleanupSettings.load().style)
        })
    private lazy var selectionCleanupWindow = SelectionCleanupWindow(model: selectionCleanupModel)
    private lazy var fileTranscriptionModel: FileTranscriptionModel = FileTranscriptionModel(
        makeJob: { [weak self] in
            guard let self, case .ready = self.engineHost.state, let engine = self.engineHost.engine else {
                throw CocoaError(.featureUnsupported)
            }
            // A dictation in an editor leaves its code names on the shared engine. An import gets the saved words only.
            let bias = VocabularyBoostSetting.bias(enabled: VocabularyBoostSetting.isEnabled(), rules: self.dictionary.dictionary())
            return AudioFileTranscription(
                decoder: MacAudioFileDecoder(), engine: engine,
                beforeTranscribing: {
                    await (engine as? any VocabularyBiasing)?.setVocabularyBias(bias)
                })
        },
        canBegin: { [weak self] in
            guard let self, !self.isTerminating else { return false }
            return self.dictation?.phase == .idle && self.recovery?.isRecovering != true && !self.appUpdater.blocksNewWork
        },
        activityChanged: { [weak self] in
            self?.appUpdater.refreshActivity()
            self?.menuBar?.refresh()
            self?.builtSettingsWindow?.model.home.refreshRecoverability()
        }, copy: { SystemClipboard().write($0) })
    private lazy var fileTranscriptionWindow = FileTranscriptionWindow(model: fileTranscriptionModel)
    private lazy var spellingEditor = SpellingEditor(store: dictionary)
    private lazy var spellingSuggestions = SpellingSuggestionsModel(vocabulary: dictionary)
    /// Built on first use, which is the first time the window is presented. Launch never touches it, so the models behind it
    /// (`SettingsModel.init` alone is ~100 ms) stay out of the path to the menu bar item.
    lazy var settingsWindow: SettingsWindow = wiredSettingsWindow(
        SettingsWindow(
            model: SettingsModel(
                onCleanupChanged: { [weak self] in
                    self?.cleanerHost.levelChanged(); self?.refreshDiagnosticModels()
                },
                onSkinChanged: { [weak self] kind in self?.pill?.setSkin(kind) },
                onRecordingModeChanged: { [weak self] mode in self?.activateRecordingMode(mode) },
                onMouseTriggerChanged: { [weak self] trigger in self?.activateMouseTrigger(trigger) },
                onMicrophoneChanged: { [weak self] in self?.microphoneSelectionChanged() },
                onQuietOtherAudioChanged: { [weak self] enabled in if !enabled { self?.audioQuiet.end() } },
                onBoostSavedWordsChanged: { [weak self] _ in self?.refreshVocabularyBias() },
                onDockIconModeChanged: { [weak self] _ in self?.dockPresence.refresh() },
                spellings: spellingEditor, spellingSuggestions: spellingSuggestions, phrases: PhraseEditor(store: phrases),
                openTranscribeWindow: { [weak self] in self?.fileTranscriptionWindow.present() }),
            actions: SettingsActions(
                openSetup: { [weak self] in self?.showSetup() }, changeShortcut: { [weak self] in self?.showShortcutEditor() },
                cleaner: cleanerHost,
                diagnostics: diagnostics, retrySpeech: { [weak self] in self?.engineHost.start() },
                refreshDiagnostics: { [weak self] in self?.refreshDiagnostics() },
                toggleRemap: { [weak self] in self?.toggleRemap() },
                openMicSettings: { NSWorkspace.shared.open(MicrophoneAccess.settingsURL) },
                openAccessibilitySettings: { NSWorkspace.shared.open(AccessibilityAccess.settingsURL) },
                openKeyboardSettings: { NSWorkspace.shared.open(GlobeKeyCheck.settingsURL) },
                editDictionary: { [weak self] in self?.editDictionary() },
                editPhrasesFile: { [weak self] in self?.editPhrasesFile() },
                chooseFont: { [weak self] in self?.fontChooser.presentFontChooser() }, updater: appUpdater)))
    private(set) var settingsWindowBuilt = false
    var settingsStore: TranscriptStore?
    /// The window if something has already presented it. Callbacks that only refresh it use this so they don't build it.
    private var builtSettingsWindow: SettingsWindow? { settingsWindowBuilt ? settingsWindow : nil }

    /// Hands the store and the recovery hooks to the models the first time the window exists.
    private func wiredSettingsWindow(_ window: SettingsWindow) -> SettingsWindow {
        wireSettingsModels(window.model)
        settingsWindowBuilt = true
        return window
    }

    /// Safe to repeat: completeLaunch runs it again for a window something built before the store and recovery existed.
    private func wireSettingsModels(_ model: SettingsModel) {
        model.home.store = settingsStore
        model.stats.store = settingsStore
        model.spellingSuggestions?.store = settingsStore
        if let recovery {
            let home = model.home
            home.saved = { [weak recovery] in try await recovery?.loadSavedRecordings() ?? [] }
            home.completedAudio = { [weak recovery] rows in await recovery?.loadCompletedRecordings(for: rows) ?? [] }
            home.canRecover = recovery.canRecover
            home.recoverTake = { [weak recovery] item in recovery?.offerSaved(item) }
        }
    }

    /// Open-URL events that arrived before launch finished. They replay in order once the store, pill and menu exist.
    private var pendingOpenURLs: [[URL]] = []
    private(set) var launchComplete = false
    var pendingOpenCount: Int { pendingOpenURLs.count }

    /// Re-wires a settings window built early, then replays what arrived during launch. A quit that arrived meanwhile runs after the replay.
    func finishLaunch() {
        if settingsWindowBuilt { wireSettingsModels(settingsWindow.model) }
        launchComplete = true
        let pending = pendingOpenURLs
        pendingOpenURLs = []
        for urls in pending { application(NSApp, open: urls) }
        resumeDeferredQuit()
    }

    /// Drops the queue and releases a waiting quit. For a launch that can't finish; the quit deadline is the only caller so far.
    func abandonLaunch(reason: String) {
        if !pendingOpenURLs.isEmpty { Log.app.error("dropped \(self.pendingOpenURLs.count, privacy: .public) queued URL event(s): \(reason, privacy: .public)") }
        pendingOpenURLs = []
        resumeDeferredQuit()
    }

    /// How long a quit waits for the launch gap to close before the queue is dropped and the quit goes ahead.
    var quitDeadline: Duration = .seconds(3)
    private var deferredQuit: (sender: NSApplication, deadline: Task<Void, Never>)?
    /// Answers the system's pending applicationShouldTerminate.
    var replyToTermination: @MainActor (NSApplication, Bool) -> Void = { sender, ready in sender.reply(toApplicationShouldTerminate: ready) }

    /// A quit while URLs are still queued waits for them to replay first. Returns true when the quit is being held.
    func deferQuitForQueuedURLs(sender: NSApplication) -> Bool {
        guard !launchComplete, !pendingOpenURLs.isEmpty else { return false }
        if deferredQuit != nil { return true }
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: self?.quitDeadline ?? .seconds(3))
            guard !Task.isCancelled else { return }
            self?.abandonLaunch(reason: "launch didn't finish before quit")
        }
        deferredQuit = (sender, deadline)
        return true
    }

    /// Answers the held terminateLater exactly once, through the same path as an undeferred quit.
    private func resumeDeferredQuit() {
        guard let held = deferredQuit else { return }
        deferredQuit = nil
        held.deadline.cancel()
        if beginTermination(sender: held.sender) == .terminateCancel { replyToTermination(held.sender, false) }
    }

    /// Hands the engine the current bias now, so turning the setting on starts the model download without waiting for a take.
    private func refreshVocabularyBias() {
        let bias = VocabularyBoostSetting.bias(enabled: VocabularyBoostSetting.isEnabled(), rules: dictionary.dictionary())
        let engine = HostEngine(host: engineHost)
        Task { await engine.setVocabularyBias(bias) }
    }

    private let micCapture = MicCapture()
    private let audioQuiet = RecordingAudioQuiet(output: CoreAudioQuietOutput(), enabled: { QuietAudioPreference.isEnabled() })
    private let microphoneSection = MicrophoneMenuSection()
    private let systemSection = SystemAccessMenuSection()
    private let accessibility = AccessibilityAccess()
    private let fnRemap = FnRemap()
    private var signalShutdown = false
    private var wakeObserver: NSObjectProtocol?
    private lazy var remapCoordinator = FnRemapCoordinator(
        remap: fnRemap, guardian: FnGuardLauncher(),
        requestTermination: { [unowned self] in
            // A signal can't wait on a person: no unsaved-draft prompt and no failure alert on this path.
            signalShutdown = true
            FnRemap.requestQuit { NSApp.terminate(nil) }
        })
    private let shortcuts = GlobalShortcuts()
    private var menuBar: MenuBarController?
    private var historySection: HistoryMenuSection?
    private var hotkeyService: HotkeyService?
    private var shortcutSheet: ShortcutRecorderSheet?
    private var hotkeyLogTask: Task<Void, Never>?
    private var pill: PillController?
    private var cardController: DeliveryCardController?
    private var cardPresenter: DeliveryCardPresenter?
    private var inserter: TextInserter?
    private var correctionWatcher: CorrectionWatcher?
    private var dictation: DictationController?
    private var recovery: CrashRecovery?
    private var recoveryChecked = false
    private var draftOffer: DraftOffer?
    private let launchedAt = Date()
    private var inputStarted = false
    private var isTerminating = false
    private let termination = AppTermination()
    private lazy var dockPresence = DockPresence()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("launch \(AppInfo.version, privacy: .public)")
        let arguments = CommandLine.arguments
        // The two file/visual modes need no permissions and touch neither the remap, the mic nor the real database.
        if let demo = PillDemo.options(in: arguments) {
            FontRegistry.registerBundledFonts()
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

        // The status item goes up first and fonts start registering off the main thread. Everything that builds a pill or
        // card (and so draws with a bundled font) waits for the next run-loop turn, after the item has been committed.
        dockPresence.start()
        beginLaunch { [weak self] menuBar in self?.completeLaunch(arguments: arguments, menuBar: menuBar) }
    }

    /// Creates the status item and starts font registration without touching anything font-dependent, then runs `finish`
    /// on the next main-queue turn.
    func beginLaunch(statusItem: () -> MenuBarController = { MenuBarController() }, finish: @escaping @MainActor (MenuBarController) -> Void) {
        let menuBar = statusItem()
        FontRegistry.registerInBackground()
        DispatchQueue.main.async { MainActor.assumeIsolated { finish(menuBar) } }
    }

    private func completeLaunch(arguments: [String], menuBar: MenuBarController) {
        // Undo a Fn remap a previous run died with before anything reads the keyboard.
        _ = fnRemap.restoreIfStale()
        let store = openStore()
        let archive = AudioArchive(supportDirectory: TranscriptStore.defaultURL().deletingLastPathComponent())
        purgeAudio(archive: archive, store: store)

        let level = micCapture.capture
        let pill = PillController(level: { level.reading })
        let inserter = TextInserter(syntheticStamp: SyntheticEvents.stamp, inputGeneration: { [weak self] in self?.hotkeyService?.userInputGeneration })
        if let store {
            do { try inserter.restoreLast(from: store) } catch { Log.app.error("last transcript unavailable: \(error.localizedDescription, privacy: .public)") }
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
        ProfanityRemover.prewarm()
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
        draftOffer = DraftOffer(recovery: .standard, cards: presenter)
        let watcher = CorrectionWatcher(
            reader: AccessibilityFieldReader(), dictionary: dictionary, ledger: CorrectionLedger(),
            store: store.map(CorrectionStoreWriter.init), cards: presenter, clock: SystemDictationClock(),
            input: { [weak self] in self?.hotkeyService?.userInputGeneration },
            canOffer: { [weak dictation] in dictation?.phase == .idle }
        )
        watcher.onNotice = { [weak pill] message in pill?.showMessage(message, duration: 4) }
        dictation.corrections = watcher
        correctionWatcher = watcher

        pill.onLevel = { [weak menuBar] level in menuBar?.setLevel(level) }
        let history = HistoryMenuSection(store: store, onError: { [weak self] error in self?.diagnostics.historyError = error })
        settingsStore = store
        let settingsSection = SettingsMenuSection(
            open: { [weak self] in self?.settingsWindow.present(destination: .settings(.general)) },
            openHome: { [weak self] in self?.settingsWindow.present(page: .home) })
        menuBar.add(
            section: AttentionMenuSection(
                diagnostics: diagnostics,
                open: { [weak self] in
                    guard let self else { return }
                    if self.diagnostics.microphoneStatus != .authorized || !self.diagnostics.accessibilityGranted {
                        self.showSetup()
                    } else {
                        self.settingsWindow.present(destination: .settings(.health))
                    }
                }))
        menuBar.add(section: EngineRetryMenuSection(host: engineHost), startsGroup: false)
        menuBar.add(section: UpdateAvailableMenuSection(updater: appUpdater), startsGroup: false)
        menuBar.add(section: settingsSection)
        NSApp.mainMenu = settingsSection.applicationMenu()
        menuBar.add(
            section: ActionsMenuSection(
                onPasteLast: { [weak self] in self?.pasteLast() }, onCopyLast: { [weak self] in self?.copyLast() }
            ))
        menuBar.add(section: history, startsGroup: false)
        menuBar.add(
            section: TransformSelectionMenuSection(
                open: { [weak self] in self?.selectionCleanupWindow.present(transform: $0) },
                editTransforms: { [weak self] in self?.settingsWindow.present(page: .transforms) },
                aiUnavailableReason: { [weak self] in self?.selectionCleanupModel.transformUnavailableReason },
                capture: { [weak self] in
                    guard let self, AXIsProcessTrusted() else { return .unavailable }
                    return await self.selectionCleanupModel.captureForMenuOffMain()
                }))
        menuBar.add(section: FileTranscriptionMenuSection { [weak self] in self?.settingsWindow.present(destination: .transcribeFile) }, startsGroup: false)
        if let recovery {
            recovery.canRecover = { [weak self, weak dictation, weak engineHost, weak recovery] in
                guard dictation?.phase == .idle, recovery?.isRecovering != true, let engineHost else { return false }
                guard self?.isTerminating != true, self?.appUpdater.blocksNewWork != true, self?.fileTranscriptionModel.isBusy != true else { return false }
                if case .ready = engineHost.state { return true }
                return false
            }
            menuBar.add(section: SavedRecordingsMenuSection(recovery: recovery, canRecover: recovery.canRecover), startsGroup: false)
            recovery.onFinished = { [weak self, weak menuBar] in
                menuBar?.refresh()
                // An unbuilt window has nothing on screen; its first present reloads the page.
                guard let home = self?.builtSettingsWindow?.model.home else { return }
                home.refreshRecoverability()
                home.startReload()
            }
        }
        dictation.canStartRecording = { [weak self] in
            self?.isTerminating != true && self?.recovery?.isRecovering != true && self?.appUpdater.blocksNewWork != true && self?.fileTranscriptionModel.isBusy != true
        }
        menuBar.add(section: UpdateMenuSection(updater: appUpdater), isFooter: true)
        menuBar.add(section: HelpMenuSection(), isFooter: true)
        self.menuBar = menuBar
        menuBar.onRefresh = { [weak self] in self?.refreshDiagnostics() }
        microphoneSection.onStatusChanged = { [weak self] status in
            guard let self, status == .authorized, !self.micCapture.isPrepared, !self.micCapture.preparation.isPreparing else { return }
            Task { _ = await self.prepareCapture() }
        }
        historySection = history
        dictation.onAttemptFinished = { [weak self, weak menuBar] in
            menuBar?.refresh(); self?.builtSettingsWindow?.model.home.refreshRecoverability()
        }
        dictation.onHandsFreeChanged = { [weak menuBar] active in menuBar?.setHandsFree(active) }
        dictation.onLockEnded = { [weak self] in self?.hotkeyService?.releaseLock() }
        dictation.onAutomationLock = { [weak self] in self?.hotkeyService?.adoptLockedRecording() }
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
        let showFirstSetup =
            !diagnosticLaunch
            && SetupLaunchPolicy.claimPresentation(
                defaults: .standard,
                microphone: MicrophoneAccess.status, accessibility: accessibility.isGranted)
        Task { await setUpCapture(requestPermission: diagnosticLaunch) }

        accessibility.onChange = { [weak self] granted in self?.accessibilityChanged(granted) }
        accessibility.start(prompt: diagnosticLaunch)
        if showFirstSetup { showSetup() }
        appUpdater.start()
        finishLaunch()
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        guard !isTerminating else { return }
        guard launchComplete else { pendingOpenURLs.append(urls); return }
        let router = automationRouter()
        for url in urls {
            if case .disabled = router.handle(url) {
                showNotice(PillMessage("Automation is off", detail: "See the automation docs"), duration: 3)
            }
        }
    }

    /// A line on the pill that never takes a live recording's place.
    private func showNotice(_ message: PillMessage, duration: TimeInterval = 2.5) {
        if let dictation { dictation.showNotice(message, duration: duration) } else { pill?.showMessage(message, duration: duration) }
    }

    private func automationRouter() -> AutomationRouter {
        AutomationRouter(
            actions: AutomationActions(
                // Queued, so a stop or cancel that follows a start waits for the recording the start is still bringing up.
                startDictation: { [weak self] in self?.dictation?.enqueueAutomation(.start) },
                stopDictation: { [weak self] in self?.dictation?.enqueueAutomation(.stop) },
                toggleDictation: { [weak self] in self?.dictation?.enqueueAutomation(.toggle) },
                cancelDictation: { [weak self] in self?.dictation?.enqueueAutomation(.cancel) },
                copyLast: { [weak self] in self?.copyLast() },
                pasteLast: { [weak self] in self?.pasteLast() },
                // present(page:) moves through SettingsModel.select, so an unsaved spelling or phrase draft still asks first.
                open: { [weak self] page in self?.settingsWindow.present(destination: page.destination) }
            ))
    }

    /// Clicking the Dock icon with nothing open brings up the main window. Not in Never, where there is no Dock icon to click.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard launchComplete, !flag, DockIconMode.current() != .never else { return true }
        settingsWindow.present(page: .home)
        return false
    }

    public func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard launchComplete else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Open Mouthtype", action: #selector(openFromDockMenu), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func openFromDockMenu() { settingsWindow.present(page: .home) }

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
        if deferQuitForQueuedURLs(sender: sender) { return .terminateLater }
        return beginTermination(sender: sender)
    }

    private func beginTermination(sender: NSApplication) -> NSApplication.TerminateReply {
        guard Self.mayQuit(allowsTermination: appUpdater.allowsTermination, resolveDraft: { signalShutdown ? saveDraftsForSignal() : (builtSettingsWindow?.resolveDraftForQuit() ?? true) }) else {
            return .terminateCancel
        }
        isTerminating = true
        termination.begin(
            preserve: { [self] in
                await dictation?.prepareForTermination() ?? true
            },
            settleClipboard: { [self] in
                await inserter?.prepareForTermination()
            },
            reply: { [self] ready in
                if !ready { isTerminating = false }
                // The draft the user agreed to discard goes only once the quit is certain; a delayed quit keeps it.
                if ready, !signalShutdown { builtSettingsWindow?.discardDraftForQuit() }
                replyToTermination(sender, ready)
                if !ready, !signalShutdown {
                    let alert = NSAlert()
                    alert.messageText = "Couldn't finish saving the recording"
                    alert.informativeText = "Mouthtype stayed open because the recording hasn't been fully saved. Resolve the storage or microphone problem, then try Quit again."
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            })
        return .terminateLater
    }

    /// A signal can't ask whether to keep a draft, so both editors' drafts go to disk and stay in Application Support/Mouthtype/drafts.
    private func saveDraftsForSignal() -> Bool {
        // Drafts live in the settings window's editors; if it was never built there is nothing to save.
        guard let window = builtSettingsWindow else { return true }
        let saved = DraftRecovery.standard.saveDrafts(spellings: window.model.spellings, phrases: window.model.phrases)
        if !saved.isEmpty { Log.app.info("saved \(saved.count, privacy: .public) unsaved draft(s) before quitting on a signal") }
        return true
    }

    static func mayQuit(allowsTermination: Bool, resolveDraft: () -> Bool) -> Bool {
        allowsTermination && resolveDraft()
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
        guard let inserter, let cardPresenter else { return }
        Task {
            guard let result = await inserter.pasteLast() else {
                showNotice(PillMessage("Nothing to paste yet"))
                return
            }
            if let card = DeliveryCard.forDelivery(result, transcript: inserter.lastDelivered ?? "") { cardPresenter.present(card) }
        }
    }

    private func copyLast() {
        guard let inserter else { return }
        showNotice(PillMessage(inserter.copyLast() ? "Copied" : "Nothing to copy yet"))
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
        diagnostics.remapConflict = remapCoordinator.conflict
        diagnostics.shortcut = ShortcutSettings.load()
        guard log else { return }
        Log.permissions.info(
            "globe key action \(String(describing: check.action), privacy: .public), fn key present \(check.fnKeyPresent, privacy: .public), conflict \(check.hasConflict, privacy: .public)")
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
        if case .error(let message) = dictionary.status { diagnostics.dictionaryError = message } else { diagnostics.dictionaryError = nil }
        diagnostics.phrasesError = phrases.healthError()
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
        diagnostics.refreshModels(
            speech: engineHost.statusText,
            failed: { if case .failed = engineHost.state { true } else { false } }(),
            cleaner: cleanerHost, level: CleanupSettings.load().level)
    }

    private func observeDiagnosticModels() {
        withObservationTracking {
            refreshDiagnosticModels()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeDiagnosticModels() }
        }
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
        menuBar.setIcon(
            StatusIcon.resolve(
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
        guard !recoveryChecked else { return }
        guard case .ready = engineHost.state else {
            withObservationTracking {
                _ = engineHost.state
            } onChange: { [weak self] in
                Task { @MainActor in self?.offerRecoveryWhenReady() }
            }
            return
        }
        recoveryChecked = true
        let recovery = recovery, draftOffer = draftOffer
        Task {
            // One card at a time: a dictation a crash cut off goes first, and drafts wait on disk for the next launch.
            let scan = await recovery?.offerIfNeeded()
            if scan?.newest == nil { draftOffer?.offerIfNeeded() }
        }
    }

    private func accessibilityChanged(_ granted: Bool) {
        Log.permissions.info("accessibility \(granted ? "allowed" : "needed", privacy: .public)")
        systemSection.update(accessibilityGranted: granted)
        diagnostics.accessibilityGranted = granted
        refreshStatusIcon()
        if granted { startInput() }
    }

    private func startInput() {
        guard !inputStarted, shortcutSheet == nil else { return }
        inputStarted = true
        if let mode = InputProbe.mode(in: CommandLine.arguments) {
            Task { await InputProbe.run(mode, remap: fnRemap) }
            return
        }

        let source = ShortcutSettings.load().map(HotkeySource.shortcut) ?? remapCoordinator.initialSource()
        let service =
            hotkeyService
            ?? HotkeyService(
                options: .init(
                    source: source, configuration: .init(recordingMode: RecordingModePreference.current()),
                    mouseTrigger: MouseTriggerPreference.current()))
        service.onHealthChange = { [weak self] health in
            Log.hotkey.info("health \(health.statusText, privacy: .public)")
            self?.systemSection.update(hotkeyHealth: health)
            self?.diagnostics.hotkeyHealth = health
        }
        service.onWatchdog = { [weak self] in self?.verifyRemap() }
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.verifyRemap() } }
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

    /// Something else (a login agent running `hidutil`) can rewrite the key mapping after we applied ours, which
    /// leaves Fn silently dead. Check at every watchdog tick and on wake; on an unrepairable loss, fall back to raw Fn.
    private func verifyRemap() {
        guard let service = hotkeyService, remapCoordinator.isActive, !remapCoordinator.verify() else { return }
        do {
            try service.switchSource(remapCoordinator.source)
        } catch {
            Log.hotkey.error("hotkey source switch failed: \(String(describing: error), privacy: .public)")
        }
        refreshGlobeCheck(log: false)
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
        } else {
            source = remapCoordinator.initialSource()
        }
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
        guard shortcutSheet == nil else { return "Finish changing the shortcut before changing recording behavior." }
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

    private func activateMouseTrigger(_ trigger: MouseTrigger) -> String? {
        guard let service = hotkeyService else { return nil }
        do {
            try service.switchMouseTrigger(trigger)
            return nil
        } catch {
            return "The mouse button could not be listened to. Check Accessibility access, then try again. Your previous choice is still saved."
        }
    }

    private func showShortcutEditor() {
        if shortcutSheet != nil { settingsWindow.present(); return }
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
        let sheet = ShortcutRecorderSheet(
            saved: ShortcutSettings.load(),
            apply: { [weak self] shortcut in
                guard let self else { return "Mouthtype is closing." }
                return ShortcutSettings.apply(shortcut, activate: self.activateShortcut)
            },
            onClose: { [weak self] in
                guard let self else { return }
                self.shortcutSheet = nil
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
        shortcutSheet = sheet
        settingsWindow.present()
        if let parent = settingsWindow.topmostWindow { sheet.present(over: parent) } else { sheet.close() }
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
