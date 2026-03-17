import Foundation
import SwiftData

// MARK: - Repeat Type

enum RepeatType: String, Codable, CaseIterable, Sendable {
    case never = "never"
    case everyMinute = "everyMinute"
    case every5Minutes = "every5Minutes"
    case every15Minutes = "every15Minutes"
    case every30Minutes = "every30Minutes"
    case hourly = "hourly"
    case daily = "daily"
    case weekdays = "weekdays"
    case weekends = "weekends"
    case weekly = "weekly"
    case biweekly = "biweekly"
    case monthly = "monthly"
    case every3Months = "every3Months"
    case every6Months = "every6Months"
    case yearly = "yearly"
    case custom = "custom"

    var displayName: String {
        switch self {
        case .never: L10n.tr("repeat.never")
        case .everyMinute: L10n.tr("repeat.every_minute")
        case .every5Minutes: L10n.tr("repeat.every_5_minutes")
        case .every15Minutes: L10n.tr("repeat.every_15_minutes")
        case .every30Minutes: L10n.tr("repeat.every_30_minutes")
        case .hourly: L10n.tr("repeat.hourly")
        case .daily: L10n.tr("repeat.daily")
        case .weekdays: L10n.tr("repeat.weekdays")
        case .weekends: L10n.tr("repeat.weekends")
        case .weekly: L10n.tr("repeat.weekly")
        case .biweekly: L10n.tr("repeat.biweekly")
        case .monthly: L10n.tr("repeat.monthly")
        case .every3Months: L10n.tr("repeat.every_3_months")
        case .every6Months: L10n.tr("repeat.every_6_months")
        case .yearly: L10n.tr("repeat.yearly")
        case .custom: L10n.tr("repeat.custom")
        }
    }

    /// Calendar component and value for computing next date
    var calendarInterval: (component: Calendar.Component, value: Int)? {
        switch self {
        case .never: nil
        case .everyMinute: (.minute, 1)
        case .every5Minutes: (.minute, 5)
        case .every15Minutes: (.minute, 15)
        case .every30Minutes: (.minute, 30)
        case .hourly: (.hour, 1)
        case .daily, .weekdays, .weekends: (.day, 1)
        case .weekly: (.weekOfYear, 1)
        case .biweekly: (.weekOfYear, 2)
        case .monthly: (.month, 1)
        case .every3Months: (.month, 3)
        case .every6Months: (.month, 6)
        case .yearly: (.year, 1)
        case .custom: nil // handled separately with customInterval fields
        }
    }
}

/// Unit for custom repeat interval
enum CustomRepeatUnit: String, Codable, CaseIterable, Sendable {
    case hour = "hour"
    case day = "day"
    case week = "week"
    case month = "month"
    case year = "year"

    var displayName: String {
        switch self {
        case .hour: L10n.tr("repeat.unit.hour")
        case .day: L10n.tr("repeat.unit.day")
        case .week: L10n.tr("repeat.unit.week")
        case .month: L10n.tr("repeat.unit.month")
        case .year: L10n.tr("repeat.unit.year")
        }
    }

    var calendarComponent: Calendar.Component {
        switch self {
        case .hour: .hour
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }
}

// MARK: - End Repeat Type

enum EndRepeatType: String, Codable, CaseIterable, Sendable {
    case never = "never"
    case onDate = "onDate"
    case afterCount = "afterCount"

    var displayName: String {
        switch self {
        case .never: L10n.tr("end_repeat.never")
        case .onDate: L10n.tr("end_repeat.on_date")
        case .afterCount: L10n.tr("end_repeat.after_count")
        }
    }
}

// MARK: - Legacy ScheduleType (for migration)

enum ScheduleType: String, Codable, CaseIterable, Sendable {
    case cron = "cron"
    case interval = "interval"

    var displayName: String {
        switch self {
        case .cron: L10n.tr("schedule.cron")
        case .interval: L10n.tr("schedule.interval")
        }
    }
}

// MARK: - Model

@Model
final class ScheduledTask {
    var id: UUID
    var serialNumber: Int = 0
    var name: String
    var scriptBody: String
    var scriptFilePath: String?
    var shell: String

    // Legacy fields (kept for data migration)
    var scheduleType: String
    var cronExpression: String?
    var intervalSeconds: Int?

