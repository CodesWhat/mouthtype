import AppKit
import MouthtypeCore

/// The Cleanup submenu: the level, the state of the local model, one switch per deterministic stage, the tone and the
/// dictionary file. Presets set the two tone switches; changing a switch on its own shows the preset as Custom.
@MainActor
final class CleanupMenuSection: NSObject, MenuSection {
    private let defaults: UserDefaults
    private let cleaner: (any CleanupModelManaging)?
    private let dictionary: FileVocabulary?
    private let confirmDownload: @MainActor (_ name: String, _ sizeMB: Int) -> Bool
    private let manageSpellings: (@MainActor () -> Void)?
    private let spellingsItem = NSMenuItem(title: "Saved Spellings…", action: nil, keyEquivalent: "")
    private let managePhrases: (@MainActor () -> Void)?
    private let phrasesItem = NSMenuItem(title: "Phrase Replacements…", action: nil, keyEquivalent: "")
    private let openFile: @MainActor (URL) -> Void
    private let parent = NSMenuItem(title: "Cleanup", action: nil, keyEquivalent: "")
    private let submenu = NSMenu(title: "Cleanup")
    private var levelItems: [CleanupLevel: NSMenuItem] = [:]
    private let modelStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let fallbackItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let downloadItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let cancelDownloadItem = NSMenuItem(title: "Cancel Download", action: nil, keyEquivalent: "")
    private let learnItem = NSMenuItem(title: "Learn from My Corrections", action: nil, keyEquivalent: "")
    private let editDictionaryItem = NSMenuItem(title: "Edit Dictionary\u{2026}", action: nil, keyEquivalent: "")
    private let dictionaryErrorItem = NSMenuItem(title: "dictionary.json has an error", action: nil, keyEquivalent: "")
    private let fillersItem = NSMenuItem(title: "Remove fillers", action: nil, keyEquivalent: "")
    private let commandsItem = NSMenuItem(title: "Spoken commands and lists", action: nil, keyEquivalent: "")
    private let numbersItem = NSMenuItem(title: "Format numbers", action: nil, keyEquivalent: "")
    private let capitalisationItem = NSMenuItem(title: "Lowercase sentence starts", action: nil, keyEquivalent: "")
    private let endingItem = NSMenuItem(title: "Drop final full stop", action: nil, keyEquivalent: "")
    private let customItem = NSMenuItem(title: "Custom", action: nil, keyEquivalent: "")
    private var presetItems: [StylePreset: NSMenuItem] = [:]

    var items: [NSMenuItem] { [parent] }

