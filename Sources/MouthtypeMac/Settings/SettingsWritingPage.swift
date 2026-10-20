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
        }.disabled(!sharedControlsEnabled)
        appStyles
        websiteStyles
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
        }.disabled(!sharedControlsEnabled)
        SettingsGroup(eyebrow: "ADVANCED WRITING",
            footer: sharedControlsEnabled
                ? "More formal doesn’t mean different words. Your saved spellings and phrases are available from the sidebar."
                : "Cleanup is Off. Your dictation keeps its original wording and style; these options apply when cleanup is enabled.") {
            SettingsRow(title: "Learn from my corrections") {
                Toggle("Learn from my corrections", isOn: Binding(get: { model.learnCorrections }, set: model.setLearnCorrections)).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(title: "Boost my saved words while recognising", detail: boostDetail) {
                Toggle("Boost my saved words while recognising", isOn: Binding(get: { model.boostSavedWords }, set: model.setBoostSavedWords)).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(title: "Code names from your editor", detail: "While you dictate in VS Code, Cursor, Xcode or a terminal, favour file, folder and function names from the window you're in. Needs the boost above. Nothing is stored.") {
                Toggle("Code names from your editor", isOn: Binding(get: { model.editorHints }, set: model.setEditorHints)).labelsHidden().toggleStyle(.switch)
                    .accessibilityIdentifier("settings-editor-hints")
            }
            SettingsRow(title: "Lowercase sentence starts") {
                Toggle("Lowercase sentence starts", isOn: Binding(get: { model.cleanup.style.capitalisation == .lowercase }, set: model.setLowercaseStarts))
                    .labelsHidden().toggleStyle(.switch).disabled(!sharedControlsEnabled)
            }
            SettingsRow(title: "Drop final full stop", detail: "These tone details may show Custom as your default tone.") {
                Toggle("Drop final full stop", isOn: Binding(get: { model.cleanup.style.endingPunctuation == .dropFinalFullStop }, set: model.setDropFinalStop))
                    .labelsHidden().toggleStyle(.switch).disabled(!sharedControlsEnabled)
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

    /// Fillers, spoken commands, numbers and tone still apply to a take a rule turns cleanup on for, so they stay
    /// editable while the global level is Off.
    private var sharedControlsEnabled: Bool { model.cleanup.enabled || model.appStyles.enablesCleanup }

    private var boostDetail: String {
        var text = "Favours your saved spellings while recognising. The first time, it downloads an extra speech model of about 100 MB. Dictation works without it until it is ready."
        let status = model.boostStatus.text
        if model.boostSavedWords, !status.isEmpty { text += " " + status + "." }
        return text
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

    private func toneTag(_ style: StyleOptions?) -> String { style.map { $0.preset?.rawValue ?? "custom" } ?? "default" }

    private func levelPicker(_ label: String, level: CleanupLevel?, set: @escaping (CleanupLevel?) -> Void) -> some View {
        Picker(label, selection: Binding(get: { level?.rawValue ?? "default" }, set: { set(CleanupLevel(rawValue: $0)) })) {
            Text("Cleanup: Use default").tag("default")
            ForEach(CleanupLevel.allCases, id: \.rawValue) { Text("Cleanup: \($0.title)").tag($0.rawValue) }
        }.labelsHidden().fixedSize()
    }

    private var appStyles: some View {
        SettingsGroup(eyebrow: "APP RULES") {
            SettingsRow(title: "Add application",
                detail: "Apps without a rule use your default tone and cleanup level. A rule can set tone, cleanup or both, and applies to the app where you start dictating. A rule can turn cleanup on for one app even when your default is Off.") {
                Button("Add application…") { model.chooseApplication() }.disabled(model.appStylesError != nil)
            }
            if model.appStylesError != nil {
                storeErrorRow
            } else if model.appStyles.entries.isEmpty {
                SettingsNote(text: "Every app uses your default tone and cleanup level.")
            }
            ForEach(model.appStyles.entries, id: \.bundleID) { entry in
                SettingsRow(title: entry.appName, detail: entry.bundleID) {
                    Picker("Tone for \(entry.appName)", selection: Binding(get: { toneTag(entry.style) }, set: { value in
                        if value == "default" { model.setAppStyle(bundleID: entry.bundleID, appName: entry.appName, tone: nil) }
                        else if let tone = StylePreset(rawValue: value) { model.setAppStyle(bundleID: entry.bundleID, appName: entry.appName,
                                                                                            tone: tone) }
                    })) {
                        Text("Use default").tag("default")
                        ForEach(StylePreset.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                        if let style = entry.style, style.preset == nil { Text("Custom").tag("custom") }
                    }.labelsHidden().fixedSize()
                    levelPicker("Cleanup for \(entry.appName)", level: entry.level) {
                        model.setAppCleanupLevel(bundleID: entry.bundleID, appName: entry.appName, level: $0)
                    }
                    Button { model.removeAppStyle(bundleID: entry.bundleID) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).accessibilityLabel("Remove rule for \(entry.appName)")
                }.disabled(model.appStylesError != nil)
            }
        }
    }

    private var websiteStyles: some View {
        SettingsGroup(eyebrow: "WEBSITE RULES") {
            SettingsNote(text: "Website rules override app rules, including subdomains, and can set tone, cleanup or both. Anything a website rule leaves on Use default falls back to the app rule, then your default. Safari, Chrome, Edge and Brave use the focused window’s document URL when available. Otherwise the app rule applies. These rules don’t retain document URLs.")
            if model.appStylesError != nil { storeErrorRow }
            HStack {
                TextField("Domain, e.g. slack.com", text: $model.websiteDomain).accessibilityIdentifier("settings-website-domain")
                Picker("Website tone", selection: Binding(get: { model.websiteTone?.rawValue ?? "default" },
                                                          set: { model.websiteTone = StylePreset(rawValue: $0) })) {
                    Text("Use default").tag("default")
                    ForEach(StylePreset.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }.labelsHidden().fixedSize()
                levelPicker("Website cleanup", level: model.websiteLevel) { model.websiteLevel = $0 }
                Button("Add") {
                    model.addWebsiteRule(domain: model.websiteDomain, tone: model.websiteTone, level: model.websiteLevel)
                    if model.appStylesError == nil { model.websiteDomain = "" }
                }.disabled(model.websiteDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                           || (model.websiteTone == nil && model.websiteLevel == nil))
            }.frame(minHeight: SettingsTheme.rowMinHeight - 14)
            ForEach(model.appStyles.websites, id: \.domain) { entry in
                SettingsRow(title: entry.domain) {
                    Picker("Tone for \(entry.domain)", selection: Binding(get: { toneTag(entry.style) }, set: { value in
                        if value == "default" { model.setWebsiteStyle(domain: entry.domain, tone: nil) }
                        else if let tone = StylePreset(rawValue: value) { model.setWebsiteStyle(domain: entry.domain, tone: tone) }
                    })) {
                        Text("Use default").tag("default")
                        ForEach(StylePreset.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                        if let style = entry.style, style.preset == nil { Text("Custom").tag("custom") }
                    }.labelsHidden().fixedSize()
                    levelPicker("Cleanup for \(entry.domain)", level: entry.level) {
                        model.setWebsiteCleanupLevel(domain: entry.domain, level: $0)
                    }
                    Button { model.removeWebsiteStyle(domain: entry.domain) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).accessibilityLabel("Remove website rule for \(entry.domain)")
                }.disabled(model.appStylesError != nil)
            }
        }
    }
}
