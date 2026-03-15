import Foundation
import UserNotifications

/// Manages system notifications for task execution results.
final class NotificationManager: @unchecked Sendable {

    static let shared = NotificationManager()

    private var isAvailable = false

    private init() {}

    func requestPermission() {
        // UNUserNotificationCenter requires a valid app bundle with bundle identifier.
        // When running via `swift run`, no bundle exists and this will crash.
        guard Bundle.main.bundleIdentifier != nil else {
            print("[NotificationManager] No bundle identifier — notifications disabled.")
            return
        }

        isAvailable = true
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
