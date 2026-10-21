import AppKit
import AVFoundation
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
                    Text(detail).font(DesignFont.sans(DesignFont.body)).foregroundStyle(DesignPalette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    controls.padding(.top, 6)
                    if step == .ready {
                        Text("Change your shortcut or recording behavior in Settings. Fast and Thorough use Basic until their cleanup model is ready.")
                            .font(DesignFont.sans(DesignFont.detail)).foregroundStyle(DesignPalette.ink2)
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
                        .font(DesignFont.sans(12.5)).foregroundStyle(DesignPalette.ink2).accessibilityIdentifier("setup-done")
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
            model.engine.statusText + "\nDownloaded once. Recognition runs on your Mac."
        case .shortcut:
            model.inputDetail + "\nCheck your shortcut in Input settings to continue."
        case .ready:
            model.instructions
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
            if case .failed = model.engine.state {
                action("Retry model", identifier: "setup-retry-model", perform: actions.retrySpeech)
            } else {
                ProgressView().controlSize(.small).accessibilityLabel("Preparing speech model")
            }
        case .shortcut:
            action("Input settings…", identifier: "setup-input-settings", perform: actions.inputSettings)
        case .ready:
            EmptyView()
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
