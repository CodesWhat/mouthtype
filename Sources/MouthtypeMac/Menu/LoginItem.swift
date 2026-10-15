// Adapted from Parrot (https://github.com/humanitas-labs/parrot, 0eb4708), MIT License, Copyright (c) 2026 Humanitas Labs.
import AppKit
import ServiceManagement

/// The login-item calls the menu needs. `SMAppService.mainApp` in the app, a fake in tests.
@MainActor
protocol LoginItemService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
final class SystemLoginItemService: LoginItemService {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Launch at login through `SMAppService.mainApp`: macOS starts the app itself at login and lists it under
/// System Settings, General, Login Items. Needs the signed bundle; a bare `swift build` binary has none.
@MainActor
final class LoginItem {
    private let service: any LoginItemService

    init(service: any LoginItemService = SystemLoginItemService()) {
        self.service = service
    }

    /// On and waiting for approval both read as checked; approval shows as a dash.
    var menuState: NSControl.StateValue { Self.menuState(for: service.status) }

    static func menuState(for status: SMAppService.Status) -> NSControl.StateValue {
        switch status {
        case .enabled: .on
        case .requiresApproval: .mixed
        case .notRegistered, .notFound: .off
        @unknown default: .off
        }
    }

    /// A click on the menu item. Waiting for approval opens Login Items instead of toggling.
    func toggle() {
        switch service.status {
        case .requiresApproval:
            service.openSystemSettings()
        case .enabled:
            attempt("unregister") { try service.unregister() }
        case .notRegistered, .notFound:
            attempt("register") { try service.register() }
            if service.status == .requiresApproval { service.openSystemSettings() }
        @unknown default:
            break
        }
    }

    private func attempt(_ label: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            Log.app.error("login item \(label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }
}
