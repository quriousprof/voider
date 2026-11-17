import AppKit
import ApplicationServices
import os

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

nonisolated extension AXUIElement {
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

    var size: CGSize? {
        guard let value: AXValue = attribute(kAXSizeAttribute) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    /// Window frame in AX coordinates (origin at the top-left of the primary screen, y down).
    var frame: CGRect? {
        guard let position, let size else { return nil }
        return CGRect(origin: position, size: size)
    }

    var isFullScreen: Bool {
        (attribute("AXFullScreen") as Bool?) ?? false
    }

    func setPosition(_ point: CGPoint) {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(self, kAXPositionAttribute as CFString, value)
    }
}

extension AXUIElement {
    /// Brings the window to the front and activates its app.
    func focus(pid: pid_t) {
        AXUIElementPerformAction(self, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(self, kAXMainAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }
}

/// Batched AX work, run with one thread per app (like AeroSpace), so many apps or a single slow one
/// can't stall a workspace switch. The AX API is thread-safe, hence the `@unchecked Sendable`s.
nonisolated enum AXBatch {
    struct Window: @unchecked Sendable {
        let id: CGWindowID
        let element: AXUIElement
    }

    struct Move: @unchecked Sendable {
        let id: CGWindowID
        let pid: pid_t
        let element: AXUIElement
        let target: CGPoint
        /// Read the window's origin before moving it; the move is skipped if that read fails.
        let recordOrigin: Bool
    }

    /// Standard windows of each app. Apps whose query failed (e.g. hung) are left out.
    static func standardWindows(of pids: [pid_t]) -> [pid_t: [Window]] {
        let result = OSAllocatedUnfairLock(initialState: [pid_t: [Window]]())
        DispatchQueue.concurrentPerform(iterations: pids.count) { i in
            let pid = pids[i]
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.5)
            guard let elements: [AXUIElement] = app.attribute(kAXWindowsAttribute) else { return }
            let windows = elements.compactMap { element -> Window? in
                AXUIElementSetMessagingTimeout(element, 0.5)
                guard element.isStandardWindow, let id = element.windowID else { return nil }
                return Window(id: id, element: element)
            }
            result.withLock { $0[pid] = windows }
        }
        return result.withLock { $0 }
    }

    /// Applies the moves without animation, in parallel across apps. Returns the pre-move origin of
    /// every window moved with `recordOrigin`.
    static func move(_ moves: [Move]) -> [CGWindowID: CGPoint] {
        let byApp = Array(Dictionary(grouping: moves, by: \.pid).values)
        let origins = OSAllocatedUnfairLock(initialState: [CGWindowID: CGPoint]())
        DispatchQueue.concurrentPerform(iterations: byApp.count) { i in
            let group = byApp[i]
            withoutAnimations(pid: group[0].pid) {
                for move in group {
                    if move.recordOrigin {
                        guard let origin = move.element.position else { continue }
                        origins.withLock { $0[move.id] = origin }
                    }
                    move.element.setPosition(move.target)
                }
            }
        }
        return origins.withLock { $0 }
    }

    /// Apps with AXEnhancedUserInterface on (set by VoiceOver and some window tools) animate every AX
    /// move. AeroSpace turns it off for the duration of its moves; so do we.
    private static func withoutAnimations(pid: pid_t, _ body: () -> Void) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let name = "AXEnhancedUserInterface"
        let enhanced = (app.attribute(name) as Bool?) == true
        if enhanced { AXUIElementSetAttributeValue(app, name as CFString, kCFBooleanFalse) }
        body()
        if enhanced { AXUIElementSetAttributeValue(app, name as CFString, kCFBooleanTrue) }
    }
}
