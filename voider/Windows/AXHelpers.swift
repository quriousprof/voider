import AppKit
import ApplicationServices

/// Private but long-stable API (used by AeroSpace, yabai, etc.) mapping an AX window to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
nonisolated func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

enum AccessibilityPermission {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to Privacy & Security › Accessibility.
    static func prompt() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

extension AXUIElement {
    func attribute<T>(_ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    var windowID: CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(self, &id) == .success && id != 0 ? id : nil
    }

    /// Real, user-facing windows only (skips sheets, popovers, palettes, etc.).
    var isStandardWindow: Bool {
        (attribute(kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole
    }

    var isMinimized: Bool {
        (attribute(kAXMinimizedAttribute) as Bool?) ?? false
    }

    var position: CGPoint? {
        guard let value: AXValue = attribute(kAXPositionAttribute) else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    func setPosition(_ point: CGPoint) {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(self, kAXPositionAttribute as CFString, value)
    }

    /// Brings the window to the front and activates its app.
    func focus(pid: pid_t) {
        AXUIElementPerformAction(self, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(self, kAXMainAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }
}
