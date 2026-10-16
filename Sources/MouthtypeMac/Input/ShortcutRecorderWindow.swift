import AppKit

@MainActor
final class ShortcutRecorderWindow: NSWindowController, NSWindowDelegate {
    let recorder: ShortcutRecorder
    private let recordButton = NSButton(title: "", target: nil, action: nil)
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let apply: (DictationShortcut?) -> String?
    private let onClose: () -> Void

    init(saved: DictationShortcut?, apply: @escaping (DictationShortcut?) -> String?, onClose: @escaping () -> Void) {
        recorder = ShortcutRecorder(saved: saved)
        self.apply = apply
        self.onClose = onClose
        let window = CaptureWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 330),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Dictation Shortcut"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.capture = { [weak self] event in self?.capture(event) ?? false }
        let heading = NSTextField(labelWithString: "Dictation shortcut")
        heading.font = .systemFont(ofSize: 26, weight: .medium)
        let intro = NSTextField(wrappingLabelWithString: "Choose a key, a modifier key, or a key combination.")
        recordButton.target = self
        recordButton.action = #selector(beginRecording)
        recordButton.font = .systemFont(ofSize: 22, weight: .medium)
        recordButton.heightAnchor.constraint(equalToConstant: 58).isActive = true
        recordButton.setAccessibilityLabel("Dictation shortcut. Click to record a new key or combination.")
        hint.textColor = .secondaryLabelColor
        hint.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        let paused = NSTextField(labelWithString: "Dictation is paused while this window is open.")
        paused.font = .systemFont(ofSize: 12)
        paused.textColor = .secondaryLabelColor
        let reset = NSButton(title: "Use Fn / Globe", target: self, action: #selector(useDefault))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [reset, spacer, cancel, saveButton])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [heading, intro, recordButton, hint, paused, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 23),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            recordButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        recorder.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func refresh() {
        recordButton.title = recorder.isRecording ? "Press a key or combination…" : recorder.draft?.displayName ?? "Fn / Globe"
        hint.stringValue = recorder.hint
        saveButton.isEnabled = recorder.canSave
    }

    func capture(_ event: NSEvent) -> Bool {
        guard recorder.isRecording else { return false }
        let kind: TapSample.Kind
        switch event.type {
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        case .flagsChanged: kind = .flagsChanged
        default: return false
        }
        recorder.receive(TapSample(kind: kind, keyCode: event.keyCode, flags: UInt64(event.modifierFlags.rawValue), timestamp: 0,
            isAutorepeat: kind == .keyDown && event.isARepeat), keyName: kind == .keyDown ? event.charactersIgnoringModifiers : nil)
        return true
    }

    @objc private func beginRecording() { recorder.begin() }
    @objc private func useDefault() { recorder.useDefault() }
    @objc private func cancel() { close() }
    @objc private func save() { if recorder.save(apply) { close() } }
    func windowDidResignKey(_ notification: Notification) { recorder.cancelRecording() }
    func windowWillClose(_ notification: Notification) {
        recorder.cancelRecording()
        onClose()
    }
}

@MainActor private final class CaptureWindow: NSWindow {
    var capture: ((NSEvent) -> Bool)?
    override func sendEvent(_ event: NSEvent) {
        if capture?(event) == true { return }
        super.sendEvent(event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        capture?(event) == true || super.performKeyEquivalent(with: event)
    }
}
