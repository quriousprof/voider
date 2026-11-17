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
        for id in tracked.keys { show(id) }
        persist()
    }

    // MARK: - Actions

    func switchTo(_ workspace: String) {
        guard workspaces.contains(workspace) else { return }
        refresh()
        guard workspace != activeWorkspace else { return }

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
        guard workspaces.contains(workspace) else { return }
        refresh()
        guard let id = focusedWindowID(), tracked[id] != nil else { return }

        tracked[id]?.workspace = workspace
        if lastFocused[activeWorkspace] == id { lastFocused[activeWorkspace] = nil }
        guard workspace != activeWorkspace else { return }

        ignoreFocusEventsUntil = Date().addingTimeInterval(0.5)
        hide(id)
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
            refresh()
        }
    }

    /// Syncs `tracked` with the windows that actually exist. New windows join the active workspace.
    func refresh() {
        guard AccessibilityPermission.isTrusted else { return }

        var seen = Set<CGWindowID>()
        var queriedPIDs = Set<pid_t>()
        var changed = false

        for app in trackableApps() {
            let pid = app.processIdentifier
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, 0.5)
            // A failed query (hung app) must not make us forget that app's windows.
            guard let windows: [AXUIElement] = appElement.attribute(kAXWindowsAttribute) else { continue }
            queriedPIDs.insert(pid)

            for window in windows {
                guard window.isStandardWindow, let id = window.windowID else { continue }
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

    private func hide(_ id: CGWindowID) {
        guard var window = tracked[id], window.hiddenFrom == nil, let origin = window.element.position else { return }
        window.hiddenFrom = origin
        tracked[id] = window
        window.element.setPosition(offscreenPoint)
    }

    private func show(_ id: CGWindowID) {
        guard var window = tracked[id], let origin = window.hiddenFrom else { return }
        window.hiddenFrom = nil
        tracked[id] = window
        window.element.setPosition(origin)
    }

    /// Makes visibility match the active workspace. `force` re-parks hidden windows (e.g. after a screen change).
    private func reconcile(force: Bool = false) {
        for (id, window) in tracked {
            if window.workspace == activeWorkspace {
                show(id)
            } else if force, window.hiddenFrom != nil {
                window.element.setPosition(offscreenPoint)
            } else {
                hide(id)
            }
        }
    }

    // MARK: - Focus

    private func focusedWindowID() -> CGWindowID? {
        let system = AXUIElementCreateSystemWide()
        guard let app: AXUIElement = system.attribute(kAXFocusedApplicationAttribute),
              let window: AXUIElement = app.attribute(kAXFocusedWindowAttribute) else { return nil }
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

    /// If the user focuses a window from another workspace (Cmd-Tab, Dock click), follow it there.
    private func handleFocusChanged(to window: AXUIElement) {
        guard Date() >= ignoreFocusEventsUntil, let id = window.windowID else { return }
        guard let entry = tracked[id] else {
            scheduleRefresh()
            return
        }
        lastFocused[entry.workspace] = id
        if entry.workspace != activeWorkspace { switchTo(entry.workspace) }
    }
}

private nonisolated func axObserverCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let manager = Unmanaged<WindowManager>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    Task { @MainActor in manager.handle(notification: name, element: element) }
}
