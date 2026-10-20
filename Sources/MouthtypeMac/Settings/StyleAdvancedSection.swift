import SwiftUI
import MouthtypeCore

/// The writing switches the redesign moves to Settings > Advanced. Until that page takes them they stay here, so every one is still
/// reachable. The settings agent moves them and the integrator removes this section.
struct StyleAdvancedSection: View {
    @Bindable var model: SettingsModel
    var actions: SettingsActions

    /// Fillers, spoken commands, numbers and tone still apply to a take a rule turns cleanup on for, so they stay editable while the
    /// global level is Off.
    private var enabled: Bool { model.cleanup.enabled || model.appStyles.enablesCleanup }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            DesignSection(eyebrow: "Writing options · moving to Settings > Advanced",
                footer: enabled ? "These adjust how cleanup writes. Your saved spellings and phrases are on the Dictionary and Transforms pages."
                    : "Cleanup is Off. Your dictation keeps its original wording and style; these options apply when cleanup is enabled.") {
                toggle("Remove fillers", isOn: Binding(get: { model.cleanup.fillers }, set: model.setFillers)).disabled(!enabled)
                toggle("Spoken commands and lists", isOn: Binding(get: { model.cleanup.spokenCommands }, set: model.setSpokenCommands)).disabled(!enabled)
                toggle("Format numbers", isOn: Binding(get: { model.cleanup.numbers }, set: model.setNumbers)).disabled(!enabled)
                toggle("Lowercase sentence starts", detail: "Part of the Very casual tone. Setting it alone makes your default tone Custom.",
                       isOn: Binding(get: { model.cleanup.style.capitalisation == .lowercase }, set: model.setLowercaseStarts)).disabled(!enabled)
                toggle("Drop the final full stop", detail: "Part of the Casual and Very casual tones. Setting it alone makes your default tone Custom.",
                       isOn: Binding(get: { model.cleanup.style.endingPunctuation == .dropFinalFullStop }, set: model.setDropFinalStop)).disabled(!enabled)
                toggle("Learn from my corrections", isOn: Binding(get: { model.learnCorrections }, set: model.setLearnCorrections))
                toggle("Boost my saved words while recognising", detail: boostDetail,
                       isOn: Binding(get: { model.boostSavedWords }, set: model.setBoostSavedWords))
                DesignRow(title: "Dictionary file", detail: actions.diagnostics?.dictionaryError) {
                    Button("Edit dictionary file…", action: actions.editDictionary).buttonStyle(.designSecondary)
                }
            }
            DesignSection(eyebrow: "Delivery · moving to Settings > Advanced",
                          footer: "Split long pastes only in the terminal apps you choose. Off by default. Applies to that terminal app’s windows. Mouthtype can’t identify the program running inside it.") {
                ForEach(PasteSettings.supportedTerminals, id: \.bundleID) { terminal in
                    toggle(terminal.name, isOn: Binding(get: { model.chunkedTerminals.contains(terminal.bundleID) },
                                                        set: { model.setChunks($0, bundleID: terminal.bundleID) }))
                }
            }
        }
    }

    private func toggle(_ title: String, detail: String? = nil, isOn: Binding<Bool>) -> some View {
        DesignRow(title: title, detail: detail) {
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.designSwitch)
        }
    }

    private var boostDetail: String {
        var text = "Favours your saved spellings while recognising. The first time, it downloads an extra speech model of about 100 MB. Dictation works without it until it is ready."
        let status = model.boostStatus.text
        if model.boostSavedWords, !status.isEmpty { text += " " + status + "." }
        return text
    }
}
