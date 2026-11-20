import AppKit
import ApplicationServices
import os

/// Private but long-stable API (used by other window managers) mapping an AX window to its CGWindowID.
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
    /// Brings the window to the front, makes it key, and activates its app.
    func focus(pid: pid_t, windowID: CGWindowID) {
        // `activate()` is only a request since macOS 14 and is denied to apps that aren't active
        // themselves, which Voider never is. SkyLight activates the app with exactly this window key.
        if !SkyLight.focus(windowID: windowID, pid: pid) {
            AXUIElementSetAttributeValue(self, kAXMainAttribute as CFString, kCFBooleanTrue)
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
        AXUIElementPerformAction(self, kAXRaiseAction as CFString)
    }
}

/// Private SkyLight calls that window switchers (AltTab, yabai) use to focus a specific window from a
/// background app. Looked up at runtime, so if they ever disappear `focus` falls back to `activate()`.
private enum SkyLight {
    private typealias GetProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias SetFrontProcess = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    private typealias PostEventRecord = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let getProcessForPID = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID") // RTLD_DEFAULT
        .map { unsafeBitCast($0, to: GetProcessForPID.self) }
    private static let setFrontProcess = handle.flatMap { dlsym($0, "_SLPSSetFrontProcessWithOptions") }
        .map { unsafeBitCast($0, to: SetFrontProcess.self) }
    private static let postEventRecord = handle.flatMap { dlsym($0, "SLPSPostEventRecordTo") }
        .map { unsafeBitCast($0, to: PostEventRecord.self) }

    /// Returns false if the calls are unavailable or the app couldn't be brought to the front.
    static func focus(windowID: CGWindowID, pid: pid_t) -> Bool {
        guard let getProcessForPID, let setFrontProcess, let postEventRecord else { return false }
        var psn = ProcessSerialNumber()
        // 0x200 = kCPSUserGenerated: treat it like a user click, so the activation isn't refused.
        guard getProcessForPID(pid, &psn) == noErr, setFrontProcess(&psn, windowID, 0x200) == .success else { return false }

        // Synthesized "make key window" event record (layout from AltTab/yabai): sent once as
        // mouse-down (0x01) and once as mouse-up (0x02), targeting the window ID at offset 0x3c.
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: windowID.littleEndian) { bytes.replaceSubrange(0x3c..<0x40, with: $0) }
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        bytes[0x08] = 0x01
        _ = postEventRecord(&psn, &bytes)
        bytes[0x08] = 0x02
        _ = postEventRecord(&psn, &bytes)
        return true
    }
}

nonisolated enum WindowServer {
    /// IDs of every window the WindowServer knows about, on all Spaces and including off-screen ones.
    /// Nil if the query failed. Needs no Screen Recording permission (only window titles do).
    static func windowIDs() -> Set<CGWindowID>? {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              !list.isEmpty else { return nil }
        return Set(list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    }

    /// On-screen window IDs, front-most first. Parked windows count: they keep one pixel on screen.
    static func frontToBackWindowIDs() -> [CGWindowID] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
    }
}

/// Batched AX work, run with one thread per app, so many apps or a single slow one
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
    /// move, so it's turned off for the duration of our moves.
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
