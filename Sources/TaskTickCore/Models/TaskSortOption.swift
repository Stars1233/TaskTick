import Foundation

/// How the task list is ordered. Two dimensions (creation time, last run time),
/// each ascending or descending.
public enum TaskSortOption: String, CaseIterable, Sendable {
    case createdDesc
    case createdAsc
    case lastRunDesc
    case lastRunAsc

    /// The date this option sorts by, for a given task. Last-run options fall
    /// back to creation time for tasks that have never run.
    private func sortKey(for task: ScheduledTask) -> Date {
        switch self {
        case .createdDesc, .createdAsc: return task.createdAt
        case .lastRunDesc, .lastRunAsc: return task.lastRunAt ?? task.createdAt
        }
    }

    private var isAscending: Bool {
        switch self {
        case .createdAsc, .lastRunAsc: return true
        case .createdDesc, .lastRunDesc: return false
        }
    }

    /// Sort the given tasks according to this option.
    public func sort(_ tasks: [ScheduledTask]) -> [ScheduledTask] {
        tasks.sorted { lhs, rhs in
            let lk = sortKey(for: lhs), rk = sortKey(for: rhs)
            return isAscending ? lk < rk : lk > rk
        }
    }
}
