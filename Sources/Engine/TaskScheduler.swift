import AppKit
import Foundation
import SwiftData

/// Master timer-based task scheduler.
/// Maintains a single timer that fires at the earliest `nextRunAt` across all enabled tasks.
@MainActor
final class TaskScheduler: ObservableObject {
    @Published var isRunning = false
    @Published var runningTaskIDs: Set<UUID> = []

    private var masterTimer: Timer?
    private var modelContext: ModelContext?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    static let shared = TaskScheduler()

    private init() {}

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func start() {
        guard let modelContext else { return }
        isRunning = true

        // Compute nextRunAt for all enabled tasks that don't have one
        let descriptor = FetchDescriptor<ScheduledTask>(
            predicate: #Predicate { $0.isEnabled }
        )
        if let tasks = try? modelContext.fetch(descriptor) {
            for task in tasks {
                if task.nextRunAt == nil {
                    task.nextRunAt = computeNextRunDate(for: task)
                }
            }
            try? modelContext.save()
        }

        rebuildSchedule()
        setupSleepWakeObservers()
    }

    func stop() {
        masterTimer?.invalidate()
        masterTimer = nil
        isRunning = false
        removeSleepWakeObservers()
    }

    func rebuildSchedule() {
        masterTimer?.invalidate()
        masterTimer = nil

        guard isRunning, let modelContext else { return }

        let descriptor = FetchDescriptor<ScheduledTask>(
            predicate: #Predicate { $0.isEnabled }
        )
        guard let tasks = try? modelContext.fetch(descriptor) else { return }

        // Find the earliest nextRunAt
        let now = Date()
        var earliest: Date?

        for task in tasks {
            guard let nextRun = task.nextRunAt else { continue }
            if nextRun <= now {
                // Task is overdue, execute it now
                fireTask(task)
                continue
            }
            if earliest == nil || nextRun < earliest! {
                earliest = nextRun
            }
        }

        guard let fireDate = earliest else { return }

        let interval = fireDate.timeIntervalSince(now)
        masterTimer = Timer.scheduledTimer(withTimeInterval: max(interval, 0.1), repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.timerFired()
            }
        }
    }

    // MARK: - Private

    private func timerFired() {
        guard let modelContext else { return }

        let now = Date()
        let descriptor = FetchDescriptor<ScheduledTask>(
            predicate: #Predicate { $0.isEnabled }
        )
        guard let tasks = try? modelContext.fetch(descriptor) else { return }

        for task in tasks {
            if let nextRun = task.nextRunAt, nextRun <= now {
                fireTask(task)
            }
        }

        rebuildSchedule()
    }

    private func fireTask(_ task: ScheduledTask) {
        let taskId = task.id
        guard !runningTaskIDs.contains(taskId), let modelContext else { return }

        runningTaskIDs.insert(taskId)

        // Compute next run date before executing
        task.nextRunAt = computeNextRunDate(for: task, after: Date())
        try? modelContext.save()

        Task {
            await ScriptExecutor.shared.execute(task: task, triggeredBy: .schedule, modelContext: modelContext)
            runningTaskIDs.remove(taskId)
            rebuildSchedule()
        }
    }

    func computeNextRunDate(for task: ScheduledTask, after date: Date = Date()) -> Date? {
        switch task.schedule {
        case .cron:
            guard let expr = task.cronExpression,
                  let cron = try? CronExpression(parsing: expr) else { return nil }
            return cron.nextFireDate(after: date)

        case .interval:
            guard let interval = task.intervalSeconds, interval > 0 else { return nil }
            return date.addingTimeInterval(TimeInterval(interval))
        }
    }

    // MARK: - Sleep/Wake

    private func setupSleepWakeObservers() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // After wake, check for missed tasks
                self?.rebuildSchedule()
            }
        }
    }

    private func removeSleepWakeObservers() {
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        wakeObserver = nil
    }
}
