import Testing
import Foundation
@testable import TaskTickApp
@testable import TaskTickCore

@Suite("TaskScheduler Tests")
struct TaskSchedulerTests {

    @Test("Scheduler singleton exists")
    @MainActor
    func schedulerExists() {
        let scheduler = TaskScheduler.shared
        #expect(scheduler.isRunning == false)
    }

    // Regression for issue #30: a fresh task with no scheduledDate but a
    // sub-day repeat (every minute) used to land in the legacy interval
    // branch and return nil, blocking the scheduler from picking it up.
    @Test("Every-minute task without scheduledDate computes future nextRunAt")
    @MainActor
    func everyMinuteWithoutScheduledDateComputesNextRun() {
        let task = ScheduledTask(
            name: "issue-30",
            scriptBody: "echo hi",
            scheduledDate: nil,
            repeatType: .everyMinute
        )
        task.intervalSeconds = nil
        task.cronExpression = nil

        let anchor = Date()
        let next = TaskScheduler.shared.computeNextRunDate(for: task, after: anchor)

        #expect(next != nil)
        if let next {
            let delta = next.timeIntervalSince(anchor)
            #expect(delta > 0)
            #expect(delta <= 60)
        }
    }

    @Test("Legacy interval task still honors intervalSeconds")
    @MainActor
    func legacyIntervalTaskStillWorks() {
        let task = ScheduledTask(name: "legacy", scriptBody: "echo hi")
        task.scheduledDate = nil
        task.intervalSeconds = 300
        task.cronExpression = nil

        let anchor = Date()
        let next = TaskScheduler.shared.computeNextRunDate(for: task, after: anchor)

        #expect(next != nil)
        if let next {
            #expect(abs(next.timeIntervalSince(anchor) - 300) < 1)
        }
    }

    // Shortcut tasks share the same scheduling pipeline as shell tasks —
    // setting shortcutName must not block computeNextRunDate from picking
    // up a normal repeat schedule.
    @Test("Shortcut task with repeatType.everyMinute schedules normally")
    @MainActor
    func shortcutTaskRespectsRepeat() {
        let task = ScheduledTask(
            name: "shortcut",
            scriptBody: "",
            repeatType: .everyMinute
        )
        task.shortcutName = "MyShortcut"
        task.intervalSeconds = nil
        task.cronExpression = nil

        let anchor = Date()
        let next = TaskScheduler.shared.computeNextRunDate(for: task, after: anchor)

        #expect(next != nil)
        if let next {
            let delta = next.timeIntervalSince(anchor)
            #expect(delta > 0)
            #expect(delta <= 60)
        }
    }

    @Test("New ScheduledTask has nil shortcutName")
    @MainActor
    func shortcutNameDefaultsToNil() {
        let task = ScheduledTask(name: "fresh", scriptBody: "echo hi")
        #expect(task.shortcutName == nil)
    }
}
