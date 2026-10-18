import SwiftUI
import MouthtypeCore

struct AudioRetentionSection: View {
    let model: SettingsModel

    var body: some View {
        SettingsGroup(eyebrow: "SAVED AUDIO",
            footer: "The oldest completed recordings are removed when either limit is reached. Changes apply to existing recordings the next time Mouthtype launches. Text and word timings stay unchanged. Unfinished recordings and audio kept for recovery are separate and aren't removed by these limits.") {
            SettingsRow(title: "Keep completed recordings") {
                Picker("Keep completed recordings", selection: Binding(get: { model.audioRetention.age }, set: model.setAudioRetentionAge)) {
                    Text("14 days").tag(AudioRetentionAge.days14)
                    Text("30 days").tag(AudioRetentionAge.days30)
                    Text("90 days").tag(AudioRetentionAge.days90)
                    Text("No age limit").tag(AudioRetentionAge.noAgeLimit)
                }.labelsHidden().fixedSize().accessibilityIdentifier("settings-audio-age")
            }
            SettingsRow(title: "Completed audio size limit") {
                Picker("Completed audio size limit", selection: Binding(get: { model.audioRetention.size }, set: model.setAudioRetentionSize)) {
                    Text("2 GB").tag(AudioRetentionSize.gb2)
                    Text("10 GB").tag(AudioRetentionSize.gb10)
                }.labelsHidden().fixedSize().accessibilityIdentifier("settings-audio-size")
            }
        }
    }
}
