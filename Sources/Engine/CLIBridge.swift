import AppKit
import Foundation
import SwiftData
import TaskTickCore

/// Single entry point for CLI / URL-Scheme triggered actions. Both the
/// AppDelegate URL handler and the DistributedNotification observers route
/// here so the action vocabulary lives in exactly one place.
@MainActor
final class CLIBridge {

    static let shared = CLIBridge()

    enum Action: String {
        case run, stop, restart, reveal
    }

    /// Notification names: see spec §6.1
    /// Dynamic per-bundle so dev (`com.lifedever.TaskTick.dev`) and release
    /// (`com.lifedever.TaskTick`) running in parallel don't crosstalk.
    private static var bundlePrefix: String {
        BundleContext.bundleID
    }

    static var runNotification: Notification.Name     { Notification.Name("\(bundlePrefix).cli.run") }
    static var stopNotification: Notification.Name    { Notification.Name("\(bundlePrefix).cli.stop") }
    static var restartNotification: Notification.Name { Notification.Name("\(bundlePrefix).cli.restart") }
    static var revealNotification: Notification.Name  { Notification.Name("\(bundlePrefix).cli.reveal") }
    /// `cli.create` lives outside the Action enum because it carries a
    /// multi-field payload (name/script_path/shell/repeat/...) instead of
    /// a single taskId. See `handleCreate(userInfo:)`.
    static var createNotification: Notification.Name  { Notification.Name("\(bundlePrefix).cli.create") }

