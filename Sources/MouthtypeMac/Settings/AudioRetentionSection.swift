import SwiftUI
import MouthtypeCore

struct AudioRetentionSection: View {
    let model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Saved audio").font(.headline)
            HStack {
                Text("Keep completed recordings")
                Spacer()
                Picker("Keep completed recordings", selection: Binding(get: { model.audioRetention.age }, set: model.setAudioRetentionAge)) {
                    Text("14 days").tag(AudioRetentionAge.days14)
                    Text("30 days").tag(AudioRetentionAge.days30)
                    Text("90 days").tag(AudioRetentionAge.days90)
                    Text("No age limit").tag(AudioRetentionAge.noAgeLimit)
                }.labelsHidden().frame(width: 160).accessibilityIdentifier("settings-audio-age")
            }
            HStack {
                Text("Completed audio size limit")
                Spacer()
                Picker("Completed audio size limit", selection: Binding(get: { model.audioRetention.size }, set: model.setAudioRetentionSize)) {
                    Text("2 GB").tag(AudioRetentionSize.gb2)
                    Text("10 GB").tag(AudioRetentionSize.gb10)
                }.labelsHidden().frame(width: 160).accessibilityIdentifier("settings-audio-size")
            }
            Text("The oldest completed recordings are removed when either limit is reached. Changes apply to existing recordings the next time Mouthtype launches.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Text and word timings stay unchanged. Unfinished recordings and audio kept for recovery are separate and aren't removed by these limits.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