    // New schedule fields
    var scheduledDate: Date?
    var repeatTypeRaw: String = RepeatType.daily.rawValue
    var endRepeatTypeRaw: String = EndRepeatType.never.rawValue
    var endRepeatDate: Date?
    var endRepeatCount: Int?
    var executionCount: Int = 0
    var customIntervalValue: Int = 1
    var customIntervalUnitRaw: String = CustomRepeatUnit.day.rawValue

    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date
    var lastRunAt: Date?
    var nextRunAt: Date?
    var workingDirectory: String?
    var environmentVariablesJSON: String?
    var timeoutSeconds: Int
    var notifyOnSuccess: Bool
    var notifyOnFailure: Bool
    var runMissedExecution: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \ExecutionLog.task)
    var executionLogs: [ExecutionLog]

    init(
        name: String = "",
        scriptBody: String = "",
        shell: String = "/bin/zsh",
        scheduledDate: Date? = nil,
        repeatType: RepeatType = .daily,
        endRepeatType: EndRepeatType = .never,
        endRepeatDate: Date? = nil,
        endRepeatCount: Int? = nil,
        isEnabled: Bool = true,
        workingDirectory: String? = nil,
        environmentVariablesJSON: String? = nil,
        timeoutSeconds: Int = 300,
        notifyOnSuccess: Bool = false,
        notifyOnFailure: Bool = true
    ) {
        self.id = UUID()
        let nextSerial = UserDefaults.standard.integer(forKey: "taskSerialCounter") + 1
        UserDefaults.standard.set(nextSerial, forKey: "taskSerialCounter")
        self.serialNumber = nextSerial
        self.name = name
        self.scriptBody = scriptBody
        self.shell = shell
        self.scheduleType = "interval" // legacy default
        self.cronExpression = nil
        self.intervalSeconds = nil
        self.scheduledDate = scheduledDate
        self.repeatTypeRaw = repeatType.rawValue
        self.endRepeatTypeRaw = endRepeatType.rawValue
        self.endRepeatDate = endRepeatDate
        self.endRepeatCount = endRepeatCount
        self.executionCount = 0
        self.isEnabled = isEnabled
        self.createdAt = Date()
        self.updatedAt = Date()
        self.workingDirectory = workingDirectory
        self.environmentVariablesJSON = environmentVariablesJSON
        self.timeoutSeconds = timeoutSeconds
        self.notifyOnSuccess = notifyOnSuccess
        self.notifyOnFailure = notifyOnFailure
        self.executionLogs = []
        self.scriptFilePath = nil
    }

    // MARK: - Computed Properties

    var schedule: ScheduleType {
        get { ScheduleType(rawValue: scheduleType) ?? .interval }
        set { scheduleType = newValue.rawValue }
    }

    var repeatType: RepeatType {
        get { RepeatType(rawValue: repeatTypeRaw) ?? .daily }
        set { repeatTypeRaw = newValue.rawValue }
    }

    var endRepeatType: EndRepeatType {
        get { EndRepeatType(rawValue: endRepeatTypeRaw) ?? .never }
        set { endRepeatTypeRaw = newValue.rawValue }
    }

    var customIntervalUnit: CustomRepeatUnit {
        get { CustomRepeatUnit(rawValue: customIntervalUnitRaw) ?? .day }
        set { customIntervalUnitRaw = newValue.rawValue }
    }

    var environmentVariables: [String: String]? {
        get {
            guard let json = environmentVariablesJSON,
                  let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode([String: String].self, from: data)
        }
        set {
            guard let value = newValue,
                  let data = try? JSONEncoder().encode(value) else {
                environmentVariablesJSON = nil
                return
            }
            environmentVariablesJSON = String(data: data, encoding: .utf8)
        }
    }

    /// Human-readable schedule description
    var scheduleDescription: String {
        var parts: [String] = []

        if let date = scheduledDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            parts.append(formatter.string(from: date))
        }

        parts.append(repeatType.displayName)

        if repeatType != .never {
            switch endRepeatType {
            case .never:
                break
            case .onDate:
                if let endDate = endRepeatDate {
                    let formatter = DateFormatter()
                    formatter.dateStyle = .medium
                    parts.append(L10n.tr("schedule.until", formatter.string(from: endDate)))
                }
            case .afterCount:
                if let count = endRepeatCount {
                    parts.append(L10n.tr("schedule.after_n_times", count))
                }
            }
        }

        return parts.joined(separator: " · ")
    }
}
