import AppKit
import SwiftUI
import MouthtypeCore

@MainActor final class SettingsWindow: NSWindowController, NSWindowDelegate {
    let model: SettingsModel
    private let refreshDiagnostics: () -> Void

    init(model: SettingsModel, actions: SettingsActions = SettingsActions()) {
        self.model = model
        refreshDiagnostics = actions.refreshDiagnostics
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 690),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Mouthtype Settings"
        window.minSize = NSSize(width: 860, height: 620)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(model: model, actions: actions))
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func present(page: SettingsPage? = nil) {
        if let page { model.page = page }
        refreshDiagnostics()
        model.refresh()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) { refreshDiagnostics(); model.refresh() }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, writing, appearance, diagnostics
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self { case .general: "slider.horizontal.3"; case .writing: "textformat"; case .appearance: "paintpalette"; case .diagnostics: "stethoscope" }
    }
}

@MainActor struct SettingsActions {
    var openSetup: () -> Void = {}
    var changeShortcut: () -> Void = {}
    var openSpellings: () -> Void = {}
    var openPhrases: () -> Void = {}
    var cleaner: (any CleanupModelManaging)?
    var diagnostics: SettingsDiagnostics?
    var retrySpeech: () -> Void = {}
    var refreshDiagnostics: () -> Void = {}
    var toggleRemap: () -> Void = {}
    var openMicSettings: () -> Void = {}
    var openAccessibilitySettings: () -> Void = {}
    var openKeyboardSettings: () -> Void = {}
    var editDictionary: () -> Void = {}
    var editPhrasesFile: () -> Void = {}
    var chooseFont: () -> Void = {}
    var updater: AppUpdater?
}

