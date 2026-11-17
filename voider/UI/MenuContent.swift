import AppKit
import SwiftUI

/// The text shown in the menu bar: the active workspace's name.
struct MenuBarLabel: View {
    let controller: AppController

    var body: some View {
        Text(controller.windowManager.activeWorkspace)
    }
}

struct MenuContent: View {
    let controller: AppController

    var body: some View {
        let windowManager = controller.windowManager

        ForEach(windowManager.workspaces, id: \.self) { workspace in
            Toggle(isOn: Binding(
                get: { windowManager.activeWorkspace == workspace },
                set: { _ in controller.perform(.focusWorkspace(workspace)) }
            )) {
                Text("Workspace \(workspace) (\(windowManager.windowCount(in: workspace)))")
            }
        }

        Divider()

        if !controller.isAccessibilityTrusted {
            Button("Grant Accessibility Access…") {
                AccessibilityPermission.prompt()
                AccessibilityPermission.openSettings()
            }
        }
        if let error = controller.configManager.lastError {
            Text("Config error: \(error)")
        }
        if !controller.hotkeyFailures.isEmpty {
            Text("Couldn't register: \(controller.hotkeyFailures.joined(separator: ", "))")
        }

        Button("Reload Config") { controller.reloadConfig() }
        Button("Open Config") { NSWorkspace.shared.open(controller.configManager.fileURL) }

        Divider()

        Button("Quit Voider") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
