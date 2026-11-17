import AppKit
import ApplicationServices
import Observation

/// Tracks every standard window, assigns it to a workspace, and hides windows of
/// inactive workspaces by parking them just past the bottom-right screen corner.
@Observable
final class WindowManager {
    struct TrackedWindow {
        let pid: pid_t
        let element: AXUIElement
        var workspace: String
        /// Where the window was before being hidden; non-nil means it's currently parked off-screen.
        var hiddenFrom: CGPoint?
    }

    private(set) var workspaces: [String]
    private(set) var activeWorkspace: String
    private(set) var tracked: [CGWindowID: TrackedWindow] = [:]
    /// Whether moving a window also switches to its new workspace. Set from config.
    @ObservationIgnored var followMovedWindow = false

    @ObservationIgnored private var lastFocused: [String: CGWindowID] = [:]
    @ObservationIgnored private var observers: [pid_t: AXObserver] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    /// Focus events right after a switch come from our own hide/show; ignore them.
    @ObservationIgnored private var ignoreFocusEventsUntil = Date.distantPast
    /// State from the previous run, consumed as its windows are rediscovered. Loaded in `start()`,
    /// after any previous instance has quit and written its final state.
    @ObservationIgnored private var restoredState: SavedState?

    init(workspaces: [String] = VoiderConfig.defaultWorkspaces) {
        self.workspaces = workspaces
        self.activeWorkspace = workspaces[0]
    }

    func windowCount(in workspace: String) -> Int {
        tracked.values.filter { $0.workspace == workspace }.count
    }

    /// Name of the app owning the workspace's last-focused window, if the workspace has any windows.
    func focusedWindowName(in workspace: String) -> String? {
        let candidates = tracked.filter { $0.value.workspace == workspace }
        let id = lastFocused[workspace].flatMap { candidates[$0] != nil ? $0 : nil } ?? candidates.keys.sorted().first
        guard let id, let window = tracked[id] else { return nil }
        return NSRunningApplication(processIdentifier: window.pid)?.localizedName
    }

    // MARK: - Lifecycle

