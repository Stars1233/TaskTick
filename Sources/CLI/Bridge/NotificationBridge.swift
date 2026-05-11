import AppKit
import Foundation
import SwiftData
import TaskTickCore

/// Distributed Notification helpers. Only post + observe primitives — the
/// command-specific logic stays in each Command class.
enum NotificationBridge {

    enum CLIAction: String {
        case run, stop, restart, reveal

        var notificationName: Notification.Name {
            // Dynamic per-bundle so the dev CLI (Bundle.main =
            // com.lifedever.TaskTick.dev) posts to the dev GUI listener
            // and not the release GUI's. Falls back to release ID when run
            // outside any .app (e.g. .build/debug/tasktick).
            let bundleId = BundleContext.bundleID
            return Notification.Name("\(bundleId).cli.\(rawValue)")
        }
    }

    /// Post a CLI → GUI command notification.
    static func post(action: CLIAction, taskId: UUID) {
        DistributedNotificationCenter.default().postNotificationName(
            action.notificationName,
            object: nil,
            userInfo: ["id": taskId.uuidString],
            deliverImmediately: true
        )
    }

    /// Post the multi-field `cli.create` notification. Unlike the simple
    /// action notifications above, create needs to ship the full task spec
    /// (name, script path, schedule, etc.) so the GUI can build a
    /// ScheduledTask on the other side.
    static func postCreate(payload: [String: Any]) {
        let bundleId = BundleContext.bundleID
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("\(bundleId).cli.create"),
            object: nil,
            userInfo: payload,
            deliverImmediately: true
        )
    }

    /// Best-effort snapshot of currently-running task IDs. CLI reads
    /// ExecutionLog rows where status == .running as a proxy for the GUI's
    /// in-memory runningTaskIDs. Stale by 1 fetch round-trip but correct
    /// after the GUI's last save. Phase 6 (tail/wait) augments with live
    /// notification subscription for real-time accuracy.
    @MainActor
    static func runningTaskIds(store: ReadOnlyStore) -> Set<UUID> {
        let descriptor = FetchDescriptor<ExecutionLog>(
            predicate: #Predicate { $0.statusRaw == "running" }
        )
        let logs = (try? store.container.mainContext.fetch(descriptor)) ?? []
        return Set(logs.compactMap { $0.task?.id })
    }
}
