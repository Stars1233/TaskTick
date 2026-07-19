import Testing
import Foundation
@testable import TaskTickApp
@testable import TaskTickCore

// Issue #41: per-task time zone. Wall-clock times of a schedule are interpreted
// in the task's `timeZoneIdentifier` when set, instead of the system time zone.
@Suite("Per-task time zone scheduling")
struct TimeZoneSchedulingTests {

    private func calendar(_ identifier: String) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: identifier)!
        return cal
    }

    private func date(_ cal: Calendar, _ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: 0))!
    }

    @Test("scheduleTimeZone roundtrips and defaults to nil (follow system)")
    @MainActor
    func timeZoneRoundtrip() {
        let task = ScheduledTask(name: "tz", scriptBody: "echo hi")
        #expect(task.timeZoneIdentifier == nil)
        #expect(task.scheduleTimeZone == nil)
        #expect(task.scheduleCalendar.timeZone == TimeZone.current)

        task.scheduleTimeZone = TimeZone(identifier: "Asia/Tokyo")
        #expect(task.timeZoneIdentifier == "Asia/Tokyo")
        #expect(task.scheduleTimeZone?.identifier == "Asia/Tokyo")
        #expect(task.scheduleCalendar.timeZone.identifier == "Asia/Tokyo")
    }

    @Test("Unknown identifier degrades to system time zone, not a crash or freeze")
    @MainActor
    func invalidIdentifierDegrades() {
        let task = ScheduledTask(name: "tz-bad", scriptBody: "echo hi", repeatType: .daily)
        task.timeZoneIdentifier = "Not/AZone"
        #expect(task.scheduleTimeZone == nil)
        #expect(task.scheduleCalendar.timeZone == TimeZone.current)

        // Scheduling still works (falls back to system-tz interpretation).
        let next = TaskScheduler.shared.computeNextRunDate(for: task, after: Date())
        #expect(next != nil)
    }

    @Test("Daily task keeps its wall-clock hour in the task's zone")
    @MainActor
    func dailyTaskFiresAtTaskZoneWallClock() {
        let tokyo = calendar("Asia/Tokyo")
        // Anchored: daily at 09:00 Tokyo, starting 2026-01-05.
        let scheduled = date(tokyo, 2026, 1, 5, 9, 0)
        let task = ScheduledTask(
            name: "tz-daily",
            scriptBody: "echo hi",
            scheduledDate: scheduled,
            repeatType: .daily
        )
        task.timeZoneIdentifier = "Asia/Tokyo"

        // "Now" = 2026-01-10 13:30 Tokyo → next fire must be 2026-01-11 09:00 Tokyo.
        let now = date(tokyo, 2026, 1, 10, 13, 30)
        let next = TaskScheduler.shared.computeNextRunDate(for: task, after: now)
        #expect(next == date(tokyo, 2026, 1, 11, 9, 0))
    }

    @Test("DST spring-forward: wall clock stays put in the task's zone")
    @MainActor
    func dstSpringForwardKeepsWallClock() {
        let newYork = calendar("America/New_York")
        // US DST began 2026-03-08 02:00. Daily 09:00 New York across the gap.
        let scheduled = date(newYork, 2026, 3, 7, 9, 0)  // EST (UTC-5)
        let task = ScheduledTask(
            name: "tz-dst",
            scriptBody: "echo hi",
            scheduledDate: scheduled,
            repeatType: .daily
        )
        task.timeZoneIdentifier = "America/New_York"

        let now = date(newYork, 2026, 3, 7, 10, 0)
        let next = TaskScheduler.shared.computeNextRunDate(for: task, after: now)
        #expect(next != nil)
        if let next {
            // Still 09:00 on the NY wall clock (EDT, UTC-4)...
            #expect(newYork.component(.hour, from: next) == 9)
            #expect(newYork.component(.day, from: next) == 8)
            // ...which is only 23 real hours after the previous fire.
            #expect(next.timeIntervalSince(scheduled) == 23 * 3600)
        }
    }

    @Test("DST gap day fires at the adjusted time, then recovers the wall clock")
    @MainActor
    func dstGapDayAdjustsThenRecovers() {
        let newYork = calendar("America/New_York")
        // Daily 02:30 New York. 2026-03-08 has no 02:30 (spring-forward gap).
        let scheduled = date(newYork, 2026, 3, 6, 2, 30)
        let task = ScheduledTask(
            name: "tz-dst-gap",
            scriptBody: "echo hi",
            scheduledDate: scheduled,
            repeatType: .daily
        )
        task.timeZoneIdentifier = "America/New_York"

        // Gap day itself: 02:30 doesn't exist → adjusted forward to 03:30 EDT.
        let beforeGap = date(newYork, 2026, 3, 7, 3, 0)
        let onGapDay = TaskScheduler.shared.computeNextRunDate(for: task, after: beforeGap)
        #expect(onGapDay != nil)
        if let onGapDay {
            #expect(newYork.component(.day, from: onGapDay) == 8)
            #expect(newYork.component(.hour, from: onGapDay) == 3)
            #expect(newYork.component(.minute, from: onGapDay) == 30)
        }

        // The day after must return to 02:30 — no permanent drift.
        let afterGap = date(newYork, 2026, 3, 8, 4, 0)
        let recovered = TaskScheduler.shared.computeNextRunDate(for: task, after: afterGap)
        #expect(recovered != nil)
        if let recovered {
            #expect(newYork.component(.day, from: recovered) == 9)
            #expect(newYork.component(.hour, from: recovered) == 2)
            #expect(newYork.component(.minute, from: recovered) == 30)
        }
    }

    @Test("Weekday skip across a DST gap keeps the wall clock")
    @MainActor
    func weekdaySkipAcrossGapKeepsWallClock() {
        let newYork = calendar("America/New_York")
        // Weekdays-only 02:30 NY; gap Sunday 2026-03-08 sits inside the skip.
        let scheduled = date(newYork, 2026, 3, 6, 2, 30)  // Friday
        let task = ScheduledTask(
            name: "tz-dst-weekday",
            scriptBody: "echo hi",
            scheduledDate: scheduled,
            repeatType: .weekdays
        )
        task.timeZoneIdentifier = "America/New_York"

        // After Saturday: next weekday fire is Monday 03-09 at 02:30, not 03:30.
        let now = date(newYork, 2026, 3, 7, 10, 0)
        let next = TaskScheduler.shared.computeNextRunDate(for: task, after: now)
        #expect(next != nil)
        if let next {
            #expect(newYork.component(.day, from: next) == 9)
            #expect(newYork.component(.hour, from: next) == 2)
            #expect(newYork.component(.minute, from: next) == 30)
        }
    }

    @Test("DST fall-back day fires once at the configured wall clock")
    @MainActor
    func dstFallBackFiresOnceAtWallClock() {
        let newYork = calendar("America/New_York")
        // Daily 01:30 NY. 2026-11-01 repeats 01:00–02:00 (fall-back).
        let scheduled = date(newYork, 2026, 10, 30, 1, 30)
        let task = ScheduledTask(
            name: "tz-dst-fallback",
            scriptBody: "echo hi",
            scheduledDate: scheduled,
            repeatType: .daily
        )
        task.timeZoneIdentifier = "America/New_York"

        let now = date(newYork, 2026, 10, 31, 2, 0)
        let next = TaskScheduler.shared.computeNextRunDate(for: task, after: now)
        #expect(next != nil)
        if let next {
            #expect(newYork.component(.day, from: next) == 1)
            #expect(newYork.component(.hour, from: next) == 1)
            #expect(newYork.component(.minute, from: next) == 30)
            // And the following day steps cleanly past the repeated hour.
            let after = TaskScheduler.shared.computeNextRunDate(for: task, after: next)
            #expect(after != nil)
            if let after {
                #expect(newYork.component(.day, from: after) == 2)
                #expect(newYork.component(.hour, from: after) == 1)
                #expect(newYork.component(.minute, from: after) == 30)
            }
        }
    }

    @Test("Additional times are evaluated in the task's zone")
    @MainActor
    func additionalTimesUseTaskZone() {
        let tokyo = calendar("Asia/Tokyo")
        let scheduled = date(tokyo, 2026, 1, 5, 9, 0)
        let task = ScheduledTask(
            name: "tz-extras",
            scriptBody: "echo hi",
            scheduledDate: scheduled,
            repeatType: .daily
        )
        task.timeZoneIdentifier = "Asia/Tokyo"
        task.additionalTimes = [DateComponents(hour: 18, minute: 30)]

        // Now = 2026-01-10 10:00 Tokyo → today's 18:30 Tokyo slot is next.
        let now = date(tokyo, 2026, 1, 10, 10, 0)
        let next = TaskScheduler.shared.computeNextRunDate(for: task, after: now)
        #expect(next == date(tokyo, 2026, 1, 10, 18, 30))
    }

    @Test("Cron expressions honor the task's zone")
    @MainActor
    func cronUsesTaskZone() throws {
        let tokyo = calendar("Asia/Tokyo")
        let cron = try CronExpression(parsing: "0 9 * * *")
        let now = date(tokyo, 2026, 1, 10, 13, 30)
        let next = cron.nextFireDate(after: now, calendar: tokyo)
        #expect(next == date(tokyo, 2026, 1, 11, 9, 0))
    }

    @Test("Nil time zone preserves existing system-zone behavior")
    @MainActor
    func nilTimeZoneMatchesSystemBehavior() {
        let system = Calendar.current
        var comps = system.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 9
        comps.minute = 0
        comps.second = 0
        let scheduled = system.date(from: comps)!

        let task = ScheduledTask(
            name: "tz-nil",
            scriptBody: "echo hi",
            scheduledDate: scheduled,
            repeatType: .daily
        )
        // timeZoneIdentifier left nil.
        let next = TaskScheduler.shared.computeNextRunDate(for: task, after: Date())
        #expect(next != nil)
        if let next {
            #expect(system.component(.hour, from: next) == 9)
            #expect(system.component(.minute, from: next) == 0)
        }
    }
}
