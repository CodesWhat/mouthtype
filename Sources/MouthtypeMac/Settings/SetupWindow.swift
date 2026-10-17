import AppKit
import AVFoundation
import SwiftUI

@MainActor struct SetupActions {
    var refresh: () -> Void = {}
    var microphone: () -> Void = {}
    var accessibility: () -> Void = {}
    var retrySpeech: () -> Void = {}
    var inputSettings: () -> Void = {}
    var done: () -> Void = {}
}

@MainActor final class SetupWindow: NSWindowController, NSWindowDelegate {
    let model: SetupModel
    private let refresh: () -> Void

    init(model: SetupModel, actions: SetupActions) {
        self.model = model
        refresh = actions.refresh
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 590),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Set Up Mouthtype"
        window.minSize = NSSize(width: 560, height: 540)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        var actions = actions
        actions.done = { [weak self] in self?.close() }
        window.contentView = NSHostingView(rootView: SetupView(model: model, actions: actions))
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

    func windowDidBecomeKey(_ notification: Notification) { refresh(); model.refreshInstructions() }
}

struct SetupView: View {
    @Bindable var model: SetupModel
    var actions: SetupActions

    private var step: SetupStep { model.readiness.step }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("MOUTHTYPE / GET STARTED")
                Spacer()
                Text(step == .ready ? "READY" : "STEP \(step.rawValue) OF 4")
                    .accessibilityIdentifier("setup-progress")
            }
            .font(.custom("JetBrainsMono-Medium", size: 10)).foregroundStyle(.secondary)
            .padding(.horizontal, 32).padding(.top, 28)
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: symbol).font(.system(size: 28))
                        .foregroundStyle(.secondary)
                        .frame(width: 68, height: 68)
                        .background(Color(red: 0.19, green: 0.36, blue: 0.34).opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                        .accessibilityHidden(true)
                    Text(title).font(.custom("InstrumentSerif-Regular", size: 42))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(detail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    controls
                    if step == .ready {
                        Text("Change your shortcut or recording behavior in Settings. Fast and Thorough use Basic until their cleanup model is ready.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480, minHeight: 360)
                .padding(32).frame(maxWidth: .infinity)
                .accessibilityIdentifier("setup-card")
                .id(step)
            }.defaultScrollAnchor(.top)
            VStack(spacing: 14) {
                Divider()
                HStack {
                    Button("Refresh status", action: actions.refresh).accessibilityIdentifier("setup-refresh")
                    Spacer()
                    if step == .ready {
                        Button("Done", action: actions.done)
                            .keyboardShortcut(.defaultAction).accessibilityIdentifier("setup-done")
                    } else {
                        Button("Set up later", action: actions.done).accessibilityIdentifier("setup-done")
                    }
                }
                Text("Reopen setup from Settings → General.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 32).padding(.bottom, 22)
        }
        .font(.custom("InstrumentSans-Regular", size: 14))
        .tint(Color(red: 0.19, green: 0.36, blue: 0.34))
        .background(Color(nsColor: .textBackgroundColor))
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

    private var symbol: String {
        switch step {
        case .microphone: "mic"
        case .accessibility: "hand.raised"
        case .speech: "waveform"
        case .shortcut: "keyboard"
        case .ready: "checkmark"
        }
    }

    private var detail: String {
        switch step {
        case .microphone:
            switch model.diagnostics.microphoneStatus {
            case .notDetermined: "Allow microphone access so Mouthtype can hear you while you dictate."
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
