import AppKit
import SwiftUI

// Shared redesign components ("Components as drawn" in the handoff). Page code reuses these instead of inventing its own:
//
//   DesignPage            scrolling page body: serif headline + summary over stacked sections, 32 pt side margins
//   DesignPageHeader      the serif headline (28, or 24 in the Settings modal) and one summary line
//   DesignSection         eyebrow label over a card, with an optional footer note
//   DesignEyebrow         JetBrains Mono 10 uppercase label, .12em tracking
//   DesignCard            surface, 1 pt hair2 border, radius 12; puts a hairline between its rows automatically
//   DesignRow             48 pt minimum row: title and detail left, controls right, wraps instead of truncating
//   DesignSwitchStyle     42x24 switch (36x20 compact): `.toggleStyle(.designSwitch)`
//   DesignPopup           28 pt popup, radius 7, with checkmarked menu
//   DesignSegmented       segmented control on c0 with a surface selected pill, optional colour dots
//   DesignKbd             key cap in JetBrains Mono on the key colour
//   DesignButtonStyle     primary (accent) and secondary (surface + hair border): `.buttonStyle(.designPrimary)`
//   DesignNavRow          34 pt sidebar / modal-nav row, radius 8, selected on the sel tint
//   DesignCloseButton     the 28 pt round close control for modals
//
// Colours come from DesignPalette, type from DesignFont, navigation icons as SF Symbols. Text wraps or grows the container, never
// truncates. Every control takes an explicit accessibility title.

// MARK: Layout

/// Hairline between card rows.
struct DesignHairline: View {
    var body: some View { Rectangle().fill(DesignPalette.hair2).frame(height: 1) }
}

struct DesignCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder var content: () -> Content

    var body: some View {
        Group(subviews: content()) { rows in
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { index in
                    if index > 0 { DesignHairline() }
                    rows[index]
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Row hover and selection fills are square, so the card shape clips them at the corners.
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DesignPalette.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DesignPalette.hair2, lineWidth: 1))
        .shadow(color: DesignPalette.shadowColor(dark: scheme == .dark), radius: 0.5, y: 1)
    }
}

struct DesignEyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).designEyebrow().padding(.leading, 4).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
    }
}

/// An eyebrow over a card of rows, with an optional footer note.
struct DesignSection<Content: View>: View {
    let eyebrow: String
    var footer: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DesignEyebrow(eyebrow)
            DesignCard(content: content)
            if let footer {
                Text(footer).font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
        }
    }
}

/// One row of a card. Controls sit on the right; when they don't fit beside the label they wrap below it.
struct DesignRow<Controls: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var controls: () -> Controls

    private var label: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(DesignFont.sans(DesignFont.body, .medium)).foregroundStyle(DesignPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let detail, !detail.isEmpty {
                Text(detail).font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var trailing: some View { HStack(spacing: 8) { controls() } }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                label.frame(minWidth: 180, idealWidth: 180, maxWidth: .infinity, alignment: .leading)
                trailing.layoutPriority(1)
            }
            VStack(alignment: .leading, spacing: 8) {
                label.frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(minHeight: 48)
    }
}

struct DesignPageHeader<Trailing: View>: View {
    let title: String
    var summary: String?
    var titleSize: CGFloat = DesignFont.headline
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(DesignFont.serif(titleSize)).foregroundStyle(DesignPalette.ink)
                    .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                if let summary {
                    Text(summary).font(DesignFont.sans(DesignFont.body)).foregroundStyle(DesignPalette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
    }
}

extension DesignPageHeader where Trailing == EmptyView {
    init(title: String, summary: String? = nil, titleSize: CGFloat = DesignFont.headline) {
        self.init(title: title, summary: summary, titleSize: titleSize) { EmptyView() }
    }
}

/// A scrolling page: header, then sections 18 pt apart. Old `SettingsForm` pages hosted inside it stop scrolling on their own.
struct DesignPage<Trailing: View, Content: View>: View {
    let title: String
    var summary: String?
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DesignPageHeader(title: title, summary: summary, trailing: trailing)
                content()
            }
            .padding(.horizontal, 32).padding(.top, 40).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(\.settingsFormScrolls, false)
        .background(DesignPalette.bg)
    }
}

extension DesignPage where Trailing == EmptyView {
    init(title: String, summary: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, summary: summary, trailing: { EmptyView() }, content: content)
    }
}

// MARK: Controls

/// 42x24 switch, or 36x20 compact. A button underneath, so Space toggles it under Full Keyboard Access; VoiceOver sees a native toggle.
struct DesignSwitchStyle: ToggleStyle {
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let width: CGFloat = compact ? 36 : 42, height: CGFloat = compact ? 20 : 24, knob = height - 4
        Button { configuration.isOn.toggle() } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? DesignPalette.accent : DesignPalette.track)
                Circle().fill(Color.white).frame(width: knob, height: knob).shadow(color: .black.opacity(0.25), radius: 0.5, y: 1).padding(2)
            }
            .frame(width: width, height: height)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