struct SettingsView: View {
    @Bindable var model: SettingsModel
    var actions = SettingsActions()

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 192)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    switch model.page {
                    case .general: general
                    case .writing: writing
                    case .appearance: appearance
                    case .diagnostics:
                        if let diagnostics = actions.diagnostics { SettingsDiagnosticsView(state: diagnostics, model: model, actions: actions) }
                        else { Text("Diagnostic status is unavailable.") }
                    }
                    Spacer(minLength: 8)
                }.padding(34).frame(maxWidth: .infinity, alignment: .topLeading)
            }.background(Color(nsColor: .textBackgroundColor))
        }
        .font(.custom("InstrumentSans-Regular", size: 13))
        .foregroundStyle(.primary)
        .frame(minWidth: 860, minHeight: 590)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in model.refresh() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let url = Bundle.module.url(forResource: "mouthtype", withExtension: "png", subdirectory: "Settings"),
                   let mark = NSImage(contentsOf: url) {
                    Image(nsImage: mark).resizable().interpolation(.none).frame(width: 32, height: 32).accessibilityHidden(true)
                }
                Text("mouthtype").font(.custom("InstrumentSerif-Regular", size: 27))
            }.padding(.horizontal, 18).padding(.top, 23).padding(.bottom, 31)
            Text("MAKE YOURSELF AT HOME").font(.custom("JetBrainsMono-Medium", size: 8))
                .foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 12)
            List(selection: Binding<SettingsPage?>(get: { model.page }, set: { if let value = $0 { model.page = value } })) {
                ForEach(SettingsPage.allCases) { page in Label(page.title, systemImage: page.icon).tag(page).padding(.vertical, 5) }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
            Divider().padding(.horizontal, 18)
            VStack(alignment: .leading, spacing: 16) {
                Button(action: actions.openSpellings) { Label("Saved spellings…", systemImage: "character.book.closed") }
                    .accessibilityIdentifier("settings-spellings")
                Button(action: actions.openPhrases) { Label("Phrases…", systemImage: "text.badge.plus") }
                    .accessibilityIdentifier("settings-phrases")
            }.buttonStyle(.plain).padding(20)
            Spacer()
            Text("ON YOUR MAC")
                .font(.custom("JetBrainsMono-Medium", size: 9)).lineSpacing(7).foregroundStyle(.secondary).padding(20)
        }.background(Color(nsColor: .windowBackgroundColor))
    }

    private func heading(_ eyebrow: String, _ title: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(eyebrow.uppercased()).font(.custom("JetBrainsMono-Medium", size: 9)).foregroundStyle(.secondary)
            Text(title).font(.custom("InstrumentSerif-Regular", size: 38))
            Text(description).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).lineSpacing(3)
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 25) {
            heading("General", "A little less typing.", "Set your shortcut, choose your cleanup, and carry on.")
            Button("Set Up Mouthtype…", action: actions.openSetup).accessibilityIdentifier("settings-setup")
            VStack(spacing: 0) {
                settingRow("Dictation shortcut", "A key or combination that feels natural.") {
                    Text(model.shortcut).font(.system(.body, design: .monospaced)).padding(8)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                    Button("Change…", action: actions.changeShortcut).accessibilityIdentifier("settings-shortcut")
                }
                Divider()
                settingRow("Recording behavior", "Changing this cancels an active recording.") {
                    Picker("Recording behavior", selection: Binding(get: { model.recordingMode.rawValue }, set: { if let mode = RecordingMode(rawValue: $0) { model.setRecordingMode(mode) } })) {
                        Text("Hold to talk").tag(RecordingMode.hold.rawValue)
                        Text("Press to toggle").tag(RecordingMode.toggle.rawValue)
                    }.labelsHidden().frame(width: 165).accessibilityIdentifier("settings-recording-mode")
                }
                if let error = model.recordingModeError {
                    Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 17)
                }
                Divider()
                settingRow("Cleanup", "Fast and Thorough run locally on your Mac.") {
                    Picker("Cleanup", selection: Binding(get: { model.cleanup.level.rawValue }, set: { if let level = CleanupLevel(rawValue: $0) { model.setLevel(level) } })) {
                        ForEach(CleanupLevel.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }.labelsHidden().frame(width: 135)
                }
                cleanerStatus
                Divider()
                LivePreviewSettingsRow(model: model)
                Divider()
                settingRow("Recording sounds", "A small cue when you start and finish.") {
                    Toggle("Recording sounds", isOn: Binding(get: { model.sounds }, set: model.setSounds)).labelsHidden().toggleStyle(.switch)
                }
                Divider()
                settingRow("Launch at login", model.loginState == .mixed ? "Waiting for approval in System Settings." : "Keep Mouthtype ready in your menu bar.") {
                    Button(model.loginState == .mixed ? "Open Login Items…" : model.loginState == .on ? "Turn off" : "Turn on") { model.toggleLogin() }
                }
            }
            if let updater = actions.updater {
                VStack(alignment: .leading, spacing: 13) {
                    Divider()
                    settingRow("Updates", updater.statusText) {
                        Button(updater.hasUpdate ? "Review Update…" : "Check for Updates…") { updater.checkForUpdates() }.disabled(!updater.canCheckForUpdates)
                    }
                    Toggle("Automatically check for updates", isOn: Binding(get: { updater.automaticallyChecksForUpdates }, set: updater.setAutomaticChecks))
                        .disabled(!updater.isAvailable)
                }
            }
            DisclosureGroup("Advanced delivery") {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Split long pastes only in the terminal apps you choose. Off by default.").font(.callout).foregroundStyle(.secondary)
                    ForEach(PasteSettings.supportedTerminals, id: \.bundleID) { terminal in
                        Toggle(terminal.name, isOn: Binding(get: { model.chunkedTerminals.contains(terminal.bundleID) }, set: { model.setChunks($0, bundleID: terminal.bundleID) }))
                    }
                    Text("Applies to that terminal app’s windows. Mouthtype can’t identify the program running inside it.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 12)
            }
            callout(model.recordingInstructions)
        }
    }

    @ViewBuilder private var cleanerStatus: some View {
        if let cleaner = actions.cleaner {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(modelStatus(cleaner)).font(.callout).foregroundStyle(.secondary)
                    if model.cleanup.level.needsModel, !isReady(cleaner) {
                        Text("Dictations use Basic until the selected model is ready.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                switch cleaner.state {
                case .absent, .failed:
                    Button("Download…") {
                        let target = cleaner.downloadTarget
                        if CleanupMenuSection.askToDownload(name: target.modelName, sizeMB: target.downloadSizeMB) { target.startDownload() }
                    }
                case .downloading: Button("Cancel") { cleaner.cancelDownload() }
                default: EmptyView()
                }
            }.padding(.bottom, 17)
        }
    }

    private func isReady(_ cleaner: any CleanupModelManaging) -> Bool { if case .ready = cleaner.state { true } else { false } }
    private func modelStatus(_ cleaner: any CleanupModelManaging) -> String {
        let name = cleaner.modelName
        switch cleaner.state {
        case .absent: return "\(name) is not downloaded."
        case .downloading(let fraction): return "\(name) downloading: \(Int(fraction * 100))%."
        case .loading: return "\(name) is loading…"
        case .unloaded: return "\(name) is downloaded and loads when needed."
        case .ready: return "\(name) is ready."
        case .failed(let message): return "\(name): \(message)"
        }
    }

    private var writing: some View {
        VStack(alignment: .leading, spacing: 26) {
            heading("Writing / Cleanup & tone", "Your words. Your way.", "A finish that feels right, without changing what you mean.")
            VStack(alignment: .leading, spacing: 13) {
                Text("Default tone").font(.headline)
                Picker("Default tone", selection: Binding(get: { model.cleanup.style.preset?.rawValue ?? "custom" }, set: { if let tone = StylePreset(rawValue: $0) { model.setTone(tone) } })) {
                    ForEach(StylePreset.allCases, id: \.rawValue) { tone in Text(tone.title).tag(tone.rawValue) }
                    if model.cleanup.style.preset == nil { Text("Custom").tag("custom") }
                }.pickerStyle(.radioGroup).horizontalRadioGroupLayout().labelsHidden().disabled(!model.cleanup.enabled)
                if let tone = model.cleanup.style.preset { Text(toneDetail(tone)).font(.callout).foregroundStyle(.secondary) }
                if model.cleanup.style.preset == nil { Text("Custom tone is active. Choose a preset to replace it.").font(.callout).foregroundStyle(.secondary) }
                Text("Tone adjusts capitalization and ending punctuation. It keeps your wording.").font(.callout).foregroundStyle(.secondary)
            }
            appStyles
            Divider()
            VStack(alignment: .leading, spacing: 17) {
                Text("Cleanup details").font(.headline)
                Toggle("Remove fillers", isOn: Binding(get: { model.cleanup.fillers }, set: model.setFillers))
                Toggle("Spoken commands and lists", isOn: Binding(get: { model.cleanup.spokenCommands }, set: model.setSpokenCommands))
                Toggle("Format numbers", isOn: Binding(get: { model.cleanup.numbers }, set: model.setNumbers))
            }.disabled(!model.cleanup.enabled)
            DisclosureGroup("Advanced writing") {
                VStack(alignment: .leading, spacing: 15) {
                    Toggle("Learn from my corrections", isOn: Binding(get: { model.learnCorrections }, set: model.setLearnCorrections))
                    Toggle("Lowercase sentence starts", isOn: Binding(get: { model.cleanup.style.capitalisation == .lowercase }, set: model.setLowercaseStarts)).disabled(!model.cleanup.enabled)
                    Toggle("Drop final full stop", isOn: Binding(get: { model.cleanup.style.endingPunctuation == .dropFinalFullStop }, set: model.setDropFinalStop)).disabled(!model.cleanup.enabled)
                    Text("These tone details may show Custom as your default tone.").font(.callout).foregroundStyle(.secondary)
                    Button("Edit dictionary file…", action: actions.editDictionary)
                    if let error = actions.diagnostics?.dictionaryError { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                }.padding(.top, 12)
            }
            callout(model.cleanup.enabled ? "More formal doesn’t mean different words. Your saved spellings and phrases are available from the sidebar." : "Cleanup is Off. Your dictation keeps its original wording and style; these options apply when cleanup is enabled.")
        }
    }

    private var appStyles: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("App styles").font(.headline)
                Spacer()
                Button("Add application…") { model.chooseApplication() }.disabled(model.appStylesError != nil)
            }
            Text("Apps without a rule use your default tone. A rule applies to the app where you start dictating.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = model.appStylesError {
                HStack {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                    Spacer()
                    Button("Reload") { model.refresh() }
                }.font(.callout)
            } else if model.appStyles.entries.isEmpty {
                Text("Every app uses your default tone.").foregroundStyle(.secondary).padding(.vertical, 8)
            }
            ForEach(model.appStyles.entries, id: \.bundleID) { entry in
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.appName).fontWeight(.medium)
                        Text(entry.bundleID).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Tone for \(entry.appName)", selection: Binding(get: { entry.style.preset?.rawValue ?? "custom" }, set: { value in
                        if value == "default" { model.removeAppStyle(bundleID: entry.bundleID) }
                        else if let tone = StylePreset(rawValue: value) { model.setAppStyle(bundleID: entry.bundleID, appName: entry.appName, tone: tone) }
                    })) {
                        Text("Use default").tag("default")
                        ForEach(StylePreset.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                        if entry.style.preset == nil { Text("Custom").tag("custom") }
                    }.labelsHidden().frame(width: 140)
                    Button { model.removeAppStyle(bundleID: entry.bundleID) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).accessibilityLabel("Remove style for \(entry.appName)")
                }.padding(.vertical, 5).disabled(model.appStylesError != nil)
            }
        }.disabled(!model.cleanup.enabled)
    }

    private func toneDetail(_ tone: StylePreset) -> String {
        switch tone { case .formal: "Sentence case. Keep punctuation."; case .casual: "Sentence case. A lighter ending."; case .veryCasual: "Lowercase starts. A lighter ending." }
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 25) {
            heading("Appearance / Floating pill", "Clean by default. Personal by choice.", "The same Mouthtype underneath. A different little machine when you want one.")
            VStack(spacing: 17) {
                if let image = SettingsPillImage.make(skin: model.skin, size: model.hiFiSize) {
                    Image(nsImage: image).interpolation(.none).accessibilityLabel("\(model.skin.title) floating pill preview")
                        .frame(height: 95)
                }
                Text("\(model.skin.title) · floating pill").font(.custom("JetBrainsMono-Medium", size: 10)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(22).background(Color(nsColor: .controlBackgroundColor))
            Picker("Pill style", selection: Binding(get: { model.skin.rawValue }, set: { if let skin = PillSkinKind(rawValue: $0) { model.setSkin(skin) } })) {
                ForEach(PillSkinKind.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }.pickerStyle(.segmented)
            if model.skin == .hifi {
                settingRow("Hi-Fi size", "Applies the next time the pill appears.") {
                    Picker("Hi-Fi size", selection: Binding(get: { model.hiFiSize.rawValue }, set: { if let size = HiFiPillSize(rawValue: $0) { model.setHiFiSize(size) } })) {
                        ForEach(HiFiPillSize.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }.labelsHidden().frame(width: 150)
                }
            }
            settingRow(model.fontOverrides.enabled ? "Base text font" : "Text font", "Used by the Classic pill and delivery cards.") {
                Picker("Text font", selection: Binding(get: { model.font.title }, set: { name in if let font = TextFontChoice.standard.first(where: { $0.title == name }) { model.setFont(font) } })) {
                    ForEach(TextFontChoice.standard, id: \.title) { Text($0.title).tag($0.title) }
                    if case .custom = model.font { Text(model.font.title).tag(model.font.title) }
                }.labelsHidden().frame(width: 170)
            }
            Button("Choose Font…", action: actions.chooseFont)
            FontOverridesSection(model: model)
        }
    }

    private func settingRow<Controls: View>(_ title: String, _ detail: String, @ViewBuilder controls: () -> Controls) -> some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 5) { Text(title).fontWeight(.medium); Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 8)
            controls()
        }.padding(.vertical, 17)
    }
    private func callout(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor))
    }
}

@MainActor enum SettingsPillImage {
    static func make(skin: PillSkinKind, size: HiFiPillSize) -> NSImage? {
        let frame = NSRect(x: 0, y: 0, width: 360, height: 110)
        let view: any PillSkinView
        if skin == .hifi, let assets = try? PillAssets.loadHiFi() { view = HiFiPillView(frame: frame, assets: assets, size: size) }
        else { view = ClassicPillView(frame: frame) }
        view.appear(reduceMotion: true)
        view.showRecording(locked: true)
        view.showFractions([0.2, 0.4, 0.6, 0.8, 0.5, 0.35, 0.65, 0.3, 0.2, 0.1])
        guard let context = CGContext(data: nil, width: 720, height: 220, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: 2, y: 2)
        view.layer?.render(in: context)
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: frame.size)
    }
}
