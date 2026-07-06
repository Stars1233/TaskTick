import Foundation
import TaskTickCore

enum TaskKind: String, Codable {
    case scheduled
    case manual
}

enum TaskStatus: String, Codable {
    case idle
    case running
}

struct TaskDTO: Codable {
    let id: UUID
    let serialNumber: Int     // matches the GUI's #N display
    let shortId: String
    let name: String
    let kind: TaskKind
    let enabled: Bool
    let status: TaskStatus
    let scheduleSummary: String
    let lastRunAt: Date?
    let lastRunDurationSec: Int?
    let lastExitCode: Int?
    let createdAt: Date
}

struct StatusGlobalDTO: Codable {
    struct RunningTask: Codable {
        let id: UUID
        let name: String
        let startedAt: Date
        let elapsedSec: Int
    }
    let running: [RunningTask]
    let totalEnabled: Int
    let totalRunning: Int
}

struct ExecutionLogDTO: Codable {
    struct LogLine: Codable {
        let ts: Date
        let stream: String  // "stdout" | "stderr"
        let text: String
    }
    let executionId: UUID
    let taskId: UUID
    let startedAt: Date
    let endedAt: Date?
    let exitCode: Int?
    let stdout: String
    let stderr: String
    let lines: [LogLine]
}

extension TaskDTO {
    /// Build from a SwiftData ScheduledTask + the current running ID set.
    /// `runningIds` must be supplied separately because a CLI process can't
    /// observe the GUI's @Published runningTaskIDs (different process).
    static func from(_ task: ScheduledTask, runningIds: Set<UUID>, lastLog: ExecutionLog?) -> TaskDTO {
        TaskDTO(
            id: task.id,
            serialNumber: task.serialNumber,
            shortId: String(task.id.uuidString.prefix(4)).lowercased(),
            name: task.name,
            kind: task.isManualOnly ? .manual : .scheduled,
            enabled: task.isEnabled,
            status: runningIds.contains(task.id) ? .running : .idle,
            scheduleSummary: task.isManualOnly ? "Manual" : task.repeatDisplayName,
            lastRunAt: task.lastRunAt,
            lastRunDurationSec: lastLog?.durationMs.map { $0 / 1000 },
            lastExitCode: lastLog?.exitCode,
            createdAt: task.createdAt
        )
    }
}

