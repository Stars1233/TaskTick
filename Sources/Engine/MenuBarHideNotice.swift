import AppKit
import Foundation
import TaskTickCore

/// The banner fired when the last window closes and the app drops to the menu bar.
/// Closing the red button looks exactly like a quit, so without it users go hunting
/// for TaskTick in the Dock and assume their schedules died with the window.
@MainActor
enum MenuBarHideNotice {

    /// Per-user opt-out, default on. Still gated by the global `notificationsEnabled`.
    static let settingKey = "notifyOnHideToMenuBar"

    /// Both hide paths can land in the same run loop turn: the quit dialog's
    /// "Hide in Menu Bar" closes the windows itself, which then reaches
    /// `applicationShouldTerminateAfterLastWindowClosed`. One banner is enough —
    /// and a hide the user just picked from a dialog needs none at all.
    private static var suppressedUntil: Date?

    static func suppressBriefly() {
        suppressedUntil = Date().addingTimeInterval(2)
    }

    static func fire(defaults: UserDefaults = .standard) {
        if let until = suppressedUntil, Date() < until { return }
        suppressBriefly()

        let globalEnabled = defaults.object(forKey: "notificationsEnabled") as? Bool ?? true
        let noticeEnabled = defaults.object(forKey: settingKey) as? Bool ?? true
        guard globalEnabled, noticeEnabled else { return }

        let hasMenuBarIcon = defaults.object(forKey: "showMenuBarIcon") as? Bool ?? true
        let (title, body) = content(hasMenuBarIcon: hasMenuBarIcon)
        NotificationManager.shared.sendNotification(
            title: title,
            body: body,
            userInfo: [NotificationManager.openMainWindowKey: true]
        )
    }

    /// Pure helper used by tests — renders the strings without sending.
    /// With the menu bar icon turned off there's no visible trace of the app left,
    /// so that variant has to name a way back in.
    static func content(hasMenuBarIcon: Bool) -> (title: String, body: String) {
        hasMenuBarIcon
            ? (L10n.tr("notification.hidden.title"), L10n.tr("notification.hidden.body"))
            : (L10n.tr("notification.hidden.no_icon.title"), L10n.tr("notification.hidden.no_icon.body"))
    }
}
