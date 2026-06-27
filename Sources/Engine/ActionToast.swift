import Foundation
import TaskTickCore

/// Single entry point for "user just performed an action" banners.
/// Run/Stop/Restart success → fires UN banner. Reveal does NOT fire.
/// Failures (CLIBridge couldn't resolve a task etc.) also fire.
enum ActionToast {

    enum Event {
        case started(taskName: String)
        case stopped(taskName: String)
        case restarted(taskName: String)
        case failed(taskName: String?, reason: String)
    }

    /// Whether an action-feedback banner should fire. Requires the global
    /// `notificationsEnabled` switch (default on) AND the per-task opt-in
    /// `wantsBanner` (the task's `notifyOnAction`, default OFF). Task-less
    /// failure events pass `wantsBanner: true` so they still surface (subject
    /// to the global switch).
    static func isEnabled(wantsBanner: Bool, _ defaults: UserDefaults = .standard) -> Bool {
        let global = defaults.object(forKey: "notificationsEnabled") as? Bool ?? true
        return global && wantsBanner
    }

    /// Fire an action-feedback banner if enabled. `wantsBanner` is the task's
    /// per-task opt-in (`notifyOnAction`); defaults to true for task-less
    /// failure events.
    static func notify(_ event: Event, wantsBanner: Bool = true) {
        guard isEnabled(wantsBanner: wantsBanner) else { return }
        let (title, body) = previewContent(for: event)
        NotificationManager.shared.sendNotification(title: title, body: body)
    }

    /// Pure helper used by tests — renders the strings without sending.
    static func previewContent(for event: Event) -> (title: String, body: String) {
        switch event {
        case .started(let name):
            return (L10n.tr("toast.action.started"), name)
        case .stopped(let name):
            return (L10n.tr("toast.action.stopped"), name)
        case .restarted(let name):
            return (L10n.tr("toast.action.restarted"), name)
        case .failed(let name, let reason):
            let body = name.map { "\($0): \(reason)" } ?? reason
            return (L10n.tr("toast.action.failed"), body)
        }
    }
}
