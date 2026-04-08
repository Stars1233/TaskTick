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
        guard !isRunning else { return }
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
            do { try modelContext.save() } catch { NSLog("⚠️ TaskScheduler save failed: \(error)") }
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
                let overdueSeconds = now.timeIntervalSince(nextRun)
                if overdueSeconds <= 60 || task.runMissedExecution {
                    // On-time (within 60s tolerance) or missed with runMissedExecution enabled
                    fireTask(task)
                } else {
                    // Missed execution without runMissedExecution, skip to next
                    let nextDate = computeNextRunDate(for: task, after: now)
                    task.nextRunAt = nextDate
                    do { try modelContext.save() } catch { NSLog("⚠️ TaskScheduler save failed: \(error)") }
                    if let nextDate, nextDate < (earliest ?? .distantFuture) {
                        earliest = nextDate
                    }
                }
                continue
            }
            if nextRun < (earliest ?? .distantFuture) {
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
                let overdueSeconds = now.timeIntervalSince(nextRun)
                if overdueSeconds <= 60 || task.runMissedExecution {
                    fireTask(task)
                } else {
                    // Missed execution without runMissedExecution, skip to next
                    let nextDate = computeNextRunDate(for: task, after: now)
                    task.nextRunAt = nextDate
                    do { try modelContext.save() } catch { NSLog("⚠️ TaskScheduler save failed: \(error)") }
                }
            }
        }

        rebuildSchedule()
    }

    private func fireTask(_ task: ScheduledTask) {
        let taskId = task.id
        guard !runningTaskIDs.contains(taskId), let modelContext else { return }

        runningTaskIDs.insert(taskId)

        // Sync executionCount with actual log count
        task.executionCount = task.executionLogs.count + 1 // +1 for current execution

        // Check end repeat count directly before computing next date
        if task.endRepeatType == .afterCount,
           let maxCount = task.endRepeatCount,
           task.executionCount >= maxCount {
            task.nextRunAt = nil
            task.isEnabled = false
        } else {
            // Compute next run date
            let nextDate = computeNextRunDate(for: task, after: Date())
            task.nextRunAt = nextDate
        }

        do {
            try modelContext.save()
        } catch {
            NSLog("⚠️ Failed to save before task execution: \(error)")
        }

        Task { @MainActor in
            await ScriptExecutor.shared.execute(task: task, triggeredBy: .schedule, modelContext: modelContext)
            runningTaskIDs.remove(taskId)
            rebuildSchedule()
        }
    }

    func computeNextRunDate(for task: ScheduledTask, after date: Date = Date()) -> Date? {
        // Check end repeat count first (applies to all schedule types)
        // Use executionLogs.count as source of truth for completed executions
        if task.endRepeatType == .afterCount,
           let maxCount = task.endRepeatCount,
           task.executionLogs.count >= maxCount {
            return nil
        }
        if task.endRepeatType == .onDate,
           let endDate = task.endRepeatDate,
           date >= endDate {
            return nil
        }

        // Legacy cron support
        if task.schedule == .cron, let expr = task.cronExpression {
            if let cron = try? CronExpression(parsing: expr) {
                return cron.nextFireDate(after: date)
            }
            return nil
        }

        // Legacy interval support
        if task.schedule == .interval, task.scheduledDate == nil {
            if let interval = task.intervalSeconds, interval > 0 {
                return date.addingTimeInterval(TimeInterval(interval))
            }
            return nil
        }

        // New schedule system
        // If no scheduledDate but has a repeat type, use current time as base
        let scheduledDate: Date
        if let sd = task.scheduledDate {
            scheduledDate = sd
        } else if task.repeatType != .never {
            scheduledDate = date
        } else {
            return nil
        }

        let repeatType = task.repeatType
        let calendar = Calendar.current

        // Non-repeating: just the scheduled date if in the future
        if repeatType == .never {
            return scheduledDate > date ? scheduledDate : nil
        }

        // Determine interval
        let intervalComponent: Calendar.Component
        let intervalValue: Int

        if repeatType == .custom {
            intervalComponent = task.customIntervalUnit.calendarComponent
            intervalValue = max(task.customIntervalValue, 1)
        } else if let ci = repeatType.calendarInterval {
            intervalComponent = ci.component
            intervalValue = ci.value
        } else {
            return nil
        }

        // If scheduled date is still in the future, use it
        if scheduledDate > date {
            if repeatType == .weekdays {
                return nextWeekday(from: scheduledDate, calendar: calendar)
            } else if repeatType == .weekends {
                return nextWeekend(from: scheduledDate, calendar: calendar)
            }
            return scheduledDate
        }

        // Compute next occurrence by stepping forward from scheduledDate
        var candidate = scheduledDate
        while candidate <= date {
            guard let next = calendar.date(byAdding: intervalComponent, value: intervalValue, to: candidate) else {
                return nil
            }
            candidate = next
        }

        // For weekdays/weekends, skip to valid day
        if repeatType == .weekdays {
            candidate = nextWeekday(from: candidate, calendar: calendar) ?? candidate
        } else if repeatType == .weekends {
            candidate = nextWeekend(from: candidate, calendar: calendar) ?? candidate
        }

        // Check end conditions
        switch task.endRepeatType {
        case .never:
            return candidate
        case .onDate:
            if let endDate = task.endRepeatDate, candidate > endDate {
                return nil
            }
            return candidate
        case .afterCount:
            if let maxCount = task.endRepeatCount, task.executionLogs.count >= maxCount {
                return nil
            }
            return candidate
        }
    }

    private func nextWeekday(from date: Date, calendar: Calendar) -> Date? {
        var d = date
        for _ in 0..<7 {
            let weekday = calendar.component(.weekday, from: d)
            if weekday >= 2 && weekday <= 6 { return d } // Mon-Fri
            d = calendar.date(byAdding: .day, value: 1, to: d) ?? d
        }
        return d
    }

    private func nextWeekend(from date: Date, calendar: Calendar) -> Date? {
        var d = date
        for _ in 0..<7 {
            let weekday = calendar.component(.weekday, from: d)
            if weekday == 1 || weekday == 7 { return d } // Sun or Sat
            d = calendar.date(byAdding: .day, value: 1, to: d) ?? d
        }
        return d
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
