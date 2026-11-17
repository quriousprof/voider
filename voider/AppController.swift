import AppKit
import Observation

/// Wires config, hotkeys and the window manager together.
@Observable
final class AppController {
    static let shared = AppController()

    let configManager = ConfigManager()
    let windowManager = WindowManager()
    private(set) var isAccessibilityTrusted = AccessibilityPermission.isTrusted
    /// Hotkeys that failed to register (usually because another app owns the combo).
    private(set) var hotkeyFailures: [String] = []

    func start() {
        configManager.bootstrap()
        HotkeyManager.shared.onAction = { [weak self] action in self?.perform(action) }
        applyConfig()

        if !isAccessibilityTrusted { AccessibilityPermission.prompt() }
        Task {
            // Poll until the user grants access, then start tracking windows.
            while !AccessibilityPermission.isTrusted {
                try? await Task.sleep(for: .seconds(1))
            }
            isAccessibilityTrusted = true
            windowManager.start()
        }
    }

    func perform(_ action: Action) {
        switch action {
        case .focusWorkspace(let name): windowManager.switchTo(name)
        case .moveToWorkspace(let name): windowManager.moveFocusedWindow(to: name)
        case .reloadConfig: reloadConfig()
        }
    }

    func reloadConfig() {
        configManager.load()
        applyConfig()
    }

    func shutdown() {
        HotkeyManager.shared.unregisterAll()
        windowManager.restoreAll()
    }

    private func applyConfig() {
        let config = configManager.config
        windowManager.configure(workspaces: config.workspaces)
        hotkeyFailures = HotkeyManager.shared.register(config.bindings)
    }
}
