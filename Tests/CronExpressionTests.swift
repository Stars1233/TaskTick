import Testing
@testable import TaskTick

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
}
