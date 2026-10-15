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
    private let micCapture = MicCapture()
    private let microphoneSection = MicrophoneMenuSection()
    private let systemSection = SystemAccessMenuSection()
    private let accessibility = AccessibilityAccess()
    private let fnRemap = FnRemap()
    private lazy var remapCoordinator = FnRemapCoordinator(remap: fnRemap, guardian: FnGuardLauncher())
    private let shortcuts = GlobalShortcuts()
    private var menuBar: MenuBarController?
    private var historySection: HistoryMenuSection?
    private var hotkeyService: HotkeyService?
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
    private var preparingCapture = false

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
        pipeline.vocabulary = dictionary
        pipeline.smart = cleanerHost
        let dictation = DictationController(
            capture: micCapture, engine: engine, pipeline: pipeline,
            inserter: inserter, pill: pill, sounds: sounds, clock: SystemDictationClock(), cards: presenter
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

        let menuBar = MenuBarController(engineHost: engineHost)
        let history = HistoryMenuSection(store: store)
        menuBar.add(section: microphoneSection)
        menuBar.add(section: systemSection)
        menuBar.add(section: EngineRetryMenuSection(host: engineHost))
        menuBar.add(section: history)
        if let recovery {
            recovery.canRecover = { [weak dictation, weak engineHost] in
                guard dictation?.phase == .idle, let engineHost else { return false }
                if case .ready = engineHost.state { return true }
                return false
            }
            menuBar.add(section: SavedRecordingsMenuSection(recovery: recovery, canRecover: recovery.canRecover))
            recovery.onFinished = { [weak menuBar] in menuBar?.refresh() }
            dictation.canStartRecording = { [weak recovery] in recovery?.isRecovering != true }
        }
        menuBar.add(section: PillSkinMenuSection(onSelect: { [weak pill] kind in pill?.setSkin(kind) }))
        menuBar.add(section: TextFontMenuSection())
        menuBar.add(section: CleanupMenuSection(cleaner: cleanerHost, dictionary: dictionary))
        menuBar.add(section: ActionsMenuSection(
            onPasteLast: { [weak self] in self?.pasteLast() }, onCopyLast: { [weak self] in self?.copyLast() }
        ))
        menuBar.add(section: HelpMenuSection())
        self.menuBar = menuBar
        microphoneSection.onStatusChanged = { [weak self] status in
            guard let self, status == .authorized, !self.micCapture.isPrepared, !self.preparingCapture else { return }
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
        systemSection.update(remapChecked: remapCoordinator.menuChecked)
        shortcuts.register(.pasteLast) { [weak self] in self?.pasteLast() }
        shortcuts.register(.copyLast) { [weak self] in self?.copyLast() }
        trackStatus()

        refreshGlobeCheck()
        engineHost.start()
        cleanerHost.start()
        offerRecoveryWhenReady()
        Task { await setUpCapture() }

        accessibility.onChange = { [weak self] granted in self?.accessibilityChanged(granted) }
        accessibility.start()
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        guard menuBar != nil else { return }
        refreshGlobeCheck()
        guard !micCapture.isPrepared, !preparingCapture else { return }
        Task {
            refreshMicrophone()
            _ = await prepareCapture()
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
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
        Task.detached {
            do {
                let removed = try archive.purge(olderThan: Date().addingTimeInterval(-AudioArchive.defaultRetention))
                if !removed.isEmpty { try store?.clearAudio(ids: removed) }
                Log.app.info("audio purge removed \(removed.count, privacy: .public) files")
            } catch {
                Log.app.error("audio purge failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func pasteLast() {
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

    private func refreshGlobeCheck() {
        let check = GlobeKeyCheck.current()
        // With the remap on the system never sees the Globe key, so its action can't conflict.
        systemSection.update(globe: remapCoordinator.isActive ? nil : check)
        systemSection.update(remapChecked: remapCoordinator.menuChecked)
        Log.permissions.info("globe key action \(String(describing: check.action), privacy: .public), fn key present \(check.fnKeyPresent, privacy: .public), conflict \(check.hasConflict, privacy: .public)")
    }

    private func refreshMicrophone() {
        microphoneSection.refresh()
        Log.permissions.info("microphone status \(MicrophoneAccess.statusText(for: MicrophoneAccess.status), privacy: .public)")
        refreshStatusIcon()
    }

    private func refreshStatusIcon() {
        guard let menuBar, let dictation else { return }
        var engineFailed = false
        if case .failed = engineHost.state { engineFailed = true }
        if let pinned = StatusIcon.pinned(in: CommandLine.arguments) {
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
        refreshStatusIcon()
        if granted { startInput() }
    }

    private func startInput() {
        guard !inputStarted else { return }
        inputStarted = true
        if let mode = InputProbe.mode(in: CommandLine.arguments) {
            Task { await InputProbe.run(mode, remap: fnRemap) }
            return
        }

        let service = HotkeyService(options: .init(source: remapCoordinator.initialSource()))
        service.onHealthChange = { [weak self] health in
            Log.hotkey.info("health \(health.statusText, privacy: .public)")
            self?.systemSection.update(hotkeyHealth: health)
        }
        do {
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
        guard let dictation else { return }
        hotkeyLogTask = Task { await dictation.consume(service.events) }
    }

    private func toggleRemap() {
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

    private func prepareCapture() async -> Bool {
        preparingCapture = true
        defer { preparingCapture = false }
        do {
            try await micCapture.prepare()
            Log.capture.info("microphone ready")
            return true
        } catch {
            Log.capture.error("capture not prepared: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func setUpCapture() async {
        await MicrophoneAccess.requestIfUndetermined()
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
