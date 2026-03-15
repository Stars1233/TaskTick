import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request notification permission
        NotificationManager.shared.requestPermission()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Re-open main window when dock icon is clicked
        if !flag {
            for window in sender.windows {
                if window.canBecomeMain {
                    window.makeKeyAndOrderFront(self)
                    break
                }
            }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Switch to accessory mode (menu bar only) when all windows are closed
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Clean up scheduler
        TaskScheduler.shared.stop()
    }
}
