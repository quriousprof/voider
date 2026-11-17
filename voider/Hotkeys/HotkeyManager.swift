import Carbon.HIToolbox

/// Global hotkeys via Carbon `RegisterEventHotKey`, which swallows the key press
/// so it never reaches the focused app (and needs no Accessibility permission).
final class HotkeyManager {
    static let shared = HotkeyManager()

    var onAction: ((Action) -> Void)?

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var actions: [UInt32: Action] = [:]
    private var handlerInstalled = false
    private var nextID: UInt32 = 1

    /// Replaces all registered hotkeys. Returns a description of each binding that couldn't be registered.
    @discardableResult
    func register(_ bindings: [(action: Action, binding: KeyBinding)]) -> [String] {
        unregisterAll()
        installHandlerIfNeeded()

        var failures: [String] = []
        for (action, binding) in bindings {
            let id = nextID
            nextID += 1
            let hotKeyID = EventHotKeyID(signature: 0x5644_4552 /* 'VDER' */, id: id)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                hotKeyRefs.append(ref)
                actions[id] = action
            } else {
                failures.append("\(action) (error \(status))")
            }
        }
        return failures
    }

    func unregisterAll() {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs.removeAll()
        actions.removeAll()
    }

    fileprivate func fire(id: UInt32) {
        guard let action = actions[id] else { return }
        onAction?(action)
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, nil, nil)
        handlerInstalled = true
    }
}

private nonisolated func hotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
    )
    guard status == noErr else { return status }
    let id = hotKeyID.id
    Task { @MainActor in HotkeyManager.shared.fire(id: id) }
    return noErr
}
