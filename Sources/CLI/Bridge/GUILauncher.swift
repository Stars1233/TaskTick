import AppKit
import Foundation
import TaskTickCore

/// Detects whether TaskTick.app is running, launches it via URL Scheme if not,
/// and waits up to 10s for it to be ready before returning.
enum GUILauncher {

    /// Bundle IDs to look for. Includes the dev variant so `tasktick` invoked
    /// during development still works against TaskTick Dev.app.
    private static let bundleIds = ["com.lifedever.TaskTick", "com.lifedever.TaskTick.dev"]

    static func isRunning() -> Bool {
        bundleIds.contains { id in
            !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
        }
    }

    /// Launch TaskTick without dispatching any action — used by `create`,
    /// which posts a separate DistributedNotification after the GUI is ready
    /// (the action vocabulary in CLIBridge.Action is taskId-based and
    /// doesn't fit a multi-field create payload).
    static func launchAndWait(timeout: TimeInterval = 10) -> Bool {
        // Pick URL Scheme based on the CLI's bundle context.
        let scheme = BundleContext.isDev ? "tasktick-dev" : "tasktick"
        // Use a no-op host so AppDelegate.parse() returns nil and just wakes
        // the app without trying to act on a task. The URL still works to
        // launch the app via LaunchServices.
        guard let url = URL(string: "\(scheme)://wake") else { return false }
        NSWorkspace.shared.open(url)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isRunning() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    /// Launch TaskTick by opening a URL. Used as fallback when the GUI isn't
    /// running and a write command needs to dispatch. Blocks up to 10s for the
    /// app to be running. Returns whether launch succeeded.
    static func launchAndWait(action: NotificationBridge.CLIAction, taskId: UUID, timeout: TimeInterval = 10) -> Bool {
        // Pick URL Scheme based on the CLI's bundle context: dev CLI
        // (inside TaskTick Dev.app) uses tasktick-dev:// which is registered
        // only by the dev .app, eliminating LaunchServices ambiguity when
        // both apps are installed.
        let scheme = BundleContext.isDev ? "tasktick-dev" : "tasktick"
        guard let url = URL(string: "\(scheme)://\(action.rawValue)?id=\(taskId.uuidString)") else {
            return false
        }
        NSWorkspace.shared.open(url)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isRunning() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }
}
