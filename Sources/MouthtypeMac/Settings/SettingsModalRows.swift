import SwiftUI

/// A card row with one switch on the right, shared by the Settings modal pages. The switch carries the title as its accessibility label.
struct ModalToggleRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool
    var identifier: String?

    var body: some View {
        DesignRow(title: title, detail: detail) {
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.designSwitch)
                .accessibilityIdentifier(identifier ?? "")
        }
    }
}

/// A line of explanation or an error inside a card, padded like a row.
struct ModalCardNote: View {
    let text: String
    var tone: Color = DesignPalette.ink2

    var body: some View {
        Text(text).font(DesignFont.sans(DesignFont.caption)).foregroundStyle(tone)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Wraps an optional string as a popup choice list for enum-backed settings.
func modalChoices<Value: Hashable>(_ pairs: [(String, Value)]) -> [DesignChoice<Value>] { pairs.map { DesignChoice($0.0, $0.1) } }
