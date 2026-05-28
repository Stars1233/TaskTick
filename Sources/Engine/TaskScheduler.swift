import AppKit
import Foundation
import SwiftData
import TaskTickCore

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
    /// Becomes true once the post-launch sweep has run. While false,
    /// `rebuildSchedule()` defers tasks with `runOnLaunch = true` so the launch
    /// sweep gets the first-fire (and `runMissedExecution` does not double-fire).
    private var hasFiredLaunchTasks = false

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

        // Fire onLaunch tasks once after a brief delay so app finishes booting
        // (model context, windows, etc.) before scripts run. See issue #25.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            Task { @MainActor in self?.fireLaunchTasks() }
        }
    }

    func stop() {
        masterTimer?.invalidate()
        masterTimer = nil
        isRunning = false
        hasFiredLaunchTasks = false
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
            // Defer runOnLaunch tasks until the launch sweep runs (issue #25).
            // Skipping here also prevents `runMissedExecution` from double-firing
            // them when both flags are set.
            if !hasFiredLaunchTasks && task.runOnLaunch { continue }

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

    // MARK: - Adoption Poll

    /// Polls every 30s to see whether any adopted process has exited.
    /// When one does, transition the corresponding log from .running to
    /// .cancelled and clear the runningTaskIDs entry. Cheap — typically
    /// 0-2 adopted processes; each probe is a single `kill(pid, 0)` syscall.
    private var adoptionPollTimer: Timer?

    @MainActor
    func startAdoptionPoll() {
        adoptionPollTimer?.invalidate()
        adoptionPollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollAdoptedProcesses() }
        }
    }

    @MainActor
    func stopAdoptionPoll() {
        adoptionPollTimer?.invalidate()
        adoptionPollTimer = nil
    }

    @MainActor
    private func pollAdoptedProcesses() {
        let snapshot = ScriptExecutor.shared.adoptedProcesses
        guard !snapshot.isEmpty, let ctx = modelContext else { return }
        let now = Date()
        for (taskID, pid) in snapshot {
            if ProcessReconciler.isAlive(pid: pid) { continue }
            ScriptExecutor.shared.adoptedProcesses.removeValue(forKey: taskID)
            runningTaskIDs.remove(taskID)

            // Mark the most recent running log for this task as cancelled.
            let runningRaw = ExecutionStatus.running.rawValue
            let descriptor = FetchDescriptor<ExecutionLog>(
                predicate: #Predicate { $0.statusRaw == runningRaw && $0.task?.id == taskID }
            )
            if let log = try? ctx.fetch(descriptor).first {
                log.status = .cancelled
                log.finishedAt = now
                if log.durationMs == nil {
                    log.durationMs = Int(now.timeIntervalSince(log.startedAt) * 1000)
                }
                if (log.stderr ?? "").isEmpty {
                    log.stderr = "[TaskTick] Adopted process \(pid) exited externally."
                }
            }
        }
        do { try ctx.save() } catch { NSLog("⚠️ TaskScheduler save failed: \(error)") }
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
            // Defer runOnLaunch tasks until the launch sweep runs (issue #25).
            if !hasFiredLaunchTasks && task.runOnLaunch { continue }

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

    /// Fires every enabled task with `runOnLaunch == true` exactly once per
    /// `start()` cycle. Called 3s after `start()`. After this runs,
    /// `hasFiredLaunchTasks` flips to true so `rebuildSchedule()` resumes
    /// processing those tasks normally for the rest of the session.
    private func fireLaunchTasks() {
        defer {
            hasFiredLaunchTasks = true
            rebuildSchedule()
        }
        guard isRunning, let modelContext else { return }

        let descriptor = FetchDescriptor<ScheduledTask>(
            predicate: #Predicate { $0.isEnabled && $0.runOnLaunch && !$0.isManualOnly }
        )
        guard let tasks = try? modelContext.fetch(descriptor) else { return }

        for task in tasks {
            fireTask(task, triggeredBy: .launch)
        }
    }

    private func fireTask(_ task: ScheduledTask, triggeredBy: TriggerType = .schedule) {
        let taskId = task.id
        guard !runningTaskIDs.contains(taskId), let modelContext else { return }

        runningTaskIDs.insert(taskId)

        // Sync executionCount with actual log count, skipping invalidated references
        let validLogCount = task.executionLogs.filter { $0.modelContext != nil }.count
        task.executionCount = validLogCount + 1 // +1 for current execution

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
            await ScriptExecutor.shared.execute(task: task, triggeredBy: triggeredBy, modelContext: modelContext)
            runningTaskIDs.remove(taskId)
            rebuildSchedule()
        }
    }

    func computeNextRunDate(for task: ScheduledTask, after date: Date = Date()) -> Date? {
        // Manual-only tasks never schedule themselves
        if task.isManualOnly {
            return nil
        }

        // Check end repeat count first (applies to all schedule types)
        // Use executionLogs.count as source of truth for completed executions
        if task.endRepeatType == .afterCount,
           let maxCount = task.endRepeatCount,
           task.executionLogs.filter({ $0.modelContext != nil }).count >= maxCount {
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

        // Legacy interval support — only matches tasks that actually carry a
        // legacy `intervalSeconds`. New-system tasks share `scheduleType="interval"`
        // as an init default, so without this guard a new task with no
        // scheduledDate (date/time toggles off) would fall in here and return
        // nil, blocking auto-execution. See issue #30.
        if task.schedule == .interval, task.scheduledDate == nil,
           let interval = task.intervalSeconds, interval > 0 {
            return date.addingTimeInterval(TimeInterval(interval))
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

        // Multi-time-of-day path: a single occurrence may fire at several times
        // per day (issue #34). Only day-aligned RepeatTypes carry extras —
        // sub-day / monthly+ types skip this branch and stay on the original
        // single-time stepping below.
        if repeatType.supportsAdditionalTimes && !task.additionalTimes.isEmpty {
            return nextRunWithAdditionalTimes(
                for: task,
                after: date,
                scheduledDate: scheduledDate,
                repeatType: repeatType,
                intervalComponent: intervalComponent,
                intervalValue: intervalValue,
                calendar: calendar
            )
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
            if let maxCount = task.endRepeatCount,
               task.executionLogs.filter({ $0.modelContext != nil }).count >= maxCount {
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

    /// Multi-time-of-day occurrence walker. For each candidate day, evaluates
    /// `[scheduledTime] + additionalTimes` and returns the earliest fire that
    /// is strictly after `date` and not before `scheduledDate`. Steps forward
    /// by `intervalComponent` / `intervalValue` between days, applying weekday
    /// /weekend filtering for those RepeatTypes. Bounded iteration so a bogus
    /// end-date / pathological config can never spin the scheduler.
    private func nextRunWithAdditionalTimes(
        for task: ScheduledTask,
        after date: Date,
        scheduledDate: Date,
        repeatType: RepeatType,
        intervalComponent: Calendar.Component,
        intervalValue: Int,
        calendar: Calendar
    ) -> Date? {
        var timesOfDay: [DateComponents] = []
        let mainComponents = calendar.dateComponents([.hour, .minute], from: scheduledDate)
        timesOfDay.append(mainComponents)
        for extra in task.additionalTimes {
            if !timesOfDay.contains(where: { $0.hour == extra.hour && $0.minute == extra.minute }) {
                timesOfDay.append(extra)
            }
        }

        var occurrenceDay = calendar.startOfDay(for: scheduledDate)
        let logCount = task.executionLogs.filter { $0.modelContext != nil }.count

        // ~2 years of daily steps, ~15 years of weekly. Pathological configs
        // (e.g. end-on-date in the distant past with stride misaligned) bail
        // out rather than spinning forever.
        for _ in 0..<800 {
            let weekday = calendar.component(.weekday, from: occurrenceDay)
            let dayValid: Bool = switch repeatType {
            case .weekdays: (2...6).contains(weekday)
            case .weekends: weekday == 1 || weekday == 7
            default: true
            }

            if dayValid {
                let dayCandidates: [Date] = timesOfDay.compactMap { tc in
                    var c = calendar.dateComponents([.year, .month, .day], from: occurrenceDay)
                    c.hour = tc.hour
                    c.minute = tc.minute
                    c.second = 0
                    return calendar.date(from: c)
                }
                if let earliest = dayCandidates.filter({ $0 > date && $0 >= scheduledDate }).min() {
                    switch task.endRepeatType {
                    case .never:
                        return earliest
                    case .onDate:
                        if let endDate = task.endRepeatDate, earliest > endDate { return nil }
                        return earliest
                    case .afterCount:
                        if let maxCount = task.endRepeatCount, logCount >= maxCount { return nil }
                        return earliest
                    }
                }
            }

            guard let nextDay = calendar.date(byAdding: intervalComponent, value: intervalValue, to: occurrenceDay) else {
                return nil
            }
            occurrenceDay = nextDay
            if task.endRepeatType == .onDate,
               let endDate = task.endRepeatDate,
               occurrenceDay > endDate {
                return nil
            }
        }
        return nil
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