    /// Begins tracking windows. Requires Accessibility permission.
    func start() {
        guard !started, AccessibilityPermission.isTrusted else { return }
        started = true

        restoredState = StateStore.load()
        if let saved = restoredState?.activeWorkspace.uppercased(), workspaces.contains(saved) { activeWorkspace = saved }
        for app in trackableApps() { observe(app) }
        refresh()
        reconcile()
        persist()

        let center = NSWorkspace.shared.notificationCenter
        Task {
            for await note in center.notifications(named: NSWorkspace.didLaunchApplicationNotification) {
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { continue }
                observe(app)
                scheduleRefresh()
            }
        }
        Task {
            for await note in center.notifications(named: NSWorkspace.didTerminateApplicationNotification) {
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { continue }
                observers[app.processIdentifier] = nil
                scheduleRefresh()
            }
        }
        // Cmd-Tab and Dock clicks don't always produce a focused-window AX event, so also watch activation.
        Task {
            let ownPID = ProcessInfo.processInfo.processIdentifier
            for await note in center.notifications(named: NSWorkspace.didActivateApplicationNotification) {
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier != ownPID else { continue }
                let appElement = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(appElement, 0.5)
                if let window: AXUIElement = appElement.attribute(kAXFocusedWindowAttribute) {
                    handleFocusChanged(to: window)
                }
            }
        }
        Task {
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didChangeScreenParametersNotification) {
                reconcile(force: true)
            }
        }
    }

    /// Applies a (re)loaded workspace list, moving orphaned windows to the active workspace.
    func configure(workspaces newWorkspaces: [String]) {
        guard !newWorkspaces.isEmpty, newWorkspaces != workspaces else { return }
        workspaces = newWorkspaces
        if !newWorkspaces.contains(activeWorkspace) { activeWorkspace = newWorkspaces[0] }
        for id in tracked.keys where !newWorkspaces.contains(tracked[id]?.workspace ?? "") {
            tracked[id]?.workspace = activeWorkspace
        }
        lastFocused = lastFocused.filter { newWorkspaces.contains($0.key) }
        reconcile()
        persist()
    }

    /// Puts every hidden window back where it was. Call before quitting.
    func restoreAll() {
        let moves = tracked.compactMap { id, window in window.hiddenFrom.map { move(id, window, to: $0) } }
        _ = AXBatch.move(moves)
        for id in tracked.keys { tracked[id]?.hiddenFrom = nil }
        persist()
    }

    // MARK: - Actions

    func switchTo(_ workspace: String) {
        guard workspaces.contains(workspace), workspace != activeWorkspace else { return }
        // No full refresh here: observers keep `tracked` current, and querying every app is what made switches lag.
        flushPendingRefresh()

        if let id = focusedWindowID(), tracked[id]?.workspace == activeWorkspace {
            lastFocused[activeWorkspace] = id
        }
        ignoreFocusEventsUntil = Date().addingTimeInterval(0.5)
        activeWorkspace = workspace
        reconcile()
        persist()
        focusAnyWindow(in: workspace)
    }

    func moveFocusedWindow(to workspace: String) {
        guard workspaces.contains(workspace), let id = focusedWindowID() else { return }
        if tracked[id] == nil { refresh() }
        guard tracked[id] != nil else { return }

        tracked[id]?.workspace = workspace
        if lastFocused[activeWorkspace] == id { lastFocused[activeWorkspace] = nil }
        guard workspace != activeWorkspace else { return }

        ignoreFocusEventsUntil = Date().addingTimeInterval(0.5)
        if followMovedWindow {
            lastFocused[workspace] = id
            activeWorkspace = workspace
            reconcile()
            persist()
            focusAnyWindow(in: workspace)
            return
        }
        reconcile()
        persist()
        focusAnyWindow(in: activeWorkspace)
    }

    // MARK: - Discovery

    private func trackableApps() -> [NSRunningApplication] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID && !$0.isTerminated
        }
    }

    /// Debounced refresh, so a window that's still being set up has its attributes by the time we look.
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            refreshTask = nil
            refresh()
        }
    }

    /// Runs a debounced refresh now, if one is waiting, so a just-created window isn't missed.
    private func flushPendingRefresh() {
        guard let task = refreshTask else { return }
        task.cancel()
        refreshTask = nil
        refresh()
    }

    /// Syncs `tracked` with the windows that actually exist. New windows join the active workspace.
    func refresh() {
        guard AccessibilityPermission.isTrusted else { return }

        // Apps are queried in parallel; a failed query (hung app) must not make us forget that app's windows.
        let found = AXBatch.standardWindows(of: trackableApps().map(\.processIdentifier))
        let queriedPIDs = Set(found.keys)
        var seen = Set<CGWindowID>()
        var changed = false

        for (pid, windows) in found {
            for entry in windows {
                let id = entry.id, window = entry.element
                if tracked[id] == nil {
                    guard !window.isMinimized else { continue }
                    tracked[id] = adopt(window, id: id, pid: pid)
                    changed = true
                    if let observer = observers[pid] {
                        AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, observerRefcon)
                    }
                }
                seen.insert(id)
            }
        }

        let runningPIDs = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        for (id, window) in tracked where !seen.contains(id) && (queriedPIDs.contains(window.pid) || !runningPIDs.contains(window.pid)) {
            tracked[id] = nil
            changed = true
        }
        lastFocused = lastFocused.filter { tracked[$0.value] != nil }
        if changed { persist() }
    }

    /// Builds the tracking entry for a newly discovered window, re-adopting its saved workspace
    /// and parked position from a previous run, or rescuing it if it was left parked off-screen.
    private func adopt(_ window: AXUIElement, id: CGWindowID, pid: pid_t) -> TrackedWindow {
        var entry = TrackedWindow(pid: pid, element: window, workspace: activeWorkspace)
        let parked = window.position.map(isParked) ?? false

        // Uppercase: state written before workspace names became case-insensitive may hold lowercase names.
        if let saved = restoredState?.windows.removeValue(forKey: String(id)), saved.pid == pid, workspaces.contains(saved.workspace.uppercased()) {
            entry.workspace = saved.workspace.uppercased()
            // Only trust the saved origin if the window really is still parked.
            if parked, let origin = saved.hiddenFrom { entry.hiddenFrom = origin }
            else if parked { window.setPosition(rescuePoint) }
        } else if parked {
            window.setPosition(rescuePoint)
        }
        return entry
    }

    /// Writes workspace assignments and parked positions to disk. No-op until tracking has started,
    /// so a launch without Accessibility permission can't clobber the previous run's state.
    private func persist() {
        guard started else { return }
        let windows = tracked.reduce(into: [String: SavedWindow]()) { result, entry in
            result[String(entry.key)] = SavedWindow(pid: entry.value.pid, workspace: entry.value.workspace, hiddenFrom: entry.value.hiddenFrom)
        }
        // Keep not-yet-rediscovered windows from the previous run (e.g. an app that was hung at launch).
        let runningPIDs = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        let carried = (restoredState?.windows ?? [:]).filter { runningPIDs.contains($0.value.pid) }
        StateStore.save(SavedState(activeWorkspace: activeWorkspace, windows: carried.merging(windows) { _, current in current }))
    }

    // MARK: - Hiding / showing

    private var offscreenPoint: CGPoint {
        let screens = NSScreen.screens
        let maxX = screens.map(\.frame.maxX).max() ?? 0
        let primaryHeight = screens.first?.frame.height ?? 0
        // Leave one pixel on-screen; macOS pulls fully off-screen windows back.
        return CGPoint(x: maxX - 1, y: primaryHeight - 1)
    }

    /// Where rescued windows reappear. Matches the default origin of a fresh window.
    private var rescuePoint: CGPoint { CGPoint(x: 80, y: 80) }

    /// True if a window's origin sits in the bottom-right parking area (with slack for macOS clamping).
    private func isParked(_ origin: CGPoint) -> Bool {
        let parking = offscreenPoint
        return origin.x >= parking.x - 20 && origin.y >= parking.y - 20
    }

    private func move(_ id: CGWindowID, _ window: TrackedWindow, to target: CGPoint, recordOrigin: Bool = false) -> AXBatch.Move {
        AXBatch.Move(id: id, pid: window.pid, element: window.element, target: target, recordOrigin: recordOrigin)
    }

    /// Makes visibility match the active workspace. `force` re-parks hidden windows (e.g. after a screen change).
    /// All moves go out in one parallel, animation-free batch so the switch lands at once.
    private func reconcile(force: Bool = false) {
        let parking = offscreenPoint
        var updated = tracked
        var moves: [AXBatch.Move] = []
        for (id, window) in tracked {
            if window.workspace == activeWorkspace {
                guard let origin = window.hiddenFrom else { continue }
                moves.append(move(id, window, to: origin))
                updated[id]?.hiddenFrom = nil
            } else if window.hiddenFrom == nil {
                moves.append(move(id, window, to: parking, recordOrigin: true))
            } else if force {
                moves.append(move(id, window, to: parking))
            }
        }
        guard !moves.isEmpty else { return }
        for (id, origin) in AXBatch.move(moves) { updated[id]?.hiddenFrom = origin }
        tracked = updated
    }

    // MARK: - Focus

    private func focusedWindowID() -> CGWindowID? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        let systemApp: AXUIElement? = system.attribute(kAXFocusedApplicationAttribute)
        // The system-wide query comes back empty for some apps, so fall back to the frontmost app's pid.
        let app = systemApp ?? NSWorkspace.shared.frontmostApplication.map { AXUIElementCreateApplication($0.processIdentifier) }
        guard let window: AXUIElement = app?.attribute(kAXFocusedWindowAttribute) else { return nil }
        return window.windowID
    }

    private func focusAnyWindow(in workspace: String) {
        let candidates = tracked.filter { $0.value.workspace == workspace }
        let id = lastFocused[workspace].flatMap { candidates[$0] != nil ? $0 : nil } ?? candidates.keys.sorted().first
        guard let id, let window = tracked[id] else { return }
        lastFocused[workspace] = id
        window.element.focus(pid: window.pid)
    }

    // MARK: - AX observers

    private var observerRefcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] == nil else { return }

        var observer: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &observer) == .success, let observer else { return }

        let appElement = AXUIElementCreateApplication(pid)
        // Chromium/Electron apps (Spotify, ...) keep their accessibility tree off until a client asks for it.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXObserverAddNotification(observer, appElement, kAXWindowCreatedNotification as CFString, observerRefcon)
        AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString, observerRefcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    fileprivate func handle(notification name: String, element: AXUIElement) {
        switch name {
        case kAXWindowCreatedNotification, kAXUIElementDestroyedNotification:
            scheduleRefresh()
        case kAXFocusedWindowChangedNotification:
            let window: AXUIElement = element.attribute(kAXFocusedWindowAttribute) ?? element
            handleFocusChanged(to: window)
        default:
            break
        }
    }

    /// If the user focuses a window from another workspace (Cmd-Tab, Dock click), follow it there,
    /// and make sure the window is actually on screen.
    private func handleFocusChanged(to window: AXUIElement) {
        guard Date() >= ignoreFocusEventsUntil, let id = window.windowID else { return }
        if tracked[id] == nil { refresh() }
        guard let entry = tracked[id] else {
            scheduleRefresh()
            return
        }
        lastFocused[entry.workspace] = id
        if entry.workspace != activeWorkspace { switchTo(entry.workspace) }
        bringOnScreenIfNeeded(id)
    }

    // MARK: - Off-screen recovery

    /// Converts an AppKit rect (origin bottom-left of the primary screen) to AX coordinates (top-left, y down).
    private func axRect(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Re-centers a focused window that's (almost) entirely off every screen, e.g. after a display was
    /// unplugged. Partly off-screen windows are left alone so dragging near an edge isn't fought.
    private func bringOnScreenIfNeeded(_ id: CGWindowID) {
        guard let window = tracked[id], window.hiddenFrom == nil,
              !window.element.isFullScreen, let frame = window.element.frame else { return }

        let needed = CGSize(width: min(100, frame.width), height: min(100, frame.height))
        let isVisible = NSScreen.screens.contains {
            let overlap = axRect($0.frame).intersection(frame)
            return !overlap.isNull && overlap.width >= needed.width && overlap.height >= needed.height
        }
        guard !isVisible else { return }

        // Center on the screen the mouse is on, keeping the title bar reachable if the window is oversized.
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.screens.first else { return }
        let area = axRect(screen.visibleFrame)
        window.element.setPosition(CGPoint(
            x: max(area.minX, area.midX - frame.width / 2),
            y: max(area.minY, area.midY - frame.height / 2)
        ))
    }
}

private nonisolated func axObserverCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let manager = Unmanaged<WindowManager>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    Task { @MainActor in manager.handle(notification: name, element: element) }
}
