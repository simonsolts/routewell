import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var reopenMainWindow: (() -> Void)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        reopenMainWindow?()
        return true
    }
}
