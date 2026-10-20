import SwiftUI
import MouthtypeCore

/// Advanced: how long finished recordings are kept. Age and size are two popups on one row.
struct AudioRetentionSection: View {
    let model: SettingsModel

    var body: some View {
        DesignSection(eyebrow: "STORAGE",
            footer: "The oldest completed recordings are removed when either limit is reached. Changes apply to existing recordings the next time Mouthtype launches. Text and word timings stay unchanged. Unfinished recordings and audio kept for recovery are separate and aren't removed by these limits.") {
            DesignRow(title: "Keep finished audio for", detail: "Unfinished and recovery audio is kept regardless.") {
                DesignPopup(title: "Keep completed recordings", selection: Binding(get: { model.audioRetention.age }, set: model.setAudioRetentionAge),
                    choices: [DesignChoice("14 days", AudioRetentionAge.days14), DesignChoice("30 days", .days30),
                              DesignChoice("90 days", .days90), DesignChoice("No age limit", .noAgeLimit)])
                    .accessibilityIdentifier("settings-audio-age")
                DesignPopup(title: "Completed audio size limit", selection: Binding(get: { model.audioRetention.size }, set: model.setAudioRetentionSize),
                    choices: [DesignChoice("up to 2 GB", AudioRetentionSize.gb2), DesignChoice("up to 10 GB", .gb10)])
                    .accessibilityIdentifier("settings-audio-size")
            }
        }
    }
}
