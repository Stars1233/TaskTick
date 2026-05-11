import ArgumentParser
import Foundation
import SwiftData
import TaskTickCore

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List tasks (default: all enabled)."
    )

    enum Filter: String, ExpressibleByArgument {
        case all, manual, scheduled, running
    }

    @Option(name: .long, help: "Filter: all | manual | scheduled | running")
    var filter: Filter = .all

    @Flag(name: .long, help: "Output JSON instead of a human-readable table.")
    var json: Bool = false

    @MainActor
    func run() async throws {
        let store = try ReadOnlyStore()
        let runningIds = NotificationBridge.runningTaskIds(store: store)
        let allTasks = try store.fetchTasks()

        let filtered = allTasks.filter { task in
            switch filter {
            case .all: return task.isEnabled
            case .manual: return task.isEnabled && task.isManualOnly
            case .scheduled: return task.isEnabled && !task.isManualOnly
            case .running: return runningIds.contains(task.id)
            }
        }

        let dtos: [TaskDTO] = filtered.map { task in
            let lastLog = (try? store.fetchLatestLog(forTaskId: task.id)) ?? nil
            return TaskDTO.from(task, runningIds: runningIds, lastLog: lastLog)
        }

        if json {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(dtos)
            print(String(data: data, encoding: .utf8) ?? "[]")
        } else {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            let rows = dtos.map { dto in
                [
                    "#\(dto.serialNumber)",
                    dto.shortId,
                    dto.name,
                    dto.kind.rawValue,
                    dto.status.rawValue,
                    dto.lastRunAt.map { date -> String in
                        let diff = Date().timeIntervalSince(date)
                        if diff >= 0 && diff < 60 {
                            return L10n.tr("time.just_now")
                        }
                        return formatter.localizedString(for: date, relativeTo: Date())
                    } ?? "—"
                ]
            }
            print(TableRenderer.render(
                headers: ["NO", "ID", "NAME", "KIND", "STATUS", "LAST RUN"],
                rows: rows
            ))
        }
    }
}
