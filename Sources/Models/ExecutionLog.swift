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
}

@Model
final class ExecutionLog {
    var id: UUID
    var task: ScheduledTask?
    var startedAt: Date
    var finishedAt: Date?
    var statusRaw: String // ExecutionStatus raw value
    var exitCode: Int?
    var stdout: String?
    var stderr: String?
    var durationMs: Int?
    var triggeredByRaw: String // TriggerType raw value

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
