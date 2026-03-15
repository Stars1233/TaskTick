import Foundation

/// Cron expression parser supporting standard 5-field format:
/// minute hour dayOfMonth month dayOfWeek
struct CronExpression: Sendable {
    let minute: CronField
    let hour: CronField
    let dayOfMonth: CronField
    let month: CronField
    let dayOfWeek: CronField

    let raw: String

    enum CronField: Sendable, Equatable {
        case any                          // *
        case step(Int)                    // */N
        case value(Int)                   // N
        case range(Int, Int)              // N-M
        case list([CronFieldEntry])       // N,M,O or combined

        enum CronFieldEntry: Sendable, Equatable {
            case value(Int)
            case range(Int, Int)
            case step(Int)
        }
    }

    enum ParseError: Error, LocalizedError {
        case invalidFormat(String)
        case invalidField(String, String)
        case valueOutOfRange(field: String, value: Int, range: ClosedRange<Int>)

        var errorDescription: String? {
            switch self {
            case .invalidFormat(let expr):
                return "无效的 Cron 表达式格式: \(expr)，需要 5 个字段"
            case .invalidField(let field, let value):
                return "无效的字段值 '\(value)' (字段: \(field))"
            case .valueOutOfRange(let field, let value, let range):
                return "值 \(value) 超出范围 \(range) (字段: \(field))"
            }
        }
    }

    static let fieldRanges: [(name: String, range: ClosedRange<Int>)] = [
        ("minute", 0...59),
        ("hour", 0...23),
        ("dayOfMonth", 1...31),
        ("month", 1...12),
        ("dayOfWeek", 0...6)
    ]

    init(parsing expression: String) throws {
        self.raw = expression.trimmingCharacters(in: .whitespaces)
        let parts = self.raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)

        guard parts.count == 5 else {
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
    func nextFireDate(after date: Date = Date()) -> Date? {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        // Start from the next minute
        components.second = 0
        if let minute = components.minute {
            components.minute = minute + 1
        }

        guard var candidate = calendar.date(from: components) else { return nil }

        // Search up to 4 years ahead
        let limit = calendar.date(byAdding: .year, value: 4, to: date)!

        while candidate < limit {
            let comps = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: candidate)
            guard let m = comps.minute, let h = comps.hour,
                  let d = comps.day, let mo = comps.month,
                  let wd = comps.weekday else { return nil }

            // Calendar weekday: 1=Sunday..7=Saturday -> cron: 0=Sunday..6=Saturday
            let cronWeekday = wd - 1

            if matches(field: month, value: mo) &&
               matches(field: dayOfMonth, value: d) &&
               matches(field: dayOfWeek, value: cronWeekday) &&
               matches(field: hour, value: h) &&
               matches(field: minute, value: m) {
                return candidate
            }

            // Advance by 1 minute
            candidate = calendar.date(byAdding: .minute, value: 1, to: candidate)!
        }

        return nil
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
    var humanReadable: String {
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
