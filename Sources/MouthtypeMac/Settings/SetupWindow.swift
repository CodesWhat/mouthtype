import AppKit
import AVFoundation
import MouthtypeCore
import SwiftUI

@MainActor struct SetupActions {
    var refresh: () -> Void = {}
    var poll: () -> Void = {}
    var microphone: () -> Void = {}
    var accessibility: () -> Void = {}
    var retrySpeech: () -> Void = {}
    var inputSettings: () -> Void = {}
    var done: () -> Void = {}
}

@MainActor final class SetupWindow: NSWindowController, NSWindowDelegate {
    static let contentSize = NSSize(width: 560, height: 440)

    let model: SetupModel
    private let refresh: () -> Void
    private let poll: () -> Void
    private let pollInterval: TimeInterval
    private var pollTimer: Timer?
    private var actions: SetupActions
    private let reduceTransparency: () -> Bool
    private let notifications: NotificationCenter
    private nonisolated(unsafe) var transparencyObserver: NSObjectProtocol?
    var isPolling: Bool { pollTimer != nil }
    var isObservingTransparency: Bool { transparencyObserver != nil }

    init(model: SetupModel, actions: SetupActions, pollInterval: TimeInterval = 2,
         reduceTransparency: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency },
         notifications: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.model = model
        self.pollInterval = pollInterval
        self.reduceTransparency = reduceTransparency
        self.notifications = notifications
        refresh = actions.refresh
        poll = actions.poll
        self.actions = actions
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Set Up Mouthtype"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        self.actions.done = { [weak self] in self?.close() }
        applyContent()
        window.setContentSize(Self.contentSize)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let transparencyObserver { notifications.removeObserver(transparencyObserver) }
    }

    /// Installs the glass or solid content to match Reduce Transparency. Called at init and again whenever the setting changes.
    private func applyContent() {
        guard let window else { return }
        let solid = reduceTransparency()
        let hosting = NSHostingView(rootView: SetupView(model: model, actions: actions, solid: solid))
        hosting.sizingOptions = []
        if solid {
            window.backgroundColor = .windowBackgroundColor
            window.contentView = hosting
        } else {
            window.backgroundColor = .clear
            let glass = NSGlassEffectView()
            glass.contentView = hosting
            window.contentView = glass
        }
        window.setContentSize(Self.contentSize)
    }

    private func startObservingTransparency() {
        guard transparencyObserver == nil else { return }
        transparencyObserver = notifications.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyContent() }
        }
        applyContent()
    }

    private func stopObservingTransparency() {
        guard let transparencyObserver else { return }
        notifications.removeObserver(transparencyObserver)
        self.transparencyObserver = nil
    }

    func present() {
        startObservingTransparency()
        refresh()
        model.refreshInstructions()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        startObservingTransparency()
        refresh()
        model.refreshInstructions()
        startPolling()
    }

    func windowDidResignKey(_ notification: Notification) { stopPolling() }

    func windowWillClose(_ notification: Notification) {
        stopPolling()
        stopObservingTransparency()
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

struct SetupView: View {
    @Bindable var model: SetupModel
    var actions: SetupActions
    var solid = false

    /// The window extends under the title bar, so the dots sit below the traffic lights (about 28 pt tall) with a gap.
    static let dotsTopInset: CGFloat = 36

    private var step: SetupStep { model.readiness.step }

    var body: some View {
        VStack(spacing: 0) {
            SetupStepDots(dots: step.dots).padding(.top, SetupView.dotsTopInset)
            ScrollView {
                VStack(spacing: 12) {
                    SetupLips().padding(.bottom, 6)
                    Text(title).font(DesignFont.serif(DesignFont.headline)).foregroundStyle(DesignPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(detail).font(DesignFont.sans(DesignFont.body)).foregroundStyle(DesignPalette.sideInk)
                        .fixedSize(horizontal: false, vertical: true)
                    controls.padding(.top, 6)
                    if step == .ready {
                        Text("Change your shortcut or recording behavior in Settings. Fast and Thorough use Basic until their cleanup model is ready.")
                            .font(DesignFont.sans(DesignFont.detail)).foregroundStyle(DesignPalette.sideInk)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(stepCaption).designEyebrow().foregroundStyle(DesignPalette.sideInk).tracking(1).padding(.top, 4)
                            .fixedSize(horizontal: false, vertical: true).accessibilityHidden(true)
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                .padding(.horizontal, 40).padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: 330)
                .accessibilityIdentifier("setup-card")
                .id(step)
            }.defaultScrollAnchor(.top)
            HStack {
                if step == .ready {
                    Button("Done", action: actions.done).buttonStyle(.designPrimary)
                        .keyboardShortcut(.defaultAction).accessibilityIdentifier("setup-done")
                } else {
                    Button("Set up later", action: actions.done).buttonStyle(.plain)
                        .font(DesignFont.sans(12.5)).foregroundStyle(DesignPalette.sideInk).accessibilityIdentifier("setup-done")
                }
                Spacer()
                footerSteps.accessibilityIdentifier("setup-progress")
            }
            .padding(.horizontal, 20).padding(.bottom, 16)
        }
        .frame(width: SetupWindow.contentSize.width, height: SetupWindow.contentSize.height)
        .ignoresSafeArea()
        .font(DesignFont.sans(DesignFont.body))
        .tint(DesignPalette.accent)
        .background { DesignSidebarBackground(solid: solid) }
    }

    /// The eyebrow under the card's control. Only Accessibility says it is being re-checked, because that is the step the
    /// user leaves the window for.
    private var stepCaption: String {
        let base = "Step \(step.rawValue) of 4"
        return step == .accessibility ? base + " · Checking every few seconds" : base
    }

    /// One Text so the names wrap onto a second line at narrow widths instead of truncating.
    private var footerSteps: some View {
        let line = SetupStep.footerNames.enumerated().reduce(Text("")) { text, entry in
            let name = Text(entry.element).foregroundColor(entry.offset + 1 == step.rawValue ? DesignPalette.ink : DesignPalette.sideInk)
            return entry.offset == 0 ? name : text + Text(" · ").foregroundColor(DesignPalette.hair) + name
        }
        return line
        .font(DesignFont.mono(DesignFont.eyebrow)).tracking(1)
        .multilineTextAlignment(.trailing)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(step == .ready ? "Setup complete" : "Step \(step.rawValue) of 4, \(SetupStep.footerNames[step.rawValue - 1].capitalized)")
    }

    private var title: String {
        switch step {
        case .microphone: "Let’s hear you."
        case .accessibility: "Put your words to work."
        case .speech: "Keep recognition on your Mac."
        case .shortcut: "Check your shortcut."
        case .ready: "You’re ready to talk."
        }
    }

    private var detail: String {
        switch step {
        case .microphone:
            switch model.diagnostics.microphoneStatus {
            case .notDetermined: "Allow microphone access so Mouthtype can hear you while you dictate. Audio stays on this Mac."
            case .denied, .restricted: "Microphone access is not allowed. Enable Mouthtype in System Settings, then return here."
            case .authorized:
                if model.capturePreparing { "Preparing your microphone…" }
                else { model.captureError ?? "Access allowed. Prepare your microphone to continue." }
            @unknown default: "Check Microphone access in System Settings."
            }
        case .accessibility:
            "Accessibility lets your shortcut work and puts text into your chosen app. Enable Mouthtype in System Settings, then return here."
        case .speech:
            speechStatus + "\nDownloaded once. Recognition runs on your Mac."
        case .shortcut:
            model.inputDetail + "\nCheck your shortcut with Change shortcut to continue."
        case .ready:
            model.instructions
        }
    }

    /// The bar carries the percentage, so the line above it doesn't repeat it.
    private var speechStatus: String {
        if case .downloading = model.engine.downloadStatus { return "Downloading the speech model." }
        return model.engine.statusText
    }

    @ViewBuilder private var speechControls: some View {
        switch model.engine.downloadStatus {
        case .failed:
            action("Retry model", identifier: "setup-retry-model", perform: actions.retrySpeech)
        case let .downloading(progress):
            SetupDownloadMeter(fraction: progress.fraction, caption: ModelDownloadFormat.caption(progress), label: "Speech model download")
                .accessibilityIdentifier("setup-speech-progress")
        case .done:
            SetupDownloadMeter(fraction: 1, caption: "Downloaded", label: "Speech model download")
                .accessibilityIdentifier("setup-speech-progress")
        case .preparing, .available:
            ProgressView().controlSize(.small).accessibilityLabel("Preparing speech model")
        }
    }

    @ViewBuilder private var controls: some View {
        switch step {
        case .microphone:
            if model.capturePreparing {
                ProgressView().controlSize(.small)
            } else {
                action(microphoneAction, identifier: "setup-microphone", perform: actions.microphone)
            }
        case .accessibility:
            action("Open System Settings…", identifier: "setup-accessibility", perform: actions.accessibility)
        case .speech:
            speechControls
        case .shortcut:
            action("Change shortcut…", identifier: "setup-input-settings", perform: actions.inputSettings)
        case .ready:
            SetupCleanupModels(models: model.cleanupModels, download: model.downloadCleanupModel, cancel: model.cancelCleanupDownload)
        }
    }

    private var microphoneAction: String {
        switch model.diagnostics.microphoneStatus {
        case .notDetermined: "Allow microphone…"
        case .authorized: "Prepare microphone"
        default: "Microphone Settings…"
        }
    }

    private func action(_ title: String, identifier: String, perform: @escaping () -> Void) -> some View {
        Button(title, action: perform).buttonStyle(SetupActionButtonStyle())
            .keyboardShortcut(.defaultAction).accessibilityIdentifier(identifier)
    }
}

/// A determinate bar over a caption, in the sheet's own colours. The caption wraps rather than truncating.
struct SetupDownloadMeter: View {
    var fraction: Double
    var caption: String
    var label: String

    var body: some View {
        VStack(spacing: 6) {
            SetupProgressBar(fraction: fraction)
            Text(caption).font(DesignFont.sans(DesignFont.detail)).foregroundStyle(DesignPalette.sideInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 320)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((min(max(fraction, 0), 1) * 100).rounded())) percent, \(caption)")
    }
}

struct SetupProgressBar: View {
    var fraction: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(DesignPalette.track)
                    .overlay(Capsule().strokeBorder(DesignPalette.hair, lineWidth: 1))
                Capsule().fill(DesignPalette.accent)
                    .frame(width: max(proxy.size.width * min(max(fraction, 0), 1), fraction > 0 ? 6 : 0))
            }
        }
        .frame(height: 6)
        .animation(reduceMotion ? nil : .linear(duration: 0.25), value: fraction)
        .accessibilityHidden(true)
    }
}

