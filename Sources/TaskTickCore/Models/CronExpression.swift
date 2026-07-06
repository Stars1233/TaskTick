import Foundation

/// Cron expression parser supporting standard 5-field format:
/// minute hour dayOfMonth month dayOfWeek
/// plus an extended 6-field format with a leading seconds field (Quartz style):
/// second minute hour dayOfMonth month dayOfWeek — see issue #38.
public struct CronExpression: Sendable {
    /// nil for 5-field expressions, which fire at second 0 of each matching
    /// minute (classic cron behavior, unchanged).
    public let seconds: CronField?
    public let minute: CronField
    public let hour: CronField
    public let dayOfMonth: CronField
    public let month: CronField
    public let dayOfWeek: CronField

    public let raw: String

    public enum CronField: Sendable, Equatable {
        case any                          // *
        case step(Int)                    // */N
        case value(Int)                   // N
        case range(Int, Int)              // N-M
        case list([CronFieldEntry])       // N,M,O or combined

        public enum CronFieldEntry: Sendable, Equatable {
            case value(Int)
            case range(Int, Int)
            case step(Int)
        }
    }

    public enum ParseError: Error, LocalizedError {
        case invalidFormat(String)
        case invalidField(String, String)
        case valueOutOfRange(field: String, value: Int, range: ClosedRange<Int>)

        public var errorDescription: String? {
            switch self {
            case .invalidFormat(let expr):
                return "无效的 Cron 表达式格式: \(expr)，需要 5 或 6 个字段"
            case .invalidField(let field, let value):
                return "无效的字段值 '\(value)' (字段: \(field))"
            case .valueOutOfRange(let field, let value, let range):
                return "值 \(value) 超出范围 \(range) (字段: \(field))"
            }
        }
    }

    public static let fieldRanges: [(name: String, range: ClosedRange<Int>)] = [
        ("minute", 0...59),
        ("hour", 0...23),
        ("dayOfMonth", 1...31),
        ("month", 1...12),
        ("dayOfWeek", 0...6)
    ]

    public init(parsing expression: String) throws {
        self.raw = expression.trimmingCharacters(in: .whitespaces)
        var parts = self.raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)

        switch parts.count {
        case 5:
            self.seconds = nil
        case 6:
            self.seconds = try Self.parseField(parts[0], name: "second", range: 0...59)
            parts.removeFirst()
        default:
            throw ParseError.invalidFormat(expression)
        }

