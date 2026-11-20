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
                if let name = windowManager.focusedWindowName(in: workspace) {
                    Text("\(workspace) - \(name)")
                } else {
                    Text(workspace)
                }
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

        UpdateMenuItems(updater: controller.updater)
        Text("Voider \(controller.updater.currentVersion)")

        Divider()

        Button("Quit Voider") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// "Check for Updates", or the update's progress and actions.
private struct UpdateMenuItems: View {
    let updater: Updater

    var body: some View {
        switch updater.state {
        case .idle:
            Button("Check for Updates") { updater.checkForUpdates() }
        case .checking:
            Text("Checking for Updates…")
        case .upToDate:
            Button("Check for Updates") { updater.checkForUpdates() }
            Text("Voider is up to date")
        case .available(let release):
            Button("Update to \(release.version) and Restart") { updater.installUpdate() }
            Button("What's New in \(release.version)…") { NSWorkspace.shared.open(release.pageURL) }
        case .installing(let release):
            Text("Installing \(release.version)…")
        case .failed(let message, let release):
            Text(message)
            if let release {
                Button("Download \(release.version) Manually…") { NSWorkspace.shared.open(release.pageURL) }
            }
            Button("Check for Updates") { updater.checkForUpdates() }
        }
    }
}
