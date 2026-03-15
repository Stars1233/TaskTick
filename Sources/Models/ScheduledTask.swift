import Foundation
import SwiftData

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

@Model
final class ScheduledTask {
    var id: UUID
    var name: String
    var scriptBody: String
    var scriptFilePath: String?  // nil = inline script, non-nil = local file path
    var shell: String
    var scheduleType: String // ScheduleType raw value
    var cronExpression: String?
    var intervalSeconds: Int?
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

    @Relationship(deleteRule: .cascade, inverse: \ExecutionLog.task)
    var executionLogs: [ExecutionLog]

    init(
        name: String = "",
        scriptBody: String = "",
        shell: String = "/bin/zsh",
        scheduleType: ScheduleType = .interval,
        cronExpression: String? = nil,
        intervalSeconds: Int? = 60,
        isEnabled: Bool = true,
        workingDirectory: String? = nil,
        environmentVariablesJSON: String? = nil,
        timeoutSeconds: Int = 300,
        notifyOnSuccess: Bool = false,
        notifyOnFailure: Bool = true
    ) {
        self.id = UUID()
        self.name = name
        self.scriptBody = scriptBody
        self.shell = shell
        self.scheduleType = scheduleType.rawValue
        self.cronExpression = cronExpression
        self.intervalSeconds = intervalSeconds
        self.isEnabled = isEnabled
        self.createdAt = Date()
        self.updatedAt = Date()
        self.workingDirectory = workingDirectory
        self.environmentVariablesJSON = environmentVariablesJSON
        self.timeoutSeconds = timeoutSeconds
        self.notifyOnSuccess = notifyOnSuccess
        self.notifyOnFailure = notifyOnFailure
        self.executionLogs = []
    }

    var schedule: ScheduleType {
        get { ScheduleType(rawValue: scheduleType) ?? .interval }
        set { scheduleType = newValue.rawValue }
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
}
