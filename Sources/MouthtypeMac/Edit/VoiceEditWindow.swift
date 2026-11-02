import AppKit
import SwiftUI

@MainActor final class VoiceEditWindow: NSWindowController, NSWindowDelegate {
    let model: VoiceEditCoordinator
    private let maximumContentHeight: CGFloat
    private(set) var flowTask: Task<Void, Never>?

    init(model: VoiceEditCoordinator, maximumContentHeight: CGFloat? = nil) {
        self.model = model
        self.maximumContentHeight = max(260, min(560, maximumContentHeight ?? ((NSScreen.main?.visibleFrame.height ?? 684) - 64)))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Edit Selection by Voice"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        super.init(window: panel)
        panel.delegate = self
        panel.contentView = NSHostingView(
            rootView: VoiceEditView(
                model: model, maximumContentHeight: self.maximumContentHeight,
                close: { [weak self] in self?.close() }, resize: { [weak self] in self?.resizeToFitContent() }))
        resizeToFitContent()
        panel.center()
    }

    required init?(coder: NSCoder) { nil }

    /// Opens the panel and starts the flow. The original app keeps activation so Accept can check its exact selection.
    func present() {
        guard !model.phase.isActive else {
            window?.orderFrontRegardless()
            return
        }
        flowTask?.cancel()
        window?.orderFrontRegardless()
        flowTask = Task { [weak self] in
            guard let self else { return }
            await model.begin()
            resizeToFitContent()
        }
    }

    func windowWillClose(_ notification: Notification) {
        flowTask?.cancel()
        flowTask = nil
        Task { [model] in await model.cancel() }
    }

    private func resizeToFitContent() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let fitting = content.fittingSize
        window.setContentSize(NSSize(width: fitting.width, height: min(maximumContentHeight, fitting.height)))
    }
}

struct VoiceEditView: View {
    var model: VoiceEditCoordinator
    var maximumContentHeight: CGFloat
    var close: () -> Void
    var resize: () -> Void
    private static let bodySize: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(.horizontal, 24).padding(.vertical, 20).frame(width: 480)
        .background(DesignPalette.bg)
        .onChange(of: model.phase) { resize() }
        .onChange(of: model.replacement) { resize() }
        .onExitCommand(perform: cancel)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .readingSelection:
            status("Reading the selection.", detail: nil)
            buttons(cancelTitle: "Cancel")
        case .recording:
            status(
                "Listening. Say how to change the selected text.",
                detail: "For example: make it shorter, or rephrase it more formally.")
            buttons(cancelTitle: "Cancel") {
                Button("Done") { Task { await model.stopRecording() } }.buttonStyle(.designPrimary)
                    .accessibilityLabel("Done speaking").accessibilityIdentifier("voice-edit-done")
            }
        case .transcribing:
            status("Transcribing your instruction.", detail: nil)
            buttons(cancelTitle: "Cancel")
        case .generating:
            status("Editing on the local model.", detail: "Nothing leaves this Mac.")
            buttons(cancelTitle: "Cancel")
        case .preview:
            preview
        case let .ended(outcome):
            ended(outcome)
        }
    }

    private func status(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(DesignFont.sans(Self.bodySize, .medium)).foregroundStyle(DesignPalette.ink)
            if let detail { Text(detail).font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2) }
        }
        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine).accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("voice-edit-status")
    }

    @ViewBuilder private var preview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("You said").designEyebrow()
            Text(model.instruction).font(DesignFont.sans(Self.bodySize)).foregroundStyle(DesignPalette.ink)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Instruction: \(model.instruction)").accessibilityIdentifier("voice-edit-instruction")
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("Replacement").designEyebrow()
            ScrollView {
                Text(model.replacement).font(DesignFont.sans(Self.bodySize)).foregroundStyle(DesignPalette.ink)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 6)
            }
            .frame(height: replacementHeight)
            .background(DesignPalette.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesignPalette.hair, lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Replacement text").accessibilityValue(model.replacement)
            .accessibilityIdentifier("voice-edit-replacement")
        }
        Text("Nothing changes until you accept. The original stays if you cancel.")
            .font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2)
        buttons(cancelTitle: "Cancel") {
            Button("Accept", action: model.accept).buttonStyle(.designPrimary)
                .keyboardShortcut(.defaultAction).disabled(!model.canAccept)
                .accessibilityIdentifier("voice-edit-accept")
        }
    }

    @ViewBuilder private func ended(_ outcome: VoiceEditEnd) -> some View {
        Text(outcome.message)
            .font(DesignFont.sans(DesignFont.detail, .medium)).foregroundStyle(DesignPalette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
            .background(
                (outcome.isFailure ? DesignPalette.orange : DesignPalette.accentMark).opacity(0.16),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder((outcome.isFailure ? DesignPalette.orange : DesignPalette.accentMark).opacity(0.55), lineWidth: 1)
            )
            .accessibilityElement(children: .combine).accessibilityIdentifier("voice-edit-ended")
        HStack {
            Spacer(minLength: 0)
            Button("Close", action: close).buttonStyle(.designPrimary).keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("voice-edit-close")
        }
    }

    private func buttons<Extra: View>(cancelTitle: String, @ViewBuilder extra: () -> Extra) -> some View {
        HStack(spacing: 8) {
            Button(cancelTitle, action: cancel).buttonStyle(.designSecondary)
                .keyboardShortcut(.cancelAction).accessibilityIdentifier("voice-edit-cancel")
            Spacer(minLength: 0)
            extra()
        }.padding(.top, 2)
    }

    private func buttons(cancelTitle: String) -> some View { buttons(cancelTitle: cancelTitle) { EmptyView() } }

    private func cancel() {
        Task {
            await model.cancel()
            close()
        }
    }

    private var replacementHeight: CGFloat {
        let bounds = NSAttributedString(
            string: model.replacement + " ", attributes: [.font: NSFont.systemFont(ofSize: Self.bodySize)]
        ).boundingRect(
            with: NSSize(width: 432, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return min(max(44, (maximumContentHeight - 220)), max(44, ceil(bounds.height) + 20))
    }
}