    init(
        defaults: UserDefaults = .standard, cleaner: (any CleanupModelManaging)? = nil, dictionary: FileVocabulary? = nil,
        confirmDownload: @escaping @MainActor (_ name: String, _ sizeMB: Int) -> Bool = CleanupMenuSection.askToDownload,
        managePhrases: (@MainActor () -> Void)? = nil, manageSpellings: (@MainActor () -> Void)? = nil,
        openFile: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.defaults = defaults
        self.cleaner = cleaner
        self.dictionary = dictionary
        self.confirmDownload = confirmDownload
        self.openFile = openFile
        self.managePhrases = managePhrases
        self.manageSpellings = manageSpellings
        super.init()
        for (item, action) in [
            (phrasesItem, #selector(editPhrases(_:))), (spellingsItem, #selector(editSpellings(_:))),
            (downloadItem, #selector(download(_:))), (cancelDownloadItem, #selector(cancelDownload(_:))),
            (editDictionaryItem, #selector(editDictionary(_:))), (learnItem, #selector(toggleLearn(_:))), (fillersItem, #selector(toggleFillers(_:))),
            (commandsItem, #selector(toggleCommands(_:))), (numbersItem, #selector(toggleNumbers(_:))),
            (capitalisationItem, #selector(toggleCapitalisation(_:))), (endingItem, #selector(toggleEnding(_:))),
        ] {
            item.action = action
            item.target = self
        }
        let levelHeader = NSMenuItem(title: "Level", action: nil, keyEquivalent: "")
        levelHeader.isEnabled = false
        submenu.addItem(levelHeader)
        for level in CleanupLevel.allCases {
            let item = NSMenuItem(title: level.title, action: #selector(selectLevel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = level.rawValue
            submenu.addItem(item)
            levelItems[level] = item
        }
        for item in [modelStatusItem, fallbackItem, dictionaryErrorItem] { item.isEnabled = false }
        submenu.addItem(modelStatusItem)
        submenu.addItem(fallbackItem)
        submenu.addItem(downloadItem)
        submenu.addItem(cancelDownloadItem)
        submenu.addItem(.separator())
        submenu.addItem(fillersItem)
        submenu.addItem(commandsItem)
        submenu.addItem(numbersItem)
        submenu.addItem(.separator())
        let header = NSMenuItem(title: "Tone", action: nil, keyEquivalent: "")
        header.isEnabled = false
        submenu.addItem(header)
        for preset in StylePreset.allCases {
            let item = NSMenuItem(title: preset.title, action: #selector(selectPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.rawValue
            submenu.addItem(item)
            presetItems[preset] = item
        }
        customItem.isEnabled = false
        submenu.addItem(customItem)
        submenu.addItem(.separator())
        submenu.addItem(capitalisationItem)
        submenu.addItem(endingItem)
        submenu.addItem(.separator())
        submenu.addItem(learnItem)
        submenu.addItem(editDictionaryItem)
        submenu.addItem(spellingsItem)
        spellingsItem.isEnabled = manageSpellings != nil
        submenu.addItem(phrasesItem)
        phrasesItem.isEnabled = managePhrases != nil
        submenu.addItem(dictionaryErrorItem)
        parent.submenu = submenu
        refresh()
        observeModelState()
    }

    /// The state line follows the model while the menu is open (download progress, load finishing).
    private func observeModelState() {
        guard let cleaner else { return }
        withObservationTracking {
            _ = cleaner.state
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshModelItems()
                self?.observeModelState()
            }
        }
    }

    private func refreshModelItems() {
        let level = CleanupSettings.load(defaults).level
        guard let cleaner else {
            for item in [modelStatusItem, fallbackItem, downloadItem, cancelDownloadItem] { item.isHidden = true }
            return
        }
        let name = cleaner.modelName
        var absent = false
        var downloading = false
        var ready = false
        switch cleaner.state {
        case .absent:
            absent = true
            modelStatusItem.title = "\(name): not downloaded"
        case let .downloading(fraction):
            downloading = true
            modelStatusItem.title = "\(name): downloading \(Int((fraction * 100).rounded()))%"
        case .loading:
            modelStatusItem.title = "\(name): loading\u{2026}"
        case .unloaded:
            modelStatusItem.title = "\(name): downloaded, loads when needed"
        case .ready:
            ready = true
            modelStatusItem.title = "\(name): ready"
        case let .failed(message):
            absent = true
            modelStatusItem.title = "\(name): failed (\(message))"
        }
        downloadItem.title = "Download Cleanup Model\u{2026} (\(Self.sizeText(cleaner.downloadSizeMB)))"
        downloadItem.isHidden = !absent
        cancelDownloadItem.isHidden = !downloading
        fallbackItem.title = "Cleanup model isn't ready, so dictations use Basic"
        fallbackItem.isHidden = !(level.needsModel && !ready)
    }

    static func sizeText(_ megabytes: Int) -> String {
        megabytes >= 1000 ? String(format: "%.1f GB", Double(megabytes) / 1000) : "\(megabytes) MB"
    }

    static func askToDownload(name: String, sizeMB: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Download \(name)?"
        alert.informativeText = "It's \(sizeText(sizeMB)), fetched from Hugging Face, and runs on this Mac. "
            + "Only the selected cleanup model is downloaded."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    func refresh() {
        let settings = CleanupSettings.load(defaults)
        for (level, item) in levelItems { item.state = level == settings.level ? .on : .off }
        refreshModelItems()
        dictionary?.reloadIfChanged()
        editDictionaryItem.isHidden = dictionary == nil
        switch dictionary?.status {
        case let .error(message):
            dictionaryErrorItem.title = "dictionary.json has an error: \(message)"
            dictionaryErrorItem.isHidden = false
        default:
            dictionaryErrorItem.isHidden = true
        }
        learnItem.state = CorrectionSettings.isEnabled(defaults) ? .on : .off
        fillersItem.state = settings.fillers ? .on : .off
        commandsItem.state = settings.spokenCommands ? .on : .off
        numbersItem.state = settings.numbers ? .on : .off
        capitalisationItem.state = settings.style.capitalisation == .lowercase ? .on : .off
        endingItem.state = settings.style.endingPunctuation == .dropFinalFullStop ? .on : .off
        let preset = settings.style.preset
        for (candidate, item) in presetItems { item.state = candidate == preset ? .on : .off }
        customItem.state = preset == nil ? .on : .off
        for item in [fillersItem, commandsItem, numbersItem, capitalisationItem, endingItem] + Array(presetItems.values) {
            item.isEnabled = settings.enabled
        }
    }

    private func update(_ change: (inout CleanupSettings) -> Void) {
        var settings = CleanupSettings.load(defaults)
        change(&settings)
        settings.save(to: defaults)
        refresh()
    }

    @objc private func selectLevel(_ sender: NSMenuItem) {
        guard let level = (sender.representedObject as? String).flatMap(CleanupLevel.init(rawValue:)) else { return }
        update { $0.level = level }
        cleaner?.levelChanged()
        refreshModelItems()
    }

    @objc private func download(_ sender: NSMenuItem) {
        guard let target = cleaner?.downloadTarget, confirmDownload(target.modelName, target.downloadSizeMB) else { return }
        target.startDownload()
        refreshModelItems()
    }

    @objc private func cancelDownload(_ sender: NSMenuItem) {
        cleaner?.cancelDownload()
    }

    @objc private func editSpellings(_ sender: NSMenuItem) { manageSpellings?() }

    @objc private func editPhrases(_ sender: NSMenuItem) { managePhrases?() }

    @objc private func editDictionary(_ sender: NSMenuItem) {
        guard let dictionary else { return }
        do {
            openFile(try dictionary.createIfMissing())
        } catch {
            Log.app.error("dictionary file not created: \(String(describing: error), privacy: .public)")
        }
        refresh()
    }
    @objc private func toggleLearn(_ sender: NSMenuItem) {
        CorrectionSettings.set(!CorrectionSettings.isEnabled(defaults), in: defaults)
        refresh()
    }

    @objc private func toggleFillers(_ sender: NSMenuItem) { update { $0.fillers.toggle() } }
    @objc private func toggleCommands(_ sender: NSMenuItem) { update { $0.spokenCommands.toggle() } }
    @objc private func toggleNumbers(_ sender: NSMenuItem) { update { $0.numbers.toggle() } }

    @objc private func toggleCapitalisation(_ sender: NSMenuItem) {
        update { $0.style.capitalisation = $0.style.capitalisation == .lowercase ? .sentence : .lowercase }
    }

    @objc private func toggleEnding(_ sender: NSMenuItem) {
        update { $0.style.endingPunctuation = $0.style.endingPunctuation == .keep ? .dropFinalFullStop : .keep }
    }

    @objc private func selectPreset(_ sender: NSMenuItem) {
        guard let preset = (sender.representedObject as? String).flatMap(StylePreset.init(rawValue:)) else { return }
        update { $0.style = preset.options }
    }
}