/// Fast and Thorough on the ready step, each with its own bar. They download in the background, so setup can close first.
struct SetupCleanupModels: View {
    var models: [CleanupModelStatus]
    var download: (CleanupLevel) -> Void
    var cancel: (CleanupLevel) -> Void

    var body: some View {
        if !models.isEmpty {
            DesignSection(eyebrow: "Cleanup models") {
                ForEach(models) { model in
                    SetupCleanupRow(model: model, download: { download(model.level) }, cancel: { cancel(model.level) })
                }
            }
            .multilineTextAlignment(.leading)
            .accessibilityIdentifier("setup-cleanup-models")
        }
    }
}

struct SetupCleanupRow: View {
    var model: CleanupModelStatus
    var download: () -> Void
    var cancel: () -> Void

    private var size: String { ModelDownloadFormat.size(Int64(model.sizeMB) * 1_000_000) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(model.level.title).font(DesignFont.sans(DesignFont.body, .medium)).foregroundStyle(DesignPalette.ink)
                        if model.selected {
                            Text("Selected").designEyebrow().foregroundStyle(DesignPalette.accentText)
                        }
                    }
                    Text("\(model.name) · \(size)").font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                trailing
            }
            switch model.status {
            case let .downloading(progress):
                VStack(alignment: .leading, spacing: 4) {
                    SetupProgressBar(fraction: progress.fraction)
                    Text(ModelDownloadFormat.caption(progress)).font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(model.level.title) cleanup model download")
                .accessibilityValue("\(Int((progress.fraction * 100).rounded())) percent, \(ModelDownloadFormat.caption(progress))")
            case let .failed(message):
                Text(message).font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .accessibilityIdentifier("setup-cleanup-\(model.level.rawValue)")
    }

    @ViewBuilder private var trailing: some View {
        switch model.status {
        case .available:
            Button("Download", action: download).buttonStyle(.designSecondary)
                .accessibilityLabel("Download \(model.level.title) cleanup model, \(size)")
        case .downloading:
            Button("Cancel", action: cancel).buttonStyle(.designSecondary)
                .accessibilityLabel("Cancel \(model.level.title) cleanup model download")
                .accessibilityIdentifier("setup-cleanup-cancel-\(model.level.rawValue)")
        case .preparing:
            Text("Downloading").font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2)
        case .done:
            Label("Done", systemImage: "checkmark.circle.fill").font(DesignFont.sans(DesignFont.detail, .medium))
                .foregroundStyle(DesignPalette.success)
        case .failed:
            Button("Retry", action: download).buttonStyle(.designSecondary)
                .accessibilityLabel("Retry \(model.level.title) cleanup model download")
        }
    }
}

