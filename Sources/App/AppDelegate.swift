import AppKit
import SwiftUI

/// Show a modal warning alert for a non-fatal error. Use at sites where we previously
/// swallowed errors with `try?` and the user needs to know the action didn't take effect.
@MainActor
func presentErrorAlert(titleKey: String, messageKey: String, error: Error) {
    let alert = NSAlert()
    alert.messageText = L10n.tr(titleKey)
    alert.informativeText = L10n.tr(messageKey, error.localizedDescription)
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.runModal()
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// When true, `NSApp.terminate` actually quits. Otherwise Cmd+Q just closes windows.
    @MainActor static var shouldReallyQuit = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationManager.shared.requestPermission()

        // Apply saved appearance mode
        let mode = UserDefaults.standard.string(forKey: "appearanceMode") ?? "system"
        switch mode {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if AppDelegate.shouldReallyQuit {
            return .terminateNow
        }
        // Cmd+Q: just close all windows instead of quitting
        for window in sender.windows {
            if window.isVisible && window.canBecomeMain {
                window.close()
            }
        }
        NSApp.setActivationPolicy(.accessory)
        return .terminateCancel
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
        TaskScheduler.shared.stop()
        // Flush pending SwiftData writes to ensure database is consistent on disk.
        // We can't block termination for user input here, but logging gives a trail
        // when a user later reports "my edits vanished after I quit".
        do {
            try TaskTickApp._sharedModelContainer.mainContext.save()
        } catch {
            NSLog("⚠️ Final save on terminate failed: \(error.localizedDescription)")
        }
        // save() writes to the -wal sidecar but does NOT merge it into the main store.
        // If the update installer replaces the .app right after this, a -wal left
        // behind can be orphaned and its contents lost. Force a checkpoint now so
        // the main store is self-contained.
        StoreHardener.checkpoint(at: TaskTickApp._storeURL)
    }
}
