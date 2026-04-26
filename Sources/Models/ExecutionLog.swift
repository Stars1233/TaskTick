import Foundation
import SwiftData

enum ExecutionStatus: String, Codable, CaseIterable, Sendable {
    case running = "running"
    case success = "success"
    case failure = "failure"
    case timeout = "timeout"
    case cancelled = "cancelled"

    var displayName: String {
        switch self {
        case .running: L10n.tr("status.running")
        case .success: L10n.tr("status.success")
        case .failure: L10n.tr("status.failure")
        case .timeout: L10n.tr("status.timeout")
        case .cancelled: L10n.tr("status.cancelled")
        }
    }

    var iconName: String {
        switch self {
        case .running: "play.circle.fill"
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.circle.fill"
        case .timeout: "clock.badge.exclamationmark"
        case .cancelled: "stop.circle.fill"
        }
    }
}

enum TriggerType: String, Codable, Sendable {
    case schedule = "schedule"
    case manual = "manual"
    case launch = "launch"

    var displayName: String {
        switch self {
        case .schedule: L10n.tr("log.detail.trigger.schedule")
        case .manual:   L10n.tr("log.detail.trigger.manual")
        case .launch:   L10n.tr("log.detail.trigger.launch")
        }
    }
}

@Model
final class ExecutionLog {
    var id: UUID = UUID()
    var task: ScheduledTask?
    var startedAt: Date = Date()
    var finishedAt: Date?
    var statusRaw: String = ExecutionStatus.running.rawValue
    var exitCode: Int?
    var stdout: String?
    var stderr: String?
    var durationMs: Int?
    var triggeredByRaw: String = TriggerType.manual.rawValue

    init(
        task: ScheduledTask? = nil,
        triggeredBy: TriggerType = .manual
    ) {
        self.id = UUID()
        self.task = task
        self.startedAt = Date()
        self.statusRaw = ExecutionStatus.running.rawValue
        self.triggeredByRaw = triggeredBy.rawValue
    }

    var status: ExecutionStatus {
        get { ExecutionStatus(rawValue: statusRaw) ?? .running }
        set { statusRaw = newValue.rawValue }
    }

    var triggeredBy: TriggerType {
        get { TriggerType(rawValue: triggeredByRaw) ?? .manual }
        set { triggeredByRaw = newValue.rawValue }
    }

    /// Maximum output size: 512KB
    static let maxOutputSize = 512 * 1024

    static func truncateOutput(_ output: String) -> String {
        if output.utf8.count > maxOutputSize {
            let truncated = String(output.prefix(maxOutputSize / 2))
            return truncated + "\n\n--- 输出已截断 (超过 512KB) ---"
        }
        return output
    }
}
