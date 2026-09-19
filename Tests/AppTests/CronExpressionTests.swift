import Foundation
import Testing
@testable import TaskTickApp
import TaskTickCore

@Suite("CronExpression Tests")
struct CronExpressionTests {

    @Test("Parse every minute")
    func parseEveryMinute() throws {
        let cron = try CronExpression(parsing: "* * * * *")
        #expect(cron.minute == .any)
        #expect(cron.hour == .any)
        #expect(cron.dayOfMonth == .any)
        #expect(cron.month == .any)
        #expect(cron.dayOfWeek == .any)
    }

    @Test("Parse step expression")
    func parseStep() throws {
        let cron = try CronExpression(parsing: "*/5 * * * *")
        #expect(cron.minute == .step(5))
    }

    @Test("Parse specific value")
    func parseValue() throws {
        let cron = try CronExpression(parsing: "30 8 * * *")
        #expect(cron.minute == .value(30))
        #expect(cron.hour == .value(8))
    }

    @Test("Parse range")
    func parseRange() throws {
        let cron = try CronExpression(parsing: "0 9-17 * * *")
        #expect(cron.hour == .range(9, 17))
    }

    @Test("Invalid format throws")
    func invalidFormat() {
        #expect(throws: CronExpression.ParseError.self) {
            try CronExpression(parsing: "* * *")
        }
    }

    @Test("Value out of range throws")
    func valueOutOfRange() {
        #expect(throws: CronExpression.ParseError.self) {
            try CronExpression(parsing: "60 * * * *")
        }
    }

    @Test("Next fire date calculation")
    func nextFireDate() throws {
        let cron = try CronExpression(parsing: "* * * * *")
        let next = cron.nextFireDate()
        #expect(next != nil)
    }

    @Test("Human readable presets")
    func humanReadable() throws {
        let cron = try CronExpression(parsing: "* * * * *")
        #expect(cron.humanReadable == "每分钟")

        let hourly = try CronExpression(parsing: "0 * * * *")
        #expect(hourly.humanReadable == "每小时")
    }

    /// The expression from issue #53 — a minute step, an hour range and a
    /// weekday range composed in one expression, which the repeat picker can't
    /// express. Pinned to a fixed zone so the test doesn't read the host's.
    @Test("Weekday window: Saturday rolls forward to Monday's first slot")
    func weekdayWindowSkipsWeekend() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))

        let cron = try CronExpression(parsing: "*/10 9-19 * * 1-5")
        let saturday = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 19, hour: 18, minute: 34)))

        let next = try #require(cron.nextFireDate(after: saturday, calendar: calendar))
        let got = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: next)
        #expect(got.year == 2026)
        #expect(got.month == 9)
        #expect(got.day == 21) // Monday
        #expect(got.hour == 9)
        #expect(got.minute == 0)
    }

    @Test("Weekday window: steps by 10 minutes inside the window")
    func weekdayWindowStepsInsideWindow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))

        let cron = try CronExpression(parsing: "*/10 9-19 * * 1-5")
        // Monday 09:05 → next slot is 09:10, not the top of the next hour.
        let monday = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 21, hour: 9, minute: 5)))

        let next = try #require(cron.nextFireDate(after: monday, calendar: calendar))
        let got = calendar.dateComponents([.day, .hour, .minute], from: next)
        #expect(got.day == 21)
        #expect(got.hour == 9)
        #expect(got.minute == 10)
    }

    /// `9-19` is inclusive on both ends, so the window runs to 19:50 — worth
    /// pinning down because "9-19" reads like it stops at 19:00.
    @Test("Weekday window: last slot of the day is 19:50")
    func weekdayWindowIncludesHour19() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))

        let cron = try CronExpression(parsing: "*/10 9-19 * * 1-5")
        let monday = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 21, hour: 19, minute: 45)))

        let next = try #require(cron.nextFireDate(after: monday, calendar: calendar))
        let got = calendar.dateComponents([.day, .hour, .minute], from: next)
        #expect(got.day == 21)
        #expect(got.hour == 19)
        #expect(got.minute == 50)
    }
}
