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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 730),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Set Up Mouthtype"
        window.minSize = NSSize(width: 620, height: 660)
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

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("MOUTHTYPE / GET STARTED").font(.custom("JetBrainsMono-Medium", size: 10)).foregroundStyle(.secondary)
                        Text("A little less typing.").font(.custom("InstrumentSerif-Regular", size: 42))
                        Text("Two permissions and a local speech model. Then you’re ready to talk.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(spacing: 0) {
                        row("Microphone", icon: "mic", complete: model.diagnostics.microphoneStatus == .authorized && model.captureReady,
                            detail: microphoneDetail) { microphoneControls }
                        row("Accessibility", icon: "hand.raised", complete: model.diagnostics.accessibilityGranted,
                            detail: model.diagnostics.accessibilityGranted ? "Allowed. Your shortcut and text delivery can work across apps." : "Lets your shortcut work and puts text into your chosen app.") {
                            if !model.diagnostics.accessibilityGranted {
                                Button("Open System Settings…", action: actions.accessibility).accessibilityIdentifier("setup-accessibility")
                            }
                        }
                        row("Speech model", icon: "waveform", complete: speechReady,
                            detail: model.engine.statusText + "\nDownloaded once. Recognition runs on your Mac.") {
                            if model.engine.state == .loading { ProgressView().controlSize(.small) }
                            if case .failed = model.engine.state {
                                Button("Retry model", action: actions.retrySpeech).accessibilityIdentifier("setup-retry-model")
                            }
                        }.accessibilityIdentifier("setup-model-status")
                        row("Dictation shortcut", icon: "keyboard", complete: model.diagnostics.accessibilityGranted && model.diagnostics.hotkeyHealth == .listening && !model.readiness.globeConflict,
                            detail: model.inputDetail) {
                            Button("Input settings…", action: actions.inputSettings).accessibilityIdentifier("setup-input-settings")
                        }
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        Label(model.readiness.isReady ? "Ready to dictate" : "Finish setup to start dictating.",
                            systemImage: model.readiness.isReady ? "checkmark.circle.fill" : "info.circle")
                            .font(.headline).foregroundStyle(model.readiness.isReady ? Color(red: 0.19, green: 0.36, blue: 0.34) : .primary)
                            .accessibilityIdentifier("setup-readiness")
                        Text(model.instructions).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text("Change your shortcut or recording behavior in Settings. Fast and Thorough use Basic until their cleanup model is ready.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(32).frame(maxWidth: .infinity, alignment: .leading)
            }.defaultScrollAnchor(.top)
            VStack(spacing: 14) {
                Divider()
                HStack {
                    Button("Refresh status", action: actions.refresh).accessibilityIdentifier("setup-refresh")
                    Spacer()
                    Button(model.readiness.isReady ? "Done" : "Set up later", action: actions.done)
                        .keyboardShortcut(.defaultAction).accessibilityIdentifier("setup-done")
                }
                Text("Reopen setup from Settings → General.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 32).padding(.bottom, 22)
        }
        .font(.custom("InstrumentSans-Regular", size: 13))
        .tint(Color(red: 0.19, green: 0.36, blue: 0.34))
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var speechReady: Bool { if case .ready = model.engine.state { true } else { false } }

    private var microphoneDetail: String {
        switch model.diagnostics.microphoneStatus {
        case .notDetermined: "Lets Mouthtype hear you while you dictate."
        case .denied, .restricted: "Microphone access is not allowed. Enable Mouthtype in System Settings."
        case .authorized:
            if model.capturePreparing { "Preparing microphone…" }
            else if model.captureReady { "Allowed. Microphone prepared for dictation." }
            else { model.captureError ?? "Access allowed. Prepare your microphone to continue." }
        @unknown default: "Check Microphone access in System Settings."
        }
    }

    @ViewBuilder private var microphoneControls: some View {
        switch model.diagnostics.microphoneStatus {
        case .notDetermined:
            Button("Allow microphone…", action: actions.microphone).accessibilityIdentifier("setup-microphone")
        case .denied, .restricted:
            Button("Microphone Settings…", action: actions.microphone).accessibilityIdentifier("setup-microphone")
        case .authorized:
            if model.capturePreparing { ProgressView().controlSize(.small) }
            else if !model.captureReady {
                Button("Prepare microphone", action: actions.microphone).accessibilityIdentifier("setup-microphone")
            }
        @unknown default:
            Button("Microphone Settings…", action: actions.microphone)
        }
    }

    private func row<Controls: View>(_ title: String, icon: String, complete: Bool, detail: String,
        @ViewBuilder controls: () -> Controls) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: complete ? "checkmark.circle" : icon).font(.title3).foregroundStyle(.secondary)
                    .frame(width: 28).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.headline)
                    Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                controls().fixedSize()
            }.padding(.vertical, 20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
