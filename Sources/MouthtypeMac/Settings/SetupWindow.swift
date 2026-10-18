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

    private static let brand = Color(red: 0.19, green: 0.36, blue: 0.34)

    private var step: SetupStep { model.readiness.step }

    var body: some View {
        VStack(spacing: 0) {
            SetupStepDots(dots: step.dots).padding(.top, SetupView.dotsTopInset)
            ScrollView {
                VStack(spacing: 12) {
                    SetupLips().padding(.bottom, 6)
                    Text(title).font(.custom("InstrumentSerif-Regular", size: 30))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(detail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    controls.padding(.top, 4)
                    if step == .ready {
                        Text("Change your shortcut or recording behavior in Settings. Fast and Thorough use Basic until their cleanup model is ready.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
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
                    Button("Done", action: actions.done)
                        .keyboardShortcut(.defaultAction).accessibilityIdentifier("setup-done")
                } else {
                    Button("Set up later", action: actions.done).buttonStyle(.link)
                        .foregroundStyle(.secondary).accessibilityIdentifier("setup-done")
                }
                Spacer()
                footerSteps.accessibilityIdentifier("setup-progress")
            }
            .font(.callout).padding(.horizontal, 20).padding(.bottom, 16)
        }
        .frame(width: SetupWindow.contentSize.width, height: SetupWindow.contentSize.height)
        .ignoresSafeArea()
        .font(.custom("InstrumentSans-Regular", size: 14))
        .tint(Self.brand)
        .background { if solid { Color(nsColor: .windowBackgroundColor) } }
    }

    /// One Text so the names wrap onto a second line at narrow widths instead of truncating.
    private var footerSteps: some View {
        let line = SetupStep.footerNames.enumerated().reduce(Text("")) { text, entry in
            let name = Text(entry.element).foregroundColor(entry.offset + 1 == step.rawValue ? .primary : .secondary)
            return entry.offset == 0 ? name : text + Text(" · ").foregroundColor(.secondary) + name
        }
        return line
        .font(.custom("JetBrainsMono-Medium", size: 10)).tracking(1)
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
        Button(title, action: perform).buttonStyle(.borderedProminent).controlSize(.large)
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
        case .active: Color(red: 0.19, green: 0.36, blue: 0.34)
        case .done: Color(red: 0.19, green: 0.36, blue: 0.34).opacity(0.5)
        case .pending: Color.primary.opacity(0.18)
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
