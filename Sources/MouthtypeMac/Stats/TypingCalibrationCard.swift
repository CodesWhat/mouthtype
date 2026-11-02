import AppKit
import MouthtypeCore
import SwiftUI

/// The typing speed the time-saved numbers compare against, with an explicit way to measure it. Nothing runs until Start, the
/// text typed is never kept, and nothing is sent anywhere. The accepted speed is the only thing stored.
struct TypingCalibrationCard: View {
    var model: TypingCalibrationModel
    @FocusState private var fieldFocused: Bool

    private var baselineText: String {
        let wpm = Int(model.baseline)
        return model.isCustomBaseline ? "\(wpm) words per minute, from your own typing." : "\(wpm) words per minute, the default."
    }

    var body: some View {
        DesignSection(
            eyebrow: "TYPING SPEED",
            footer: "Time saved is worked out against this speed. Worked out on this Mac. What you type here is not saved."
        ) {
            VStack(alignment: .leading, spacing: 0) {
                DesignRow(title: "Your typing speed", detail: baselineText) {
                    if model.isCustomBaseline {
                        Button("Reset to \(Int(TypingBaselinePreference.defaultWPM))") { model.reset() }
                            .buttonStyle(.designSecondary).fixedSize()
                            .accessibilityLabel("Reset typing speed to the default of \(Int(TypingBaselinePreference.defaultWPM)) words per minute")
                            .accessibilityIdentifier("typing-reset")
                    }
                    Button(model.isOpen ? "Close" : "Calibrate") { model.isOpen ? model.close() : model.open() }
                        .buttonStyle(.designSecondary).fixedSize()
                        .accessibilityLabel(model.isOpen ? "Close the typing calibration" : "Open the one minute typing calibration")
                        .accessibilityIdentifier("typing-calibrate")
                }
                if model.isOpen {
                    Divider().overlay(DesignPalette.hair)
                    exercise.padding(14)
                }
            }
        }
        .onDisappear { model.close() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in model.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in model.cancel() }
    }

    private var exercise: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(TypingCalibrationModel.passage)
                .font(DesignFont.sans(DesignFont.body)).foregroundStyle(DesignPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Passage to type: \(TypingCalibrationModel.passage)")
            TextField("Type the passage above", text: typedText, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(3...6)
                .autocorrectionDisabled()
                .focused($fieldFocused)
                .disabled(!model.calibration.isActive)
                .accessibilityLabel("Type the passage above")
                .accessibilityHint("The clock starts on your first key.")
                .accessibilityIdentifier("typing-field")
                .onExitCommand { model.cancel() }
            Text(hint).font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            readout
            HStack(spacing: 8) { buttons }
        }
    }

    /// Typing only counts while the field has focus, so the clock can't start from anywhere else.
    private var typedText: Binding<String> {
        Binding(
            get: { model.text },
            set: { if fieldFocused { model.text = $0 } })
    }

    private var hint: String {
        switch model.phase {
        case .idle: "Press Start, then type the passage. The clock starts on your first key and runs for one minute."
        case .ready: "Type in the box. The clock starts on your first key."
        case .running: "Keep typing. Press Stop to score what you have, or Escape to throw the run away."
        case .finished: "Use this result to make it your typing speed, or Retry. Your current speed stays until you do."
        case .tooShort: "Too short to score. Retry and keep going for at least ten seconds."
        case .cancelled: "Stopped, with no result. Your current speed is unchanged."
        }
    }

    @ViewBuilder private var readout: some View {
        if let result = model.result {
            let summary = "\(result.roundedWPM) words per minute, \(result.errorCharacters) \(result.errorCharacters == 1 ? "error" : "errors") left in the text"
            VStack(alignment: .leading, spacing: 2) {
                Text("\(result.roundedWPM) WPM").font(DesignFont.serif(DesignFont.display)).foregroundStyle(DesignPalette.ink)
                Text("\(result.errorCharacters) \(result.errorCharacters == 1 ? "error" : "errors") left in the text. Five characters count as a word.")
                    .font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore).accessibilityLabel("Result: \(summary)")
        } else if model.calibration.isActive {
            let seconds = Int(model.remaining.rounded(.up))
            let errors = model.calibration.errorCharacters
            Text("\(seconds) seconds left. \(errors) \(errors == 1 ? "error" : "errors") so far.")
                .font(DesignFont.mono(DesignFont.detail)).foregroundStyle(DesignPalette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("\(seconds) seconds left, \(errors) \(errors == 1 ? "error" : "errors") so far")
        }
    }

    @ViewBuilder private var buttons: some View {
        switch model.phase {
        case .idle, .cancelled, .tooShort:
            Button("Start") {
                model.start()
                fieldFocused = true
            }
            .buttonStyle(.designPrimary).fixedSize()
            .accessibilityLabel("Start the one minute typing test")
            .accessibilityIdentifier("typing-start")
            if model.phase != .idle {
                Button("Retry") { model.retry() }.buttonStyle(.designSecondary).fixedSize()
                    .accessibilityLabel("Retry the typing test").accessibilityIdentifier("typing-retry")
            }
        case .ready, .running:
            Button("Stop") { model.stop() }.buttonStyle(.designPrimary).fixedSize()
                .disabled({ if case .running = model.phase { false } else { true } }())
                .accessibilityLabel("Stop and score the typing test").accessibilityIdentifier("typing-stop")
            Button("Cancel") { model.cancel() }.buttonStyle(.designSecondary).fixedSize()
                .accessibilityLabel("Cancel the typing test with no result").accessibilityIdentifier("typing-cancel")
        case .finished:
            Button("Use this result") { model.accept() }.buttonStyle(.designPrimary).fixedSize()
                .accessibilityLabel("Use this result as your typing speed").accessibilityIdentifier("typing-accept")
            Button("Retry") { model.retry() }.buttonStyle(.designSecondary).fixedSize()
                .accessibilityLabel("Retry the typing test").accessibilityIdentifier("typing-retry")
        }
    }
}
