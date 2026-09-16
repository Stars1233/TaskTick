import AppKit
import Foundation
import UserNotifications
import TaskTickCore

/// Manages system notifications for task execution results.
final class NotificationManager: NSObject, @unchecked Sendable {

    static let shared = NotificationManager()

    /// userInfo flag: tapping this banner should bring the main window back.
    static let openMainWindowKey = "tasktick.openMainWindow"

    private var isAvailable = false

    private override init() { super.init() }

    func requestPermission() {
        // UNUserNotificationCenter requires a valid app bundle with bundle identifier.
        // When running via `swift run`, no bundle exists and this will crash.
        guard Bundle.main.bundleIdentifier != nil else {
            print("[NotificationManager] No bundle identifier — notifications disabled.")
            return
        }

        isAvailable = true
        // Without a delegate, macOS silently drops notifications submitted while the
        // app is in the foreground — which is exactly when users test "Run Now". Set
        // ourselves as the delegate so the willPresent hook below can ask the system
        // to show the banner regardless of foreground state.
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                print("[NotificationManager] Permission error: \(error)")
            }
        }
    }

    /// `userInfo` rides along so the tap handler below knows what the banner was
    /// about — currently only `openMainWindowKey`, set by the hide-to-menu-bar notice.
    func sendNotification(title: String, body: String, userInfo: [String: Any] = [:]) {
        guard isAvailable else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = userInfo

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                NSLog("⚠️ Notification add failed: \(error.localizedDescription)")
            }
            self?.checkPermissionAndPromptIfNeeded()
        }
    }

    /// Check authorization status; if the user has explicitly denied notifications,
    /// surface an NSAlert that deep-links into System Settings. macOS does not let
    /// apps re-trigger the system permission dialog after a denial, so a custom
    /// prompt with a settings link is the only recovery path.
    private func checkPermissionAndPromptIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .denied else { return }
            DispatchQueue.main.async {
                Self.presentDeniedAlert()
            }
        }
    }

    @MainActor
    private static func presentDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = L10n.tr("notification.denied.title")
        alert.informativeText = L10n.tr("notification.denied.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.tr("notification.denied.open_settings"))
        alert.addButton(withTitle: L10n.tr("notification.denied.later"))

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Deep link directly to the per-app notification pane. Bundle ID is
            // appended so System Settings opens at the right row instead of the
            // root notifications list.
            let bundleID = Bundle.main.bundleIdentifier ?? ""
            let urlString = "x-apple.systempreferences:com.apple.preference.notifications?id=\(bundleID)"
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    /// Show banner + play sound even when the app is foregrounded; otherwise macOS
    /// suppresses the visual entirely and the user only sees the entry in Notification
    /// Center after the fact.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// A banner that says "TaskTick is still running" is only useful if tapping it
    /// gets the user back to the window.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let wantsMainWindow = response.notification.request.content
            .userInfo[Self.openMainWindowKey] as? Bool ?? false
        if wantsMainWindow, response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            DispatchQueue.main.async {
                AppDelegate.bringMainWindowForward()
            }
        }
        completionHandler()
    }
}
