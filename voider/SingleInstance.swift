import AppKit

/// Guarantees only one Voider runs at a time. The newest launch wins: it asks older copies to quit
/// (so they restore their windows), force-quits any that don't, then takes an exclusive lock.
/// Two copies would fight over hotkeys and window positions.
enum SingleInstance {
    private static var lockDescriptor: Int32 = -1

    private static var lockURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/voider/voider.lock")
    }

    /// Returns false if this process should exit instead of running.
    static func claim() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return true }
        let me = NSRunningApplication.current
        let myLaunch = me.launchDate ?? .distantFuture

        func others() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != me.processIdentifier }
        }

        // A newer copy exists and will replace this one. Stepping aside avoids two copies
        // that launch together terminating each other.
        if others().contains(where: { ($0.launchDate ?? .distantPast) > myLaunch }) { return false }

        if !others().isEmpty {
            others().forEach { $0.terminate() }
            if !wait(timeout: 3, until: { others().isEmpty }) {
                others().forEach { $0.forceTerminate() }
                _ = wait(timeout: 2, until: { others().isEmpty })
            }
        }
        return acquireLock()
    }

    /// Backstop for copies that don't show up under this bundle ID. The kernel drops the lock on
    /// any exit, including a crash or a killed debug session.
    private static func acquireLock() -> Bool {
        try? FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return true } // Can't lock; don't block startup over it.

        let acquired = wait(timeout: 2) { flock(descriptor, LOCK_EX | LOCK_NB) == 0 }
        if acquired {
            lockDescriptor = descriptor
        } else {
            close(descriptor)
        }
        return acquired
    }

    /// Polls on the main thread; fine here since nothing else is running yet.
    private static func wait(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return true
    }
}
