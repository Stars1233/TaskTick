import Foundation
import Testing
@testable import TaskTickApp
import TaskTickCore

@Suite("Cron seconds field (issue #38)")
struct CronSecondsTests {

    @Test("5-field expressions have no seconds field")
    func fiveFieldNoSeconds() throws {
        let cron = try CronExpression(parsing: "*/5 * * * *")
        #expect(cron.seconds == nil)
    }

    @Test("6-field expression parses leading seconds")
    func sixFieldParsesSeconds() throws {
        let cron = try CronExpression(parsing: "*/10 * * * * *")
        #expect(cron.seconds == .step(10))
        #expect(cron.minute == .any)
        #expect(cron.dayOfWeek == .any)
    }

    @Test("Wrong field counts throw")
    func wrongFieldCounts() {
        #expect(throws: CronExpression.ParseError.self) {
            try CronExpression(parsing: "* * * *")
        }
        #expect(throws: CronExpression.ParseError.self) {
            try CronExpression(parsing: "* * * * * * *")
        }
    }

    @Test("Seconds value out of range throws")
    func secondsOutOfRange() {
        #expect(throws: CronExpression.ParseError.self) {
            try CronExpression(parsing: "60 * * * * *")
        }
    }

    @Test("Every-10-seconds fires within the current minute")
    func nextFireWithinCurrentMinute() throws {
        let cron = try CronExpression(parsing: "*/10 * * * * *")
        #expect(cron.nextFireDate(after: date(h: 10, m: 30, s: 3)) == date(h: 10, m: 30, s: 10))
    }

    @Test("Seconds roll over to the next matching minute")
    func nextFireRollsToNextMinute() throws {
        let cron = try CronExpression(parsing: "*/10 * * * * *")
        #expect(cron.nextFireDate(after: date(h: 10, m: 30, s: 55)) == date(h: 10, m: 31, s: 0))
    }

    @Test("Fixed second still ahead in the current matching minute")
    func fixedSecondCurrentMinute() throws {
        // Second 30 of minute 5, every hour.
        let cron = try CronExpression(parsing: "30 5 * * * *")
        #expect(cron.nextFireDate(after: date(h: 10, m: 5, s: 10)) == date(h: 10, m: 5, s: 30))
    }

    @Test("Fixed second rolls to the next matching minute once passed")
    func fixedSecondNextHour() throws {
        let cron = try CronExpression(parsing: "30 5 * * * *")
        #expect(cron.nextFireDate(after: date(h: 10, m: 6, s: 0)) == date(h: 11, m: 5, s: 30))
    }

    @Test("5-field behavior unchanged: fires at second 0 of the next minute")
    func fiveFieldFiresAtSecondZero() throws {
        let cron = try CronExpression(parsing: "* * * * *")
        #expect(cron.nextFireDate(after: date(h: 10, m: 30, s: 3)) == date(h: 10, m: 31, s: 0))
    }

    private func date(h: Int, m: Int, s: Int) -> Date {
        var c = DateComponents()
        c.year = 2026
        c.month = 7
        c.day = 6
        c.hour = h
        c.minute = m
        c.second = s
        return Calendar.current.date(from: c)!
    }
}

@Suite("Scheduling jitter (issue #38)")
struct JitterTests {

    @Test("Zero jitter returns the base unchanged")
    func zeroJitterIdentity() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(TaskScheduler.jittered(base, jitterSeconds: 0, taskID: UUID()) == base)
    }

    @Test("Offset stays within 0...jitter")
    func offsetWithinBounds() {
        let id = UUID()
        for i in 0..<500 {
            let base = Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 61)
            let jittered = TaskScheduler.jittered(base, jitterSeconds: 100, taskID: id)
            let offset = jittered.timeIntervalSince(base)
            #expect(offset >= 0)
            #expect(offset <= 100)
        }
    }

    @Test("Deterministic: same task + base never re-rolls")
    func deterministic() {
        let id = UUID()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let a = TaskScheduler.jittered(base, jitterSeconds: 100, taskID: id)
        let b = TaskScheduler.jittered(base, jitterSeconds: 100, taskID: id)
        #expect(a == b)
    }

    @Test("Different occurrences get varied offsets")
    func variedAcrossOccurrences() {
        let id = UUID()
        var offsets = Set<Int>()
        for i in 0..<100 {
            let base = Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 60)
            let jittered = TaskScheduler.jittered(base, jitterSeconds: 100, taskID: id)
            offsets.insert(Int(jittered.timeIntervalSince(base)))
        }
        // 100 occurrences drawing from 0...100: a stuck hash would yield 1.
        #expect(offsets.count > 10)
    }
}
