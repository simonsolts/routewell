import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var persistence: PersistenceController?
    var reopenMainWindow: (() -> Void)?
    private weak var mainWindow: NSWindow?
    private weak var refresh: RefreshController?
    private var observing = false

    func attach(window: NSWindow, refresh: RefreshController) {
        mainWindow = window
        self.refresh = refresh
        if !observing {
            observing = true
            let center = NotificationCenter.default
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSApplication.didHideNotification,
                         NSApplication.didUnhideNotification] {
                center.addObserver(self, selector: #selector(visibilityChanged), name: name, object: nil)
            }
            center.addObserver(self, selector: #selector(windowClosing), name: NSWindow.willCloseNotification, object: nil)
            let workspace = NSWorkspace.shared.notificationCenter
            workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
            workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        }
        visibilityChanged()
    }

    @objc private func visibilityChanged() {
        guard let mainWindow else { return }
        // Occlusion notifications also report ordering changes. Being covered by
        // another app does not make an otherwise visible window hidden.
        refresh?.setWindowVisible(mainWindow.isVisible && !mainWindow.isMiniaturized && !NSApp.isHidden)
    }

    @objc private func windowClosing(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        refresh?.setWindowVisible(false)
    }

    @objc private func willSleep() { refresh?.setSleeping(true) }
    @objc private func didWake() { refresh?.setSleeping(false) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let persistence else { return .terminateNow }
        Task {
            await persistence.flush()
            if persistence.errors.isEmpty {
                sender.reply(toApplicationShouldTerminate: true)
            } else {
                let alert = NSAlert()
                alert.messageText = "Some settings could not be saved"
                alert.informativeText = "Quit anyway and lose unsaved changes, or cancel to retry in Settings."
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Quit Anyway")
                sender.reply(toApplicationShouldTerminate: alert.runModal() == .alertSecondButtonReturn)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        refresh?.stop()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        reopenMainWindow?()
        return true
    }
}

/// Reports the actual main window, without letting view appearance own a timer.
struct MainWindowLifecycle: NSViewRepresentable {
    let delegate: AppDelegate?
    let refresh: RefreshController

    func makeNSView(context: Context) -> WindowProbe {
        let view = WindowProbe()
        view.attached = { [weak delegate, weak refresh] window in
            guard let refresh else { return }
            delegate?.attach(window: window, refresh: refresh)
        }
        return view
    }

    func updateNSView(_ nsView: WindowProbe, context: Context) {}

    final class WindowProbe: NSView {
        var attached: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { attached?(window) }
        }
    }
}
