import AppKit
import MouthtypeCore
import SwiftUI

@MainActor final class SelectionCleanupWindow: NSWindowController, NSWindowDelegate {
    let model: SelectionCleanupModel
    private let maximumContentHeight: CGFloat

    init(model: SelectionCleanupModel, maximumContentHeight: CGFloat? = nil) {
        self.model = model
        self.maximumContentHeight = max(260, min(620, maximumContentHeight ?? ((NSScreen.main?.visibleFrame.height ?? 684) - 64)))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 300),
                            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Transform Selection"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        super.init(window: panel)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: SelectionCleanupView(model: model,
            maximumContentHeight: self.maximumContentHeight,
            close: { [weak self] in self?.close() }, resize: { [weak self] in self?.resizeToFitContent() }))
        resizeToFitContent()
        panel.center()
    }

    required init?(coder: NSCoder) { nil }

    func present(transform: TextTransform? = nil) {
        model.prepare(transform: transform)
        resizeToFitContent()
        // The original app keeps activation so Accept can check its exact selection.
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) { model.cancel() }

    private func resizeToFitContent() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let fitting = content.fittingSize
        window.setContentSize(NSSize(width: fitting.width, height: min(maximumContentHeight, fitting.height)))
    }
}

struct SelectionCleanupView: View {
    @Bindable var model: SelectionCleanupModel
    var maximumContentHeight: CGFloat
    var close: () -> Void
    var resize: () -> Void
    private var compact: Bool { maximumContentHeight < 420 }
    private static let bodySize: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 12) {
            if !compact {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(model.sourceApp.map { "Transform selection · from \($0)" } ?? "Transform selection").designEyebrow()
                    Spacer(minLength: 0)
                    Text("AI transforms run on this Mac").designEyebrow()
                }.fixedSize(horizontal: false, vertical: true)
            }
            chips
            if let reason = model.transformUnavailableReason {
                Text(reason).font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("selection-cleanup-unavailable")
            }
            VStack(alignment: .leading, spacing: 4) {
                if !compact { Text("Original").designEyebrow() }
                ScrollView {
                    Text(Self.originalText(model.original, result: model.result))
                        .font(DesignFont.sans(12.5)).foregroundStyle(DesignPalette.ink2).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: textHeight(model.original, width: 592, minimum: compact ? 18 : 22,
                                           maximum: max(22, min(120, (maximumContentHeight - 240) / 3))))
            }
            VStack(alignment: .leading, spacing: 4) {
                if !compact { Text("Result · edit it before you accept").designEyebrow() }
                TextEditor(text: resultBinding).font(DesignFont.sans(Self.bodySize)).foregroundStyle(DesignPalette.ink)
                    .scrollContentBackground(.hidden).disabled(!model.isEditable)
                    .frame(height: textHeight(model.result, width: 580, minimum: 44,
                                              maximum: max(44, min(240, (maximumContentHeight - 240) * 2 / 3 - 12))))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(DesignPalette.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesignPalette.hair, lineWidth: 1))
                    .accessibilityIdentifier("selection-cleanup-preview")
            }
            if model.refused {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.refusalTitle).font(DesignFont.sans(DesignFont.detail, .medium)).foregroundStyle(DesignPalette.ink)
                    if !compact {
                        Text(model.refusalDetail).font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2)
                    }
                }.fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, compact ? 6 : 10)
                    .background(DesignPalette.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesignPalette.orange.opacity(0.55), lineWidth: 1))
                    .accessibilityElement(children: .combine).accessibilityIdentifier("selection-cleanup-refused")
            } else if !model.message.isEmpty, model.message != model.transformUnavailableReason {
                Text(model.message).font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Cancel", action: close).buttonStyle(.designSecondary)
                if model.transform != nil {
                    Button("Retry", action: model.retry).buttonStyle(.designSecondary).disabled(!model.canRetry)
                        .accessibilityIdentifier("selection-cleanup-retry")
                }
                Spacer(minLength: 0)
                if model.submitted && model.transform != nil {
                    Button("Copy original", action: copyOriginal).buttonStyle(.designSecondary)
                }
                Button("Copy result", action: copyResult).buttonStyle(model.refused ? .designPrimary : .designSecondary)
                    .disabled(model.result.isEmpty || model.isTransforming)
                    .accessibilityIdentifier("selection-cleanup-copy")
                Button("Accept", action: model.accept).buttonStyle(model.refused ? .designSecondary : .designPrimary)
                    .disabled(!model.canAccept).accessibilityIdentifier("selection-cleanup-accept")
            }.padding(.top, 2)
        }.padding(.horizontal, 24).padding(.vertical, compact ? 12 : 20).frame(width: 640)
            .background(DesignPalette.bg)
            .onChange(of: model.result) { resize() }
            .onChange(of: model.message) { resize() }
            .onChange(of: model.refused) { resize() }
    }

    private var chips: some View {
        HStack(spacing: 6) {
            TransformChip(title: "Clean up", active: model.transform == nil, enabled: model.canChooseBasic,
                          action: model.chooseBasic)
            ForEach(TextTransform.allCases, id: \.self) { kind in
                TransformChip(title: kind.chipTitle, active: model.transform == kind, enabled: model.canChooseTransform) {
                    model.choose(kind)
                }
            }
        }
    }

    /// The result with added or changed characters highlighted. Edits write straight back to the model and the
    /// highlights are redrawn against the original.
    private var resultBinding: Binding<AttributedString> {
        Binding(
            get: { Self.resultText(model.result, original: model.original) },
            set: { model.result = String($0.characters) })
    }

    static func resultText(_ result: String, original: String) -> AttributedString {
        var text = AttributedString()
        for segment in SelectionDiff.result(result, original: original) {
            var run = AttributedString(segment.text)
            if segment.marked { run.backgroundColor = DesignPalette.c1 }
            text.append(run)
        }
        return text
    }

    static func originalText(_ original: String, result: String) -> AttributedString {
        var text = AttributedString()
        for segment in SelectionDiff.original(original, result: result) {
            var run = AttributedString(segment.text)
            if segment.marked {
                run.strikethroughStyle = .single
                run.foregroundColor = DesignPalette.ink3
            }
            text.append(run)
        }
        return text
    }

    private func copyOriginal() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.original, forType: .string)
    }

    private func copyResult() {
        SystemClipboard().write(model.result)
    }

    private func textHeight(_ text: String, width: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        let bounds = NSAttributedString(string: text + " ", attributes: [.font: NSFont.systemFont(ofSize: Self.bodySize)])
            .boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        return min(maximum, max(minimum, ceil(bounds.height) + 8))
    }
}

/// One transform choice. The active chip takes the soft accent; a disabled chip dims.
private struct TransformChip: View {
    var title: String
    var active: Bool
    var enabled: Bool
    var action: () -> Void

    var body: some View {
        Text(title).font(DesignFont.sans(12.5, .medium))
            .foregroundStyle(active ? DesignPalette.accentText : DesignPalette.ink2)
            .padding(.horizontal, 12).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 14).fill(active ? DesignPalette.accentSoft : DesignPalette.surface))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(active ? DesignPalette.accent : DesignPalette.hair, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .onTapGesture { if enabled { action() } }
            .opacity(enabled || active ? 1 : 0.45)
            .accessibilityElement(children: .ignore).accessibilityLabel(title)
            .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { if enabled { action() } }
    }
}
