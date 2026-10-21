import AppKit
import SwiftUI
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@MainActor @Suite(.serialized) struct SettingsLayoutTests {
    private func makeModel(_ body: (UserDefaults) -> Void = { _ in }) throws -> (SettingsModel, () -> Void) {
        let name = "SettingsLayout-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        FontRegistry.registerBundledFonts()
        body(defaults)
        return (SettingsModel(defaults: defaults), { defaults.removePersistentDomain(forName: name) })
    }

    private func actions() -> SettingsActions {
        let state = SettingsDiagnostics()
        state.engineStatus = "Parakeet TDT v3 ready"
        return SettingsActions(cleaner: LayoutCleaner(), diagnostics: state, updater: AppUpdater(driver: LayoutUpdateDriver(), activity: { .idle }))
    }

    private func descendants(of view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap { descendants(of: $0) } }
    private func count(_ typeName: String, in view: NSView) -> Int {
        descendants(of: view).filter { String(describing: type(of: $0)).contains(typeName) }.count
    }

    // MARK: Window

    @Test func windowIs900By620WithMinimum860By600() throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        let controller = SettingsWindow(model: model, actions: actions(), reduceTransparency: { true })
        let window = try #require(controller.window)
        #expect(window.contentRect(forFrameRect: window.frame).size == NSSize(width: 900, height: 620))
        #expect(window.contentMinSize == NSSize(width: 860, height: 600))
        #expect(window.styleMask.contains(.fullSizeContentView) && window.styleMask.contains(.resizable))
        #expect(window.titlebarAppearsTransparent && window.titleVisibility == .hidden)
        #expect(window.title == "Mouthtype Settings" && !window.isVisible)
        #expect(SettingsTheme.sidebarWidth == 212)
    }

    @Test func sidebarIsGlassUnlessReduceTransparencyIsOn() throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        let glass = SettingsWindow(model: model, actions: actions(), reduceTransparency: { false })
        #expect(glass.window?.contentView is NSGlassEffectView)
        #expect(glass.window?.backgroundColor == .clear)
        let solid = SettingsWindow(model: model, actions: actions(), reduceTransparency: { true })
        #expect(!(solid.window?.contentView is NSGlassEffectView))
        #expect(solid.window?.contentView is NSHostingView<SettingsView>)
    }

    // MARK: Sidebar

    @Test func sidebarListsSixPagesAndTheSettingsModalHasThreeBeforeAdvanced() {
        #expect(SettingsPage.allCases.map(\.title) == ["Home", "Stats", "Dictionary", "Transforms", "Style", "Appearance"])
        #expect(SettingsModalPage.visible(advanced: false).map(\.title) == ["General", "Mac", "Health"])
        #expect(SettingsModalPage.visible(advanced: true).map(\.title) == ["General", "Mac", "Health", "Advanced"])
        #expect(SettingsPage.allCases.map(\.symbol) == ["house", "chart.bar", "book.closed", "wand.and.stars", "textformat", "capsule"])
        #expect(SettingsModalPage.allCases.map(\.symbol) == ["gearshape", "laptopcomputer", "heart.text.square", "slider.horizontal.3"])
    }

    @Test func advancedSwitchPersistsAndAddsThePage() throws {
        let name = "SettingsAdvanced-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = SettingsModel(defaults: defaults)
        #expect(!model.advancedOptions)
        model.openSettings(.advanced)
        #expect(model.settingsOpen && model.modalPage == .general, "Advanced is unavailable while its switch is off")
        model.setAdvancedOptions(true)
        model.selectModal(.advanced)
        #expect(model.modalPage == .advanced)
        #expect(SettingsModel(defaults: defaults).advancedOptions)
        model.setAdvancedOptions(false)
        #expect(model.modalPage == .general && !SettingsModel(defaults: defaults).advancedOptions)
        model.closeSettings()
        #expect(!model.settingsOpen)
    }

    @Test func nestedEditorsAttachToTheTopmostSheet() throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        let controller = SettingsWindow(model: model, actions: actions(), reduceTransparency: { true })
        let window = try #require(controller.window)
        #expect(controller.topmostWindow === window)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.beginSheet(sheet)
        #expect(controller.topmostWindow === sheet)
        window.endSheet(sheet)
    }

    // MARK: Type and colour

    @Test func noSettingsFontIsBelowTenPoints() throws {
        #expect(SettingsFont.minimum == 10 && DesignFont.axis == 9 && DesignFont.eyebrow == 10)
        #expect(DesignFont.headline == 28 && DesignFont.body == 13 && DesignFont.detail == 12 && DesignFont.caption == 11.5)
        #expect(SettingsFont.all.allSatisfy { $0 >= 10 })
        #expect(SettingsFont.eyebrow == 10 && SettingsFont.footer == 10 && SettingsFont.wordmark == 28 && SettingsFont.title == 22)
        #expect(SettingsFont.headerDescription == 12.5)
        FontRegistry.registerBundledFonts()
        for name in [SettingsFont.sansName, SettingsFont.serifName, SettingsFont.monoName] {
            #expect(NSFont(name: name, size: SettingsFont.minimum) != nil)
        }
    }

    /// Nothing below 10 pt, except the 9 pt chart axis labels (README: "Nothing below 9 px, and 9 only on axis labels").
    /// Scans every UI source directory for `size:` literals, `DesignFont.<face>(<number>)` calls and the `DesignFont` scale
    /// constants, whether declared or referenced by name.
    @Test func sourcesDeclareNoPointSizeBelowTen() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/MouthtypeMac")
        let directories = ["Settings", "Design", "Stats", "Dictation", "FileTranscription", "Insertion", "Card"]
        // The only sub-10 sizes allowed: the `axis` scale constant (9 pt), used for chart axis labels in the stats page.
        let axisFiles: Set<String> = ["Stats/StatsPage.swift"]
        let number = #"([0-9]+(?:\.[0-9]+)?)"#
        let literal = try NSRegularExpression(pattern: #"size:\s*"# + number)
        let call = try NSRegularExpression(pattern: #"DesignFont\.[a-z]+\(\s*"# + number)
        let declaration = try NSRegularExpression(pattern: #"static let ([a-zA-Z]+): CGFloat = "# + number)
        let reference = try NSRegularExpression(pattern: #"DesignFont\.([a-zA-Z]+)\b(?!\()"#)

        func matches(_ regex: NSRegularExpression, in text: String) -> [NSTextCheckingResult] {
            regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        }
        func capture(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String {
            String(text[Range(match.range(at: index), in: text)!])
        }

        let typography = try String(contentsOf: sources.appendingPathComponent("Design/DesignTypography.swift"), encoding: .utf8)
        var scale: [String: Double] = [:]
        for match in matches(declaration, in: typography) {
            // Tracking is letter spacing, not a point size.
            if !capture(match, 1, in: typography).hasSuffix("Tracking") { scale[capture(match, 1, in: typography)] = Double(capture(match, 2, in: typography))! }
        }
        #expect(scale["axis"] == 9 && scale["eyebrow"] == 10)

        var found = 0
        let manager = FileManager.default
        for directory in directories {
            let enumerator = try #require(manager.enumerator(at: sources.appendingPathComponent(directory), includingPropertiesForKeys: nil))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let relative = directory + url.path.components(separatedBy: "/Sources/MouthtypeMac/" + directory).last!
                let text = try String(contentsOf: url, encoding: .utf8)
                var values: [(String, Double)] = []
                for match in matches(literal, in: text) + matches(call, in: text) {
                    values.append((capture(match, 0, in: text), Double(capture(match, 1, in: text))!))
                }
                for match in matches(reference, in: text) {
                    let name = capture(match, 1, in: text)
                    if let value = scale[name] { values.append(("DesignFont." + name, value)) }
                }
                if relative == "Design/DesignTypography.swift" {
                    for match in matches(declaration, in: text) where capture(match, 1, in: text) != "axis" && scale[capture(match, 1, in: text)] != nil {
                        values.append((capture(match, 0, in: text), Double(capture(match, 2, in: text))!))
                    }
                    values.removeAll { $0.0 == "DesignFont.axis" }
                }
                for (snippet, value) in values {
                    found += 1
                    let isAxis = value == 9 && snippet.hasSuffix("axis") && axisFiles.contains(relative)
                    #expect(value >= 10 || isAxis, "\(relative) declares a \(value) pt font: \(snippet)")
                }
            }
        }
        #expect(found > 0)
    }

    @Test func accentIsLimeNotSystemBlue() {
        func resolve(_ color: NSColor, _ name: NSAppearance.Name) -> String {
            var hex = ""
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                let c = color.usingColorSpace(.sRGB)!
                hex = String(format: "%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
            }
            return hex
        }
        #expect(resolve(SettingsTheme.controlNS, .aqua) == "76A11A")
        #expect(resolve(SettingsTheme.controlNS, .darkAqua) == "A6CD52")
    }

    // MARK: Layout

    @Test func generalFitsTheModalWithoutScrolling() throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        for dark in [false, true] {
            model.modalPage = .general
            let (view, _) = SettingsRender.hostModal(model: model, actions: actions(), dark: dark)
            let scroll = try #require(descendants(of: view).compactMap { $0 as? NSScrollView }.first)
            let document = try #require(scroll.documentView)
            #expect(document.frame.height <= scroll.contentView.bounds.height + 1,
                    "General needs \(document.frame.height) pt but only \(scroll.contentView.bounds.height) pt is visible")
        }
    }

    // MARK: Long microphone names, keyboard, persistent state

    private static let longMic = "Scott’s AirPods Pro 2 – Hands-Free Microphone (Bluetooth)"

    private func longMicModel(_ defaults: UserDefaults) -> SettingsModel {
        let devices = [MicrophoneDevice(uid: "long", name: Self.longMic, input: .init(sampleRate: 16_000, channels: 1, id: 7)),
                       MicrophoneDevice(uid: "mac", name: "MacBook Pro Microphone", input: .init(sampleRate: 48_000, channels: 1, id: 8))]
        try? PreferredMicrophone.save(.init(uid: "long", name: Self.longMic), in: defaults)
        let mic = MicrophoneSettingsModel(defaults: defaults, devices: { devices }, defaultInput: { 8 })
        return SettingsModel(defaults: defaults, microphone: mic)
    }

    /// Every rendered SwiftUI text must be laid out at least as tall as its wrapped content needs, and no word may be split.
    private func textsAreUntruncated(in view: NSView) -> [String] {
        var problems: [String] = []
        for sub in descendants(of: view) {
            guard let field = sub as? NSTextField, !field.isEditable, !field.stringValue.isEmpty, field.bounds.width > 0 else { continue }
            let font = field.font ?? .systemFont(ofSize: 13)
            for word in field.stringValue.split(whereSeparator: \.isWhitespace) {
                let width = (String(word) as NSString).size(withAttributes: [.font: font]).width
                if width > field.bounds.width + 1 { problems.append("\(word) (\(width) > \(field.bounds.width))") }
            }
            let needed = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: field.bounds.width, height: .greatestFiniteMagnitude)).height ?? 0
            if needed > field.bounds.height + 2 { problems.append("\(field.stringValue) needs \(needed) has \(field.bounds.height)") }
        }
        return problems
    }

    @Test(arguments: [NSSize(width: 760, height: 540)])
    func longMicrophoneNameKeepsGeneralInsideTheModal(size: NSSize) throws {
        let name = "SettingsLayoutLong-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        FontRegistry.registerBundledFonts()
        let model = longMicModel(defaults)
        model.modalPage = .general
        let (view, window) = SettingsRender.hostModal(model: model, actions: actions(), dark: false)
        let scroll = try #require(descendants(of: view).compactMap { $0 as? NSScrollView }.first)
        let document = try #require(scroll.documentView)
        print("MEASURED General \(Int(size.width))x\(Int(size.height)) content=\(document.frame.height) visible=\(scroll.contentView.bounds.height) docWidth=\(document.frame.width) viewport=\(scroll.contentView.bounds.width)")
        #expect(document.frame.height <= scroll.contentView.bounds.height + 1,
                "General needs \(document.frame.height) pt but only \(scroll.contentView.bounds.height) pt is visible")
        #expect(document.frame.width <= scroll.contentView.bounds.width + 1)
        #expect(textsAreUntruncated(in: view).isEmpty, "\(textsAreUntruncated(in: view))")
        // The design popup is drawn rather than an NSPopUpButton, so check the model and let the width and untruncated checks above cover layout.
        #expect(model.microphone.choice == .device("long"))
        #expect(model.microphone.inputs.contains { $0.name == Self.longMic })
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect(!window.isVisible)
        let directory = URL(fileURLWithPath: "/tmp/mt-visual/settings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("long-mic-\(Int(size.width)).png"))
    }

    @Test func updatesAndToneRowsStayReadableAtMinimumWidth() throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        model.page = .style
        let (page, _) = SettingsRender.host(model: model, actions: actions(), dark: false, size: SettingsTheme.minimumSize)
        #expect(textsAreUntruncated(in: page).isEmpty, "Style: \(textsAreUntruncated(in: page))")
        for modalPage in SettingsModalPage.visible(advanced: true) {
            model.setAdvancedOptions(true)
            model.modalPage = modalPage
            let (view, _) = SettingsRender.hostModal(model: model, actions: actions(), dark: false)
            #expect(textsAreUntruncated(in: view).isEmpty, "\(modalPage.title): \(textsAreUntruncated(in: view))")
        }
    }

    @Test func arrowKeysMoveTheSidebarSelectionAndStopAtTheEnds() {
        #expect(SettingsPage.style.moved(by: 1) == .appearance)
        #expect(SettingsPage.appearance.moved(by: -1) == .style)
        #expect(SettingsPage.style.moved(by: -1) == .transforms)
        #expect(SettingsPage.transforms.moved(by: -1) == .dictionary)
        #expect(SettingsPage.dictionary.moved(by: -1) == .stats)
        #expect(SettingsPage.stats.moved(by: -1) == .home)
        #expect(SettingsPage.home.moved(by: 1) == .stats)
        #expect(SettingsPage.home.moved(by: -1) == .home)
        #expect(SettingsPage.appearance.moved(by: 1) == .appearance)
    }

    @Test func halfTypedWebsiteDomainSurvivesRebuildingTheView() throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        model.websiteDomain = "slack"
        let first = SettingsWindow(model: model, actions: actions(), reduceTransparency: { true })
        let second = SettingsWindow(model: model, actions: actions(), reduceTransparency: { false })
        _ = (first, second)
        #expect(model.websiteDomain == "slack")
    }

    // MARK: Every old control is still reachable

    @Test func everyOldControlIdentifierStillExistsInTheSettingsSources() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("Sources/MouthtypeMac/Settings")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".swift") }
        let source = try files.map { try String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8) }.joined()
        let identifiers = ["settings-setup", "settings-shortcut", "settings-recording-mode",
                           "settings-quiet-audio", "settings-live-preview", "settings-microphone", "settings-microphone-refresh",
                           "settings-audio-age", "settings-audio-size", "settings-font-overrides", "settings-font-reset",
                           "style-website-domain"]
        for id in identifiers { #expect(source.contains("\"\(id)\""), "missing \(id)") }
        let titles = ["Microphone", "Shortcut", "Recording behavior", "Cleanup", "Quiet other audio", "Live words",
                      "Recording sounds", "Launch at login", "Updates", "Remove fillers", "Spoken commands and lists", "Format numbers", "Learn from my corrections",
                      "Lowercase sentence starts", "Drop the final full stop", "Edit dictionary file…", "Pill style", "Pill size",
                      "Text font", "Choose Font…", "Override individual fonts", "Keep completed recordings",
                      "Completed audio size limit", "Download…", "Check for Updates…", "Set Up Mouthtype…", "Transcribe a file…"]
        for title in titles { #expect(source.contains("\"\(title)\""), "missing \(title)") }
    }
}

@MainActor private final class LayoutCleaner: CleanupModelManaging {
    let state = CleanerState.absent
    let modelName = "Fast cleanup"
    let downloadSizeMB = 600
    func start() {}
    func levelChanged() {}
    func startDownload() {}
    func cancelDownload() {}
    nonisolated func recordingStarted() {}
    func readiness(waitingUpTo limit: Duration) async -> SmartCleanerInfo? { nil }
    func run(_ request: SmartCleanupRequest) async -> SmartCleanupResult { fatalError("Layout tests do not run cleanup") }
}

@MainActor private final class LayoutUpdateDriver: UpdateDriving {
    weak var delegate: (any UpdateDriverDelegate)?
    var onChange: (() -> Void)?
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = false
    func start() throws {}
    func checkForUpdates() {}
}
