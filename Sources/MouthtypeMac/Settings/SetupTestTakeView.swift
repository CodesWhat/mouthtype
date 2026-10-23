import AppKit
import MouthtypeCore
import SwiftUI

/// "Try a test take" on Setup's last card: one short recording, the transcript and the input level. Nothing is pasted.
struct SetupTestTakeView: View {
    var take: SetupTestTake

    var body: some View {
        VStack(spacing: 8) {
            switch take.state {
            case .idle:
                Button("Try a test take", action: take.start).buttonStyle(.designSecondary)
                    .accessibilityIdentifier("setup-test-take")
                note("Optional. Records a few seconds here. Nothing is pasted or saved.")
            case .recording:
                SetupProgressBar(fraction: take.level).frame(maxWidth: 240)
                    .accessibilityHidden(true)
                note("Say something. Listening…")
                Button("Stop", action: take.stop).buttonStyle(.designSecondary)
                    .accessibilityIdentifier("setup-test-take-stop")
            case .transcribing:
                ProgressView().controlSize(.small).accessibilityLabel("Transcribing the test take")
            case let .finished(outcome):
                result(outcome)
            case let .failed(message):
                Text(message).font(DesignFont.sans(DesignFont.detail)).foregroundStyle(DesignPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again", action: take.reset).buttonStyle(.designSecondary)
            }
        }
        .frame(maxWidth: 320)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup-test-take-panel")
    }

    @ViewBuilder private func result(_ outcome: SetupTestTake.Outcome) -> some View {
        let mic = outcome.micName.flatMap { $0.isEmpty ? nil : $0 } ?? "your microphone"
        if outcome.heardSpeech {
            Text("\u{201C}\(outcome.transcript)\u{201D}").font(DesignFont.sans(DesignFont.body)).foregroundStyle(DesignPalette.ink)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .accessibilityIdentifier("setup-test-take-transcript")
        } else {
            Text(outcome.kind == .noSignal ? "Nothing came in from \(mic)." : "\(mic) picked up sound but no speech.")
                .font(DesignFont.sans(DesignFont.body, .medium)).foregroundStyle(DesignPalette.danger)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("setup-test-take-silent")
            Button("Open Sound settings…") { NSWorkspace.shared.open(DictationController.soundSettingsURL) }
                .buttonStyle(.designSecondary)
        }
        note("Input peak \(Int(outcome.peakDb.rounded())) dB from \(mic).")
        Button("Try again", action: take.reset).buttonStyle(.designSecondary)
            .accessibilityIdentifier("setup-test-take-again")
    }

    private func note(_ text: String) -> some View {
        Text(text).font(DesignFont.sans(DesignFont.detail)).foregroundStyle(DesignPalette.sideInk)
            .fixedSize(horizontal: false, vertical: true)
    }
}
