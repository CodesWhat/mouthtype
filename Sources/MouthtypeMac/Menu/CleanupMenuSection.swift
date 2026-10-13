import AppKit
import MouthtypeCore

/// The Cleanup submenu: the master switch, one switch per deterministic stage, and the tone. Presets set the two
/// tone switches; changing a switch on its own shows the preset as Custom.
@MainActor
final class CleanupMenuSection: NSObject, MenuSection {
    private let defaults: UserDefaults
    private let parent = NSMenuItem(title: "Cleanup", action: nil, keyEquivalent: "")
    private let submenu = NSMenu(title: "Cleanup")
    private let masterItem = NSMenuItem(title: "Clean up dictation", action: nil, keyEquivalent: "")
    private let fillersItem = NSMenuItem(title: "Remove fillers", action: nil, keyEquivalent: "")
    private let commandsItem = NSMenuItem(title: "Spoken commands and lists", action: nil, keyEquivalent: "")
    private let numbersItem = NSMenuItem(title: "Format numbers", action: nil, keyEquivalent: "")
    private let capitalisationItem = NSMenuItem(title: "Lowercase sentence starts", action: nil, keyEquivalent: "")
    private let endingItem = NSMenuItem(title: "Drop final full stop", action: nil, keyEquivalent: "")
    private let customItem = NSMenuItem(title: "Custom", action: nil, keyEquivalent: "")
    private var presetItems: [StylePreset: NSMenuItem] = [:]

    var items: [NSMenuItem] { [parent] }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        for (item, action) in [
            (masterItem, #selector(toggleMaster(_:))), (fillersItem, #selector(toggleFillers(_:))),
            (commandsItem, #selector(toggleCommands(_:))), (numbersItem, #selector(toggleNumbers(_:))),
            (capitalisationItem, #selector(toggleCapitalisation(_:))), (endingItem, #selector(toggleEnding(_:))),
        ] {
            item.action = action
            item.target = self
        }
        submenu.addItem(masterItem)
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
        parent.submenu = submenu
        refresh()
    }

    func refresh() {
        let settings = CleanupSettings.load(defaults)
        masterItem.state = settings.enabled ? .on : .off
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

    @objc private func toggleMaster(_ sender: NSMenuItem) { update { $0.enabled.toggle() } }
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
