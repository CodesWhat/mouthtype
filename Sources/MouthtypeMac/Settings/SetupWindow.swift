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
    var isPolling: Bool { pollTimer != nil }

    init(model: SetupModel, actions: SetupActions, pollInterval: TimeInterval = 2,
         reduceTransparency: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency) {
        self.model = model
        self.pollInterval = pollInterval
        refresh = actions.refresh
        poll = actions.poll
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Set Up Mouthtype"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        var actions = actions
        actions.done = { [weak self] in self?.close() }
        let hosting = NSHostingView(rootView: SetupView(model: model, actions: actions, solid: reduceTransparency))
        hosting.sizingOptions = []
        if reduceTransparency {
            window.backgroundColor = .windowBackgroundColor
            window.contentView = hosting
        } else {
            let glass = NSGlassEffectView()
            glass.contentView = hosting
            window.contentView = glass
        }
        window.setContentSize(Self.contentSize)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        refresh()
        model.refreshInstructions()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refresh()
        model.refreshInstructions()
        startPolling()
    }

    func windowDidResignKey(_ notification: Notification) { stopPolling() }

    func windowWillClose(_ notification: Notification) { stopPolling() }

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

    private static let brand = Color(red: 0.19, green: 0.36, blue: 0.34)

    private var step: SetupStep { model.readiness.step }

    var body: some View {
        VStack(spacing: 0) {
            SetupStepDots(dots: step.dots).padding(.top, 18)
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
        .font(.custom("InstrumentSans-Regular", size: 14))
        .tint(Self.brand)
        .background { if solid { Color(nsColor: .windowBackgroundColor) } }
    }

    private var footerSteps: some View {
        HStack(spacing: 6) {
            ForEach(Array(SetupStep.footerNames.enumerated()), id: \.offset) { index, name in
                if index > 0 { Text("·") }
                Text(name).foregroundStyle(index + 1 == step.rawValue ? Color.primary : Color.secondary)
            }
        }
        .font(.custom("JetBrainsMono-Medium", size: 8)).tracking(1)
        .foregroundStyle(.secondary)
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
