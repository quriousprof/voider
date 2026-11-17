import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppController.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave windows stranded off-screen.
        AppController.shared.shutdown()
    }
}
