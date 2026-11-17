import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A duplicate must not run any cleanup that touches the real instance's windows.
        guard SingleInstance.claim() else { exit(0) }
        AppController.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave windows stranded off-screen.
        AppController.shared.shutdown()
    }
}
