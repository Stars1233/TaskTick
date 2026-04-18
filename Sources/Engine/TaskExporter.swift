import AppKit
import Foundation
import SwiftData
import UniformTypeIdentifiers

/// Exports and imports tasks as JSON files.
@MainActor
struct TaskExporter {

    struct ExportedTask: Codable {
        let name: String
        let scriptBody: String
        let scriptFilePath: String?
        /// Optional so exports produced by older versions (without this field) still decode.
        let preRunCommand: String?
        let shell: String
        let scheduledDate: Date?
        let repeatType: String
        let endRepeatType: String
        let endRepeatDate: Date?
        let endRepeatCount: Int?
        let cronExpression: String?
        let intervalSeconds: Int?
        let workingDirectory: String?
        let timeoutSeconds: Int
        let notifyOnSuccess: Bool
        let notifyOnFailure: Bool
        let isEnabled: Bool
    }

    /// Export all tasks to a JSON file
    static func exportTasks(from context: ModelContext) {
        let descriptor = FetchDescriptor<ScheduledTask>()
        guard let tasks = try? context.fetch(descriptor), !tasks.isEmpty else { return }

        let exported = tasks.map { task in
            ExportedTask(
                name: task.name,
                scriptBody: task.scriptBody,
                scriptFilePath: task.scriptFilePath,
                preRunCommand: task.preRunCommand,
                shell: task.shell,
                scheduledDate: task.scheduledDate,
                repeatType: task.repeatTypeRaw,
                endRepeatType: task.endRepeatTypeRaw,
                endRepeatDate: task.endRepeatDate,
                endRepeatCount: task.endRepeatCount,
                cronExpression: task.cronExpression,
                intervalSeconds: task.intervalSeconds,
                workingDirectory: task.workingDirectory,
                timeoutSeconds: task.timeoutSeconds,
                notifyOnSuccess: task.notifyOnSuccess,
                notifyOnFailure: task.notifyOnFailure,
                isEnabled: task.isEnabled
            )
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.json]
        panel.nameFieldStringValue = "TaskTick-export.json"
        panel.title = "Export Tasks"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(exported)
            try data.write(to: url)
        } catch {
            presentErrorAlert(titleKey: "error.export_failed.title",
                              messageKey: "error.export_failed.message",
                              error: error)
        }
    }

    /// Import tasks from a JSON file
    static func importTasks(into context: ModelContext) -> Int {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.json]
        panel.allowsMultipleSelection = false
        panel.title = "Import Tasks"

        guard panel.runModal() == .OK, let url = panel.url else { return 0 }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            presentErrorAlert(titleKey: "error.import_failed.title",
                              messageKey: "error.import_read_failed",
                              error: error)
            return 0
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let exported: [ExportedTask]
        do {
            exported = try decoder.decode([ExportedTask].self, from: data)
        } catch {
            presentErrorAlert(titleKey: "error.import_failed.title",
                              messageKey: "error.import_decode_failed",
                              error: error)
            return 0
        }

        var count = 0
        var insertedTasks: [ScheduledTask] = []
        for item in exported {
            let task = ScheduledTask(
                name: item.name,
                scriptBody: item.scriptBody,
                shell: item.shell,
                scheduledDate: item.scheduledDate,
                repeatType: RepeatType(rawValue: item.repeatType) ?? .daily,
                endRepeatType: EndRepeatType(rawValue: item.endRepeatType) ?? .never,
                endRepeatDate: item.endRepeatDate,
                endRepeatCount: item.endRepeatCount,
                isEnabled: item.isEnabled,
                workingDirectory: item.workingDirectory,
                timeoutSeconds: item.timeoutSeconds,
                notifyOnSuccess: item.notifyOnSuccess,
                notifyOnFailure: item.notifyOnFailure
            )
            task.scriptFilePath = item.scriptFilePath
            task.preRunCommand = item.preRunCommand ?? ""
            task.cronExpression = item.cronExpression
            task.intervalSeconds = item.intervalSeconds

            if task.isEnabled {
                task.nextRunAt = TaskScheduler.shared.computeNextRunDate(for: task)
            }

            context.insert(task)
            insertedTasks.append(task)
            count += 1
        }

        do {
            try context.save()
        } catch {
            // Roll back unsaved inserts so the UI doesn't flash phantom tasks.
            for task in insertedTasks {
                context.delete(task)
            }
            presentErrorAlert(titleKey: "error.import_failed.title",
                              messageKey: "error.import_save_failed",
                              error: error)
            return 0
        }
        TaskScheduler.shared.rebuildSchedule()
        return count
    }
}
