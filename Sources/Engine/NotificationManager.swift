import Foundation
import UserNotifications

/// Manages system notifications for task execution results.
final class NotificationManager: NSObject, @unchecked Sendable {

    static let shared = NotificationManager()

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

    func sendNotification(title: String, body: String) {
        guard isAvailable else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
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
}
