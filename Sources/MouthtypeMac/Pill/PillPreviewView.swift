import AppKit

/// A noninteractive provisional readout above either existing skin.
@MainActor
final class PillPreviewView: NSView {
    private let heading = NSTextField(labelWithString: "PREVIEW · MAY CHANGE")
    private let words = NSTextField(wrappingLabelWithString: "")
    private(set) var visibleText = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(hex: 0x1A1A1A).withAlphaComponent(0.96).cgColor
        layer?.cornerRadius = 10
        heading.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
        heading.textColor = .white.withAlphaComponent(0.6)
        words.font = Typography.current().font(.body)
        words.textColor = .white
        words.lineBreakMode = .byWordWrapping
        words.setAccessibilityLabel("Provisional dictation preview, may change")
        addSubview(heading)
        addSubview(words)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func applyTypography(_ typography: Typography) {
        words.font = typography.font(.body)
        update(visibleText)
    }

    func update(_ text: String) {
        let candidate = String(text.suffix(LivePreviewSession.maximumCharacters))
        let available = NSSize(width: bounds.width - 24, height: bounds.height - 36)
        let attributes: [NSAttributedString.Key: Any] = [.font: words.font!]
        func fits(_ count: Int) -> Bool {
            let size = NSAttributedString(string: String(candidate.suffix(count)), attributes: attributes).boundingRect(with: NSSize(width: available.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).size
            return ceil(size.height) <= available.height && ceil(size.width) <= available.width
        }
        var low = 0
        var high = candidate.count
        while low < high {
            let middle = (low + high + 1) / 2
            if fits(middle) { low = middle } else { high = middle - 1 }
        }
        visibleText = String(candidate.suffix(low))
        words.stringValue = visibleText
        isHidden = visibleText.isEmpty
        needsLayout = true
    }

    override func layout() {
        super.layout()
        heading.frame = NSRect(x: 12, y: bounds.height - 23, width: bounds.width - 24, height: 14)
        words.frame = NSRect(x: 12, y: 10, width: bounds.width - 24, height: bounds.height - 36)
    }
}
