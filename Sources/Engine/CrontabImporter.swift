import Foundation
import SwiftData

/// Imports tasks from the system crontab.
struct CrontabImporter {

    struct CrontabEntry {
        let cronExpression: String
        let command: String
        let originalLine: String
    }

    /// Read current user's crontab entries
    static func readCrontab() -> [CrontabEntry] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/crontab")
        process.arguments = ["-l"]
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var entries: [CrontabEntry] = []
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Skip empty lines, comments, and environment variables
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.contains("=") && !trimmed.contains(" ") {
                continue
            }

            if let entry = parseCrontabLine(trimmed) {
                entries.append(entry)
            }
        }
        return entries
    }

    /// Parse a single crontab line into cron expression + command
    static func parseCrontabLine(_ line: String) -> CrontabEntry? {
        let parts = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
        guard parts.count >= 6 else { return nil }

        let cronFields = parts[0..<5].joined(separator: " ")
        let command = String(parts[5...].joined(separator: " "))

        // Basic validation: first field should be a number, *, or start with */
        let firstField = String(parts[0])
        let validStarters = CharacterSet(charactersIn: "0123456789*/")
        guard firstField.unicodeScalars.first.map({ validStarters.contains($0) }) == true else {
            return nil
        }

        return CrontabEntry(
            cronExpression: cronFields,
            command: command.trimmingCharacters(in: .whitespaces),
            originalLine: line
        )
    }

    /// Convert a cron expression to the new RepeatType (best effort)
    static func cronToRepeatType(_ cron: String) -> (repeatType: RepeatType, date: Date?) {
        let calendar = Calendar.current
        let now = Date()

        switch cron {
        case "* * * * *":
            return (.everyMinute, now)
        case "*/5 * * * *":
            return (.every5Minutes, now)
        case "*/15 * * * *":
            return (.every15Minutes, now)
        case "*/30 * * * *":
            return (.every30Minutes, now)
        case let c where c.hasPrefix("0 ") && c.hasSuffix(" * * *"):
            // "0 N * * *" → daily at N:00
            let parts = c.split(separator: " ")
            if parts.count == 5, let hour = Int(parts[1]) {
                var comps = calendar.dateComponents([.year, .month, .day], from: now)
                comps.hour = hour
                comps.minute = 0
                let date = calendar.date(from: comps) ?? now
                return (.daily, date)
            }
            return (.daily, now)
        case let c where c.contains("* * 1"):
            // Weekly Monday
            return (.weekly, now)
        case let c where c.contains("* * 0"):
            // Weekly Sunday
            return (.weekly, now)
        default:
            // For complex expressions, try to parse minute/hour for daily
            let parts = cron.split(separator: " ")
            if parts.count == 5,
               let minute = Int(parts[0]),
               let hour = Int(parts[1]),
               parts[2] == "*", parts[3] == "*", parts[4] == "*" {
                var comps = calendar.dateComponents([.year, .month, .day], from: now)
                comps.hour = hour
                comps.minute = minute
                let date = calendar.date(from: comps) ?? now
                return (.daily, date)
            }
            // Fallback: use hourly with legacy cron
            return (.hourly, now)
        }
    }

    /// Import crontab entries as ScheduledTask objects
    static func importEntries(_ entries: [CrontabEntry], into context: ModelContext) -> Int {
        var imported = 0
        for entry in entries {
            let (repeatType, date) = cronToRepeatType(entry.cronExpression)

            // Generate a name from the command
            let name = generateTaskName(from: entry.command)

            let task = ScheduledTask(
                name: name,
                scriptBody: entry.command,
                shell: "/bin/bash",
                scheduledDate: date,
                repeatType: repeatType,
                endRepeatType: .never,
                isEnabled: true,
                notifyOnFailure: true
            )
            // Store original cron for reference
            task.cronExpression = entry.cronExpression
            task.schedule = .cron

            context.insert(task)
            imported += 1
        }
        try? context.save()
        return imported
    }

    /// Comment out specified lines in the crontab
    static func commentOutEntries(_ entries: [CrontabEntry]) -> Bool {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/crontab")
        process.arguments = ["-l"]
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard var content = String(data: data, encoding: .utf8) else { return false }

        let originalLines = Set(entries.map(\.originalLine))

        // Comment out matching lines
        let lines = content.components(separatedBy: "\n")
        let updatedLines = lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if originalLines.contains(trimmed) {
                return "# [TaskTick imported] " + line
            }
            return line
        }
        content = updatedLines.joined(separator: "\n")

        // Write back
        let writeProcess = Process()
        let inputPipe = Pipe()
        writeProcess.executableURL = URL(fileURLWithPath: "/usr/bin/crontab")
        writeProcess.arguments = ["-"]
        writeProcess.standardInput = inputPipe

        do {
            try writeProcess.run()
            guard let data = content.data(using: .utf8) else { return false }
            inputPipe.fileHandleForWriting.write(data)
            inputPipe.fileHandleForWriting.closeFile()
            writeProcess.waitUntilExit()
            return writeProcess.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Generate a readable task name from the command
    private static func generateTaskName(from command: String) -> String {
        // Take the first meaningful part of the command
        let cleaned = command
            .replacingOccurrences(of: "&&", with: " ")
            .replacingOccurrences(of: "||", with: " ")
            .replacingOccurrences(of: "|", with: " ")
            .replacingOccurrences(of: ";", with: " ")

        let firstCommand = cleaned.split(separator: " ").first.map(String.init) ?? command

        // Extract just the binary name
        let binary = (firstCommand as NSString).lastPathComponent

        if binary.isEmpty {
            return "Imported Task"
        }
        return "crontab: \(binary)"
    }
}
