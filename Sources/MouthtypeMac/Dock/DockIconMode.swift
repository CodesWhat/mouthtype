import AppKit

/// When Mouthtype shows in the Dock. The menu bar icon is there in every mode.
enum DockIconMode: String, CaseIterable, Sendable {
    case never
    case whileWindowOpen
    case always

    static let key = "dockIconMode"
    static let fallback = DockIconMode.whileWindowOpen

    /// A missing or unrecognized value is the default, so existing users land on it without a migration.
    static func current(_ defaults: UserDefaults = .standard) -> DockIconMode {
        defaults.string(forKey: key).flatMap(DockIconMode.init(rawValue:)) ?? fallback
    }

    static func set(_ mode: DockIconMode, in defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: key)
    }

    var label: String {
        switch self {
        case .never: "Never"
        case .whileWindowOpen: "While a window is open"
        case .always: "Always"
        }
    }

    /// The activation policy for this mode given what is on screen. Only real windows count: a floating panel such as
    /// Transform Selection never brings the Dock icon up.
    func policy(windows: [DockWindowFacts]) -> NSApplication.ActivationPolicy {
        switch self {
        case .never: .accessory
        case .always: .regular
        case .whileWindowOpen: windows.contains(where: \.countsForDock) ? .regular : .accessory
        }
    }
}

/// What the Dock decision needs to know about one window.
struct DockWindowFacts: Equatable, Sendable {
    var isVisible: Bool
    var isMiniaturized = false
    var isPanel = false
    var canBecomeMain = true
    var isClosing = false

    /// A miniaturized window still has a Dock tile, so it counts until it closes.
    var countsForDock: Bool { !isClosing && !isPanel && canBecomeMain && (isVisible || isMiniaturized) }

    @MainActor init(_ window: NSWindow, closing: NSWindow? = nil) {
        self.init(
            isVisible: window.isVisible, isMiniaturized: window.isMiniaturized, isPanel: window is NSPanel,
            canBecomeMain: window.canBecomeMain, isClosing: window === closing)
    }

    init(isVisible: Bool, isMiniaturized: Bool = false, isPanel: Bool = false, canBecomeMain: Bool = true, isClosing: Bool = false) {
        self.isVisible = isVisible
        self.isMiniaturized = isMiniaturized
        self.isPanel = isPanel
        self.canBecomeMain = canBecomeMain
        self.isClosing = isClosing
    }
}
