import ArgumentParser
import Foundation
import TaskTickCore

struct CreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new task from a script file."
    )

    @Argument(help: "Task name.")
    var name: String

    @Option(name: .long, help: "Path to script file (required).")
    var script: String

    @Option(name: .long, help: "Shell to use. Default: /bin/zsh")
    var shell: String = "/bin/zsh"

    @Option(name: .long, help: "Working directory. Default: script's parent dir.")
    var cwd: String?

    @Option(name: .long, help: "Timeout in seconds. Use -1 for unlimited. Default: -1")
    var timeout: Int = -1

    @Flag(name: .long, help: "Manual-only task (skip scheduler). Mutually exclusive with --repeat/--at.")
    var manual: Bool = false

    @Option(name: .customLong("repeat"),
            help: "Repeat type: never | everyMinute | every5Minutes | every15Minutes | every30Minutes | hourly | daily | weekdays | weekends | weekly | biweekly | monthly | every3Months | every6Months | yearly")
    var repeatType: String?

    @Option(name: .long, help: "First run time as HH:MM (24-hour). Implies a scheduled task.")
    var at: String?

    @Flag(name: .customLong("no-enable"), help: "Create the task but don't enable it.")
    var noEnable: Bool = false

    @Flag(name: .long, help: "Output JSON instead of human-readable text.")
    var json: Bool = false

    @MainActor
    func run() async throws {
        // 1. Validate script path
        let scriptURL = URL(fileURLWithPath: script).resolvingSymlinksInPath()
        let scriptPath = scriptURL.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: scriptPath, isDirectory: &isDir),
              !isDir.boolValue else {
            FileHandle.standardError.write(Data("tasktick: script not found or is a directory: \(script)\n".utf8))
            throw ExitCode(1)
        }

        // 2. Mutually-exclusive scheduling flags
        if manual && (repeatType != nil || at != nil) {
            FileHandle.standardError.write(Data("tasktick: --manual is mutually exclusive with --repeat/--at\n".utf8))
            throw ExitCode(1)
        }

        // 3. Resolve repeat type — accepts the RepeatType raw value verbatim
        // OR a few human-friendly aliases. Case-insensitive match against
        // RepeatType.allCases so users don't need to remember CamelCase.
        let repeatRaw: String
        if let r = repeatType {
            if let match = RepeatType.allCases.first(where: { $0.rawValue.lowercased() == r.lowercased() }) {
                repeatRaw = match.rawValue
            } else {
                FileHandle.standardError.write(Data("tasktick: invalid --repeat value: \(r)\n".utf8))
                throw ExitCode(1)
            }
        } else {
            repeatRaw = RepeatType.never.rawValue
        }

        // 4. Parse --at HH:MM into a scheduledDate anchored to today.
        // TaskScheduler.computeNextRunDate handles "first run is in the past"
        // by rolling forward (next day for daily, etc.), so we don't need to
        // bump the date here.
        var scheduledAt: Date? = nil
        if let atStr = at {
            let parts = atStr.split(separator: ":")
            guard parts.count == 2,
                  let hour = Int(parts[0]),
                  let minute = Int(parts[1]),
                  (0..<24).contains(hour),
                  (0..<60).contains(minute) else {
                FileHandle.standardError.write(Data("tasktick: invalid --at format (expected HH:MM): \(atStr)\n".utf8))
                throw ExitCode(1)
            }
            let calendar = Calendar.current
            var comps = calendar.dateComponents([.year, .month, .day], from: Date())
            comps.hour = hour
            comps.minute = minute
            comps.second = 0
            scheduledAt = calendar.date(from: comps)
        }

        // 5. Determine isManualOnly. Default to manual when no schedule given —
        // matches the common "I just want to register this script" use case.
        let isManualOnly = manual || (repeatType == nil && at == nil)
        let isEnabled = !noEnable

        // 6. Build the payload. Plist-serializable types only (DistributedNotificationCenter).
        let id = UUID()
        var payload: [String: Any] = [
            "id": id.uuidString,
            "name": name,
            "script_path": scriptPath,
            "shell": shell,
            "timeout": timeout,
            "manual": isManualOnly,
            "enabled": isEnabled,
            "repeat": repeatRaw,
        ]
        if let cwd, !cwd.isEmpty {
            payload["cwd"] = cwd
        }
        if let scheduledAt {
            payload["scheduled_at"] = scheduledAt.timeIntervalSince1970
        }

        // 7. Ensure the GUI is running — it owns the SwiftData store.
        if !GUILauncher.isRunning() {
            let ok = GUILauncher.launchAndWait()
            if !ok {
                FileHandle.standardError.write(Data("tasktick: TaskTick.app failed to launch within 10s\n".utf8))
                throw ExitCode(1)
            }
            // Give the GUI a moment to finish configuring CLIBridge observers.
            // Without this, the create notification can arrive before
            // CLIBridge.configure() has registered its handler.
            try? await Task.sleep(for: .milliseconds(500))
        }

        // 8. Post the create notification.
        NotificationBridge.postCreate(payload: payload)

        // 9. Poll the read-only store for up to 5s to confirm the GUI persisted
        // the task. Re-open the store each iteration — SwiftData caches reads,
        // and our process won't see another process's writes without reopen.
        for _ in 0..<25 {
            try? await Task.sleep(for: .milliseconds(200))
            if let store = try? ReadOnlyStore(),
               (try? store.fetchTask(byId: id)) != nil {
                printSuccess(taskId: id)
                return
            }
        }

        FileHandle.standardError.write(Data("tasktick: GUI didn't acknowledge create within 5s\n".utf8))
        throw ExitCode(1)
    }

    private func printSuccess(taskId: UUID) {
        if json {
            let payload: [String: String] = [
                "id": taskId.uuidString,
                "name": name,
                "status": "created"
            ]
            if let data = try? JSONEncoder().encode(payload),
               let line = String(data: data, encoding: .utf8) {
                print(line)
            }
        } else {
            print("✓ Created: \(name) (id: \(taskId.uuidString))")
        }
    }
}