extension ToggleStyle where Self == DesignSwitchStyle {
    static var designSwitch: DesignSwitchStyle { DesignSwitchStyle() }
    static var designSwitchCompact: DesignSwitchStyle { DesignSwitchStyle(compact: true) }
}

/// One choice for `DesignPopup` and `DesignSegmented`.
struct DesignChoice<Value: Hashable>: Identifiable {
    let label: String
    let value: Value
    var dot: Color?
    var id: String { label }
    init(_ label: String, _ value: Value, dot: Color? = nil) { self.label = label; self.value = value; self.dot = dot }
}

/// 28 pt popup, radius 7. `title` is the accessibility label; the current choice is its value.
struct DesignPopup<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let choices: [DesignChoice<Value>]

    private var current: String { choices.first { $0.value == selection }?.label ?? "" }

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(choices) { Text($0.label).tag($0.value) }
            }.pickerStyle(.inline).labelsHidden()
        } label: {
            HStack(spacing: 8) {
                Text(current).font(DesignFont.sans(DesignFont.detail)).foregroundStyle(DesignPalette.ink)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(DesignPalette.ink2)
            }
            .padding(.leading, 10).padding(.trailing, 8).frame(minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(DesignPalette.surface))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(DesignPalette.hair, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(title).accessibilityValue(current)
    }
}

/// Segmented control on c0 with a surface selected pill. Left and right arrows move the selection when a segment has focus.
struct DesignSegmented<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let choices: [DesignChoice<Value>]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(choices) { choice in
                let selected = choice.value == selection
                Button { selection = choice.value } label: {
                    HStack(spacing: 6) {
                        if let dot = choice.dot { Circle().fill(dot).frame(width: 9, height: 9) }
                        Text(choice.label).font(DesignFont.sans(DesignFont.detail, selected ? .medium : .regular))
                            .foregroundStyle(selected ? DesignPalette.ink : DesignPalette.ink2).fixedSize()
                    }
                    .padding(.horizontal, 12).frame(minHeight: 24)
                    .background { if selected { RoundedRectangle(cornerRadius: 6).fill(DesignPalette.surface).shadow(color: .black.opacity(0.12), radius: 0.5, y: 1) } }
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice.label).accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(DesignPalette.sel))
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        .accessibilityElement(children: .contain).accessibilityLabel(title)
    }

    private func step(_ offset: Int) -> KeyPress.Result {
        guard let index = choices.firstIndex(where: { $0.value == selection }) else { return .ignored }
        let next = min(max(index + offset, 0), choices.count - 1)
        selection = choices[next].value
        return .handled
    }
}

struct DesignKbd: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(DesignFont.mono(DesignFont.detail)).foregroundStyle(DesignPalette.ink).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(DesignPalette.hair).offset(y: 1)
                    RoundedRectangle(cornerRadius: 6).fill(DesignPalette.key)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DesignPalette.hair, lineWidth: 1))
            .accessibilityLabel(text)
    }
}

/// Primary (accent fill) and secondary (surface with a hair border) buttons, 28 pt high, radius 7.
struct DesignButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    var kind: Kind = .secondary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7)
        configuration.label
            .font(DesignFont.sans(DesignFont.detail, .medium))
            .foregroundStyle(kind == .primary ? DesignPalette.onAccent : DesignPalette.ink)
            .padding(.horizontal, 10).frame(minHeight: 28)
            .background(shape.fill(kind == .primary ? DesignPalette.accent : DesignPalette.surface))
            .overlay { if kind == .secondary { shape.strokeBorder(DesignPalette.hair, lineWidth: 1) } }
            .overlay { if configuration.isPressed { shape.fill(Color.black.opacity(0.1)) } }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
    }
}

extension ButtonStyle where Self == DesignButtonStyle {
    static var designPrimary: DesignButtonStyle { DesignButtonStyle(kind: .primary) }
    static var designSecondary: DesignButtonStyle { DesignButtonStyle(kind: .secondary) }
}

// MARK: Navigation

/// A navigation row: SF Symbol, title, selected on the sel tint. Sidebar and modal-nav rows share the native sidebar sizing, a 16 pt regular monochrome symbol in a 34 pt row.
struct DesignNavRow: View {
    let title: String
    let symbol: String
    var selected = false
    var height: CGFloat = 34
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).symbolRenderingMode(.monochrome).font(.system(size: 16, weight: .regular))
                    .foregroundStyle(selected ? DesignPalette.ink : DesignPalette.ink2).frame(width: 20).accessibilityHidden(true)
                Text(title).font(DesignFont.sans(DesignFont.body, .medium)).foregroundStyle(DesignPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(minHeight: height)
            .background { if selected { RoundedRectangle(cornerRadius: 8).fill(DesignPalette.sel) } }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The round close control in a modal's corner.
struct DesignCloseButton: View {
    var label = "Close"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(DesignPalette.ink2)
                .frame(width: 28, height: 28).background(Circle().fill(DesignPalette.sel)).contentShape(Circle())
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }
}