    private var modelContainer: ModelContainer?

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        registerObservers()
    }

    /// Called by AppDelegate.application(_:open:) on URL Scheme launches and
    /// by DistributedNotification observers below. Idempotent — safe to call
    /// the same action twice.
    func handle(action: Action, taskId: UUID) {
        guard let container = modelContainer else {
            NSLog("⚠️ CLIBridge: handle(\(action.rawValue)) called before configure()")
            ActionToast.notify(.failed(taskName: nil, reason: L10n.tr("toast.action.failed.notReady")))
            return
        }
        let context = container.mainContext
        let descriptor = FetchDescriptor<ScheduledTask>(predicate: #Predicate { $0.id == taskId })
        guard let task = try? context.fetch(descriptor).first else {
            NSLog("⚠️ CLIBridge: no task with id \(taskId)")
            ActionToast.notify(.failed(taskName: nil, reason: L10n.tr("toast.action.failed.taskNotFound")))
            return
        }

        switch action {
        case .run:
            // Already-running guard — match Quick Launcher's idempotent contract.
            guard !TaskScheduler.shared.runningTaskIDs.contains(task.id) else { return }
            Task { _ = await ScriptExecutor.shared.execute(task: task, modelContext: context) }
            ActionToast.notify(.started(taskName: task.name))
        case .stop:
            ScriptExecutor.shared.cancel(taskId: task.id)
            ActionToast.notify(.stopped(taskName: task.name))
        case .restart:
            let wasRunning = TaskScheduler.shared.runningTaskIDs.contains(task.id)
            if wasRunning { ScriptExecutor.shared.cancel(taskId: task.id) }
            Task {
                if wasRunning { try? await Task.sleep(for: .milliseconds(200)) }
                _ = await ScriptExecutor.shared.execute(task: task, modelContext: context)
            }
            ActionToast.notify(.restarted(taskName: task.name))
        case .reveal:
            MainWindowSelection.shared.taskToReveal = task
            NotificationCenter.default.post(name: .revealTaskInMain, object: nil)
            NSApp.activate(ignoringOtherApps: true)
            // No toast — reveal's feedback is the window opening.
        }
    }

    /// Parse `tasktick://run?id=<uuid>` into (action, uuid). Returns nil for
    /// malformed URLs.
    func parse(url: URL) -> (action: Action, taskId: UUID)? {
        guard url.scheme == "tasktick",
              let host = url.host,
              let action = Action(rawValue: host),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let idItem = comps.queryItems?.first(where: { $0.name == "id" }),
              let idString = idItem.value,
              let uuid = UUID(uuidString: idString) else {
            return nil
        }
        return (action, uuid)
    }

    // MARK: - DistributedNotification observers

    private func registerObservers() {
        let center = DistributedNotificationCenter.default()
        let table: [(Notification.Name, Action)] = [
            (Self.runNotification,     .run),
            (Self.stopNotification,    .stop),
            (Self.restartNotification, .restart),
            (Self.revealNotification,  .reveal)
        ]
        for (name, action) in table {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let idString = note.userInfo?["id"] as? String,
                      let uuid = UUID(uuidString: idString) else { return }
                Task { @MainActor in self?.handle(action: action, taskId: uuid) }
            }
        }
        center.addObserver(forName: Self.createNotification, object: nil, queue: .main) { [weak self] note in
            // Extract every primitive synchronously on the main queue so the
            // Task closure only captures Sendable values (Swift 6 strict
            // concurrency forbids hopping non-Sendable [AnyHashable: Any]
            // across actor boundaries).
            let info = note.userInfo ?? [:]
            let spec = CreateSpec(
                idStr: info["id"] as? String,
                name: info["name"] as? String,
                scriptPath: info["script_path"] as? String,
                shell: info["shell"] as? String,
                cwd: info["cwd"] as? String,
                timeout: info["timeout"] as? Int,
                isManual: info["manual"] as? Bool,
                isEnabled: info["enabled"] as? Bool,
                repeatRaw: info["repeat"] as? String,
                scheduledAt: info["scheduled_at"] as? Double
            )
            Task { @MainActor in self?.handleCreate(spec: spec) }
        }
    }

    /// Sendable snapshot of the create-notification payload. All primitives
    /// so it can cross actor boundaries cleanly.
    struct CreateSpec: Sendable {
        let idStr: String?
        let name: String?
        let scriptPath: String?
        let shell: String?
        let cwd: String?
        let timeout: Int?
        let isManual: Bool?
        let isEnabled: Bool?
        let repeatRaw: String?
        let scheduledAt: Double?
    }

    /// Build a ScheduledTask from the CLI-supplied payload, persist it, and
    /// rebuild the scheduler.
    private func handleCreate(spec: CreateSpec) {
        guard let container = modelContainer,
              let idStr = spec.idStr,
              let id = UUID(uuidString: idStr),
              let name = spec.name,
              let scriptPath = spec.scriptPath else {
            NSLog("⚠️ CLIBridge.handleCreate: missing required fields")
            return
        }

        let shell = spec.shell ?? "/bin/zsh"
        let cwd = spec.cwd
        let timeout = spec.timeout ?? -1
        let isManual = spec.isManual ?? false
        let isEnabled = spec.isEnabled ?? true
        let repeatRaw = spec.repeatRaw ?? RepeatType.never.rawValue
        let scheduledAt = spec.scheduledAt.map { Date(timeIntervalSince1970: $0) }

        let repeatType = RepeatType(rawValue: repeatRaw) ?? .never

        let context = container.mainContext

        // Guard against double-create (e.g. CLI retried because polling
        // didn't see the task fast enough — idempotent on UUID).
        let existing = try? context.fetch(FetchDescriptor<ScheduledTask>(predicate: #Predicate { $0.id == id })).first
        if existing != nil {
            return
        }

        let task = ScheduledTask(
            name: name,
            shell: shell,
            scheduledDate: scheduledAt,
            repeatType: repeatType,
            isEnabled: isEnabled,
            workingDirectory: cwd,
            timeoutSeconds: timeout
        )
        task.id = id
        task.scriptFilePath = scriptPath
        task.isManualOnly = isManual

        context.insert(task)
        do {
            try context.save()
        } catch {
            NSLog("⚠️ CLIBridge.handleCreate: save failed: \(error)")
            return
        }

        if isEnabled && !isManual {
            task.nextRunAt = TaskScheduler.shared.computeNextRunDate(for: task)
            try? context.save()
            TaskScheduler.shared.rebuildSchedule()
        }
    }
}
