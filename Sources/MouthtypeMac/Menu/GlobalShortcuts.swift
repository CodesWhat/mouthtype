import AppKit
import Carbon.HIToolbox

/// System-wide key shortcuts through Carbon `RegisterEventHotKey`, which needs no extra permissions.
@MainActor
final class GlobalShortcuts {
    struct Shortcut: Equatable {
        var keyCode: Int
        var modifiers: Int

        static let pasteLast = Shortcut(keyCode: kVK_ANSI_V, modifiers: cmdKey | controlKey)
        static let copyLast = Shortcut(keyCode: kVK_ANSI_C, modifiers: cmdKey | controlKey)
    }

    private static let signature: OSType = 0x4D54_5950  // 'MTYP'

    private var actions: [UInt32: @MainActor () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1

    /// False when the system refused the combination (another app holds it).
    @discardableResult
    func register(_ shortcut: Shortcut, action: @escaping @MainActor () -> Void) -> Bool {
        installHandlerIfNeeded()
        let id = nextID
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode), UInt32(shortcut.modifiers), EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else {
            Log.app.error("global shortcut \(shortcut.keyCode, privacy: .public) not registered: \(status, privacy: .public)")
            return false
        }
        nextID += 1
        refs.append(ref)
        actions[id] = action
        return true
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        actions = [:]
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }

    fileprivate func fire(_ id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(), hotKeyCallback, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler
        )
    }
}

private let hotKeyCallback: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
        MemoryLayout<EventHotKeyID>.size, nil, &id
    )
    guard status == noErr else { return status }
    let shortcuts = Unmanaged<GlobalShortcuts>.fromOpaque(userData)
    MainActor.assumeIsolated { shortcuts.takeUnretainedValue().fire(id.id) }
    return noErr
}
