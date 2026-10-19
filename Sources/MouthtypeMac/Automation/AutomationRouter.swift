import Foundation

/// The app's own actions, the same ones the menu and hotkeys use. The router holds no behavior of its own.
struct AutomationActions {
    var startDictation: @MainActor () -> Void
    var stopDictation: @MainActor () -> Void
    var toggleDictation: @MainActor () -> Void
    var cancelDictation: @MainActor () -> Void
    var copyLast: @MainActor () -> Void
    var pasteLast: @MainActor () -> Void
    var open: @MainActor (AutomationPage) -> Void
}

enum AutomationOutcome: Equatable {
    case performed(AutomationCommand)
    case rejected(AutomationParseError)
    case disabled(AutomationCommand)
}

@MainActor
struct AutomationRouter {
    /// Opt-in for everything that records, inserts or copies. A web page can open a `mouthtype://` link, so the default is off.
    static let enabledKey = "automationEnabled"

    let actions: AutomationActions
    let isEnabled: @MainActor () -> Bool

    init(actions: AutomationActions, defaults: UserDefaults = .standard) {
        self.actions = actions
        self.isEnabled = { defaults.bool(forKey: AutomationRouter.enabledKey) }
    }

    init(actions: AutomationActions, isEnabled: @escaping @MainActor () -> Bool) {
        self.actions = actions
        self.isEnabled = isEnabled
    }

    @discardableResult
    func handle(_ url: URL) -> AutomationOutcome {
        switch AutomationURL.parse(url) {
        case let .failure(error):
            Log.app.info("automation ignored: \(String(describing: error), privacy: .public)")
            return .rejected(error)
        case let .success(command):
            guard !command.needsOptIn || isEnabled() else {
                Log.app.info("automation \(command.verb, privacy: .public) refused: not enabled")
                return .disabled(command)
            }
            perform(command)
            return .performed(command)
        }
    }

    func perform(_ command: AutomationCommand) {
        switch command {
        case .start: actions.startDictation()
        case .stop: actions.stopDictation()
        case .toggle: actions.toggleDictation()
        case .cancel: actions.cancelDictation()
        case .copyLast: actions.copyLast()
        case .pasteLast: actions.pasteLast()
        case let .open(page): actions.open(page)
        }
    }
}