        self.minute = try Self.parseField(parts[0], fieldIndex: 0)
        self.hour = try Self.parseField(parts[1], fieldIndex: 1)
        self.dayOfMonth = try Self.parseField(parts[2], fieldIndex: 2)
        self.month = try Self.parseField(parts[3], fieldIndex: 3)
        self.dayOfWeek = try Self.parseField(parts[4], fieldIndex: 4)
    }

    private static func parseField(_ value: String, fieldIndex: Int) throws -> CronField {
        let (name, range) = fieldRanges[fieldIndex]
        return try parseField(value, name: name, range: range)
    }

    private static func parseField(_ value: String, name: String, range: ClosedRange<Int>) throws -> CronField {
        if value == "*" {
            return .any
        }

        if value.hasPrefix("*/") {
            let stepStr = String(value.dropFirst(2))
            guard let step = Int(stepStr), step > 0 else {
                throw ParseError.invalidField(name, value)
            }
            return .step(step)
        }

        if value.contains(",") {
            let entries = try value.split(separator: ",").map { part -> CronField.CronFieldEntry in
                let s = String(part)
                if s.contains("-") {
                    let bounds = s.split(separator: "-").map(String.init)
                    guard bounds.count == 2,
                          let low = Int(bounds[0]),
                          let high = Int(bounds[1]) else {
                        throw ParseError.invalidField(name, value)
                    }
                    try validateRange(low, field: name, range: range)
                    try validateRange(high, field: name, range: range)
                    return .range(low, high)
                } else {
                    guard let v = Int(s) else {
                        throw ParseError.invalidField(name, value)
                    }
                    try validateRange(v, field: name, range: range)
                    return .value(v)
                }
            }
            return .list(entries)
        }

        if value.contains("-") {
            let bounds = value.split(separator: "-").map(String.init)
            guard bounds.count == 2,
                  let low = Int(bounds[0]),
                  let high = Int(bounds[1]) else {
                throw ParseError.invalidField(name, value)
            }
            try validateRange(low, field: name, range: range)
            try validateRange(high, field: name, range: range)
            return .range(low, high)
        }

        guard let v = Int(value) else {
            throw ParseError.invalidField(name, value)
        }
        try validateRange(v, field: name, range: range)
        return .value(v)
    }

    private static func validateRange(_ value: Int, field: String, range: ClosedRange<Int>) throws {
        guard range.contains(value) else {
            throw ParseError.valueOutOfRange(field: field, value: value, range: range)
        }
    }

    /// Calculate the next fire date after the given date
    public func nextFireDate(after date: Date = Date()) -> Date? {
        let calendar = Calendar.current

        // 6-field expressions: the current minute may still contain a matching
        // second — check it before falling into the minute-by-minute scan.
        if let secondsField = seconds {
            let comps = calendar.dateComponents(
                [.minute, .hour, .day, .month, .weekday, .second], from: date)
            if let m = comps.minute, let h = comps.hour, let d = comps.day,
               let mo = comps.month, let wd = comps.weekday, let s = comps.second,
               minuteLevelMatches(m: m, h: h, d: d, mo: mo, cronWeekday: wd - 1),
               let nextSecond = ((s + 1)..<60).first(where: { matches(field: secondsField, value: $0) }) {
                var c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                c.second = nextSecond
                if let fire = calendar.date(from: c) {
                    return fire
                }
            }
        }

        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        // Start from the next minute
        components.second = 0
        if let minute = components.minute {
            components.minute = minute + 1
        }

        guard var candidate = calendar.date(from: components) else { return nil }

        // Search up to 4 years ahead
        guard let limit = calendar.date(byAdding: .year, value: 4, to: date) else { return nil }

        while candidate < limit {
            let comps = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: candidate)
            guard let m = comps.minute, let h = comps.hour,
                  let d = comps.day, let mo = comps.month,
                  let wd = comps.weekday else { return nil }

            if minuteLevelMatches(m: m, h: h, d: d, mo: mo, cronWeekday: wd - 1) {
                guard let secondsField = seconds else {
                    // 5-field: fire at second 0, exactly as before.
                    return candidate
                }
                // 6-field: earliest matching second within this minute. Any
                // valid seconds field matches at least one value in 0...59,
                // but stay defensive and keep scanning if none.
                if let s = (0..<60).first(where: { matches(field: secondsField, value: $0) }) {
                    return candidate.addingTimeInterval(TimeInterval(s))
                }
            }

            // Advance by 1 minute
            guard let next = calendar.date(byAdding: .minute, value: 1, to: candidate) else { return nil }
            candidate = next
        }

        return nil
    }

    /// Do the five minute-level fields match the given instant?
    /// `cronWeekday` uses cron numbering (0=Sunday..6=Saturday); Calendar's
    /// `.weekday` is 1=Sunday..7=Saturday, so callers pass `weekday - 1`.
    private func minuteLevelMatches(m: Int, h: Int, d: Int, mo: Int, cronWeekday: Int) -> Bool {
        matches(field: month, value: mo) &&
        matches(field: dayOfMonth, value: d) &&
        matches(field: dayOfWeek, value: cronWeekday) &&
        matches(field: hour, value: h) &&
        matches(field: minute, value: m)
    }

    private func matches(field: CronField, value: Int) -> Bool {
        switch field {
        case .any:
            return true
        case .step(let step):
            return value % step == 0
        case .value(let v):
            return value == v
        case .range(let low, let high):
            return value >= low && value <= high
        case .list(let entries):
            return entries.contains { entry in
                switch entry {
                case .value(let v): return value == v
                case .range(let low, let high): return value >= low && value <= high
                case .step(let step): return value % step == 0
                }
            }
        }
    }

    /// Human-readable description of the expression
    public var humanReadable: String {
        switch raw {
        case "* * * * *": return L10n.tr("cron.human.every_minute")
        case "0 * * * *": return L10n.tr("cron.human.every_hour")
        case "0 0 * * *": return L10n.tr("cron.human.daily_midnight")
        case "0 0 * * 0": return L10n.tr("cron.human.weekly_sunday")
        case "0 0 1 * *": return L10n.tr("cron.human.monthly_first")
        default: return raw
        }
    }
}
