import SwiftUI
import MouthtypeCore

extension SettingsView {
    @ViewBuilder var writing: some View {
        SettingsGroup(eyebrow: "DEFAULT TONE") {
            SettingsRow(title: "Default tone", detail: toneSummary) {
                Picker("Default tone", selection: Binding(get: { model.cleanup.style.preset?.rawValue ?? "custom" }, set: { if let tone = StylePreset(rawValue: $0) { model.setTone(tone) } })) {
                    ForEach(StylePreset.allCases, id: \.rawValue) { tone in Text(tone.title).tag(tone.rawValue) }
                    if model.cleanup.style.preset == nil { Text("Custom").tag("custom") }
                }.pickerStyle(.radioGroup).horizontalRadioGroupLayout().labelsHidden().fixedSize()
                    .accessibilityIdentifier("settings-default-tone")
            }
        }.disabled(!model.cleanup.enabled)
        appStyles.disabled(!model.cleanup.enabled)
        websiteStyles.disabled(!model.cleanup.enabled)
        SettingsGroup(eyebrow: "CLEANUP DETAILS") {
            SettingsRow(title: "Remove fillers") {
                Toggle("Remove fillers", isOn: Binding(get: { model.cleanup.fillers }, set: model.setFillers)).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(title: "Spoken commands and lists") {
                Toggle("Spoken commands and lists", isOn: Binding(get: { model.cleanup.spokenCommands }, set: model.setSpokenCommands)).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(title: "Format numbers") {
                Toggle("Format numbers", isOn: Binding(get: { model.cleanup.numbers }, set: model.setNumbers)).labelsHidden().toggleStyle(.switch)
            }
        }.disabled(!model.cleanup.enabled)
        SettingsGroup(eyebrow: "ADVANCED WRITING",
            footer: model.cleanup.enabled
                ? "More formal doesn’t mean different words. Your saved spellings and phrases are available from the sidebar."
                : "Cleanup is Off. Your dictation keeps its original wording and style; these options apply when cleanup is enabled.") {
            SettingsRow(title: "Learn from my corrections") {
                Toggle("Learn from my corrections", isOn: Binding(get: { model.learnCorrections }, set: model.setLearnCorrections)).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(title: "Boost my saved words while recognising", detail: "Gives the speech model your saved spellings as a hint. Only Whisper engines use it; the default Parakeet engine ignores it.") {
                Toggle("Boost my saved words while recognising", isOn: Binding(get: { model.boostSavedWords }, set: model.setBoostSavedWords)).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(title: "Lowercase sentence starts") {
                Toggle("Lowercase sentence starts", isOn: Binding(get: { model.cleanup.style.capitalisation == .lowercase }, set: model.setLowercaseStarts))
                    .labelsHidden().toggleStyle(.switch).disabled(!model.cleanup.enabled)
            }
            SettingsRow(title: "Drop final full stop", detail: "These tone details may show Custom as your default tone.") {
                Toggle("Drop final full stop", isOn: Binding(get: { model.cleanup.style.endingPunctuation == .dropFinalFullStop }, set: model.setDropFinalStop))
                    .labelsHidden().toggleStyle(.switch).disabled(!model.cleanup.enabled)
            }
            SettingsRow(title: "Dictionary file", detail: actions.diagnostics?.dictionaryError) {
                Button("Edit dictionary file…", action: actions.editDictionary)
            }
        }
        SettingsGroup(eyebrow: "DELIVERY") {
            SettingsNote(text: "Advanced delivery. Split long pastes only in the terminal apps you choose. Off by default.")
            ForEach(PasteSettings.supportedTerminals, id: \.bundleID) { terminal in
                SettingsRow(title: terminal.name) {
                    Toggle(terminal.name, isOn: Binding(get: { model.chunkedTerminals.contains(terminal.bundleID) }, set: { model.setChunks($0, bundleID: terminal.bundleID) }))
                        .labelsHidden().toggleStyle(.switch)
                }
            }
            SettingsNote(text: "Applies to that terminal app’s windows. Mouthtype can’t identify the program running inside it.")
        }
    }

    private var toneSummary: String {
        var parts: [String] = []
        if let tone = model.cleanup.style.preset { parts.append(toneDetail(tone)) }
        else { parts.append("Custom tone is active. Choose a preset to replace it.") }
        parts.append("Tone adjusts capitalization and ending punctuation. It keeps your wording.")
        return parts.joined(separator: " ")
    }

    private func toneDetail(_ tone: StylePreset) -> String {
        switch tone { case .formal: "Sentence case. Keep punctuation."; case .casual: "Sentence case. A lighter ending."; case .veryCasual: "Lowercase starts. A lighter ending." }
    }

    private var storeErrorRow: some View {
        SettingsRow(title: model.appStylesError ?? "") {
            Button("Reload") { model.refresh() }
        }.foregroundStyle(.red)
    }

    private var appStyles: some View {
        SettingsGroup(eyebrow: "APP STYLES") {
            SettingsRow(title: "Add application",
                detail: "Apps without a rule use your default tone. A rule applies to the app where you start dictating.") {
                Button("Add application…") { model.chooseApplication() }.disabled(model.appStylesError != nil)
            }
            if model.appStylesError != nil {
                storeErrorRow
            } else if model.appStyles.entries.isEmpty {
                SettingsNote(text: "Every app uses your default tone.")
            }
            ForEach(model.appStyles.entries, id: \.bundleID) { entry in
                SettingsRow(title: entry.appName, detail: entry.bundleID) {
                    Picker("Tone for \(entry.appName)", selection: Binding(get: { entry.style.preset?.rawValue ?? "custom" }, set: { value in
                        if value == "default" { model.removeAppStyle(bundleID: entry.bundleID) }
                        else if let tone = StylePreset(rawValue: value) { model.setAppStyle(bundleID: entry.bundleID, appName: entry.appName, tone: tone) }
                    })) {
                        Text("Use default").tag("default")
                        ForEach(StylePreset.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                        if entry.style.preset == nil { Text("Custom").tag("custom") }
                    }.labelsHidden().fixedSize()
                    Button { model.removeAppStyle(bundleID: entry.bundleID) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).accessibilityLabel("Remove style for \(entry.appName)")
                }.disabled(model.appStylesError != nil)
            }
        }
    }

    private var websiteStyles: some View {
        SettingsGroup(eyebrow: "WEBSITE TONE") {
            SettingsNote(text: "Website rules override app tone, including subdomains. Safari, Chrome, Edge and Brave use the focused window’s document URL when available. Otherwise app tone applies. These rules don’t retain document URLs.")
            if model.appStylesError != nil { storeErrorRow }
            HStack {
                TextField("Domain, e.g. slack.com", text: $model.websiteDomain).accessibilityIdentifier("settings-website-domain")
                Picker("Website tone", selection: $model.websiteTone) {
                    ForEach(StylePreset.allCases, id: \.rawValue) { Text($0.title).tag($0) }
                }.labelsHidden().fixedSize()
                Button("Add") {
                    model.setWebsiteStyle(domain: model.websiteDomain, tone: model.websiteTone)
                    if model.appStylesError == nil { model.websiteDomain = "" }
                }.disabled(model.websiteDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.frame(minHeight: SettingsTheme.rowMinHeight - 14)
            ForEach(model.appStyles.websites, id: \.domain) { entry in
                SettingsRow(title: entry.domain) {
                    Picker("Tone for \(entry.domain)", selection: Binding(get: { entry.style.preset?.rawValue ?? "custom" }, set: { value in
                        if let tone = StylePreset(rawValue: value) { model.setWebsiteStyle(domain: entry.domain, tone: tone) }
                    })) {
                        ForEach(StylePreset.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                        if entry.style.preset == nil { Text("Custom").tag("custom") }
                    }.labelsHidden().fixedSize()
                    Button { model.removeWebsiteStyle(domain: entry.domain) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).accessibilityLabel("Remove website tone for \(entry.domain)")
                }.disabled(model.appStylesError != nil)
            }
        }
    }
}