struct SetupStepDots: View {
    var dots: [SetupDot]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(dots.enumerated()), id: \.offset) { _, dot in
                Capsule().fill(fill(dot)).frame(width: dot == .active ? 18 : 5, height: 5)
            }
        }
        .accessibilityHidden(true)
    }

    private func fill(_ dot: SetupDot) -> Color {
        switch dot {
        case .active: DesignPalette.accent
        case .done: DesignPalette.c3
        case .pending: DesignPalette.track
        }
    }
}

struct SetupLips: View {
    static let size = CGSize(width: 36, height: 22)
    static let scale: CGFloat = 1.5

    var body: some View {
        if let url = Bundle.module.url(forResource: "lips-36x22", withExtension: "png", subdirectory: "Settings"),
           let sprite = NSImage(contentsOf: url) {
            Image(nsImage: sprite).resizable().interpolation(.none).antialiased(false)
                .frame(width: Self.size.width * Self.scale, height: Self.size.height * Self.scale)
                .accessibilityHidden(true)
        }
    }
}

/// The card's main action: the accent button at the 36 pt height the setup mock draws.
private struct SetupActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        configuration.label
            .font(DesignFont.sans(DesignFont.body, .medium)).foregroundStyle(DesignPalette.onAccent)
            .padding(.horizontal, 18).frame(minHeight: 36)
            .background(shape.fill(DesignPalette.accent))
            .overlay { if configuration.isPressed { shape.fill(Color.black.opacity(0.1)) } }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
    }
}
