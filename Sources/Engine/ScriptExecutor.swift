import Foundation
import SwiftData

/// Executes shell scripts using Process (NSTask) with async output capture.
@MainActor
final class ScriptExecutor: ObservableObject {

    @Published var runningProcesses: [UUID: Process] = [:]

    static let shared = ScriptExecutor()
    private let executionSemaphore = DispatchSemaphore(value: 8)

    private init() {}

    /// Run a task's script and return the execution log entry.
    @discardableResult
    func execute(task: ScheduledTask, triggeredBy: TriggerType = .manual, modelContext: ModelContext) async -> ExecutionLog {
        let log = ExecutionLog(task: task, triggeredBy: triggeredBy)
        modelContext.insert(log)
        try? modelContext.save()

        let startTime = Date()

        // Capture task properties before going off main actor
        let shell = task.shell
        let workingDirectory = task.workingDirectory
        let envVars = task.environmentVariables
        let timeoutSeconds = task.timeoutSeconds
        let taskId = task.id
        let ignoreExitCode = task.ignoreExitCode
        let taskName = task.name
        let notifyOnSuccess = task.notifyOnSuccess
        let notifyOnFailure = task.notifyOnFailure
        let strongReminder = task.strongReminder
        let logId = log.id

        // Resolve script: inline body or file content
        let scriptBody: String
        if let filePath = task.scriptFilePath, !filePath.isEmpty {
            if let content = try? String(contentsOfFile: filePath, encoding: .utf8) {
                scriptBody = content
            } else {
                // File not readable
                log.status = .failure
                log.stderr = "Cannot read script file: \(filePath)"
                log.finishedAt = Date()
                log.durationMs = 0
                try? modelContext.save()
                return log
            }
        } else {
            scriptBody = task.scriptBody
        }

        let result = await runProcess(
            shell: shell,
            script: scriptBody,
            workingDirectory: workingDirectory,
            environmentVariables: envVars,
            timeoutSeconds: timeoutSeconds,
            taskId: taskId,
            ignoreExitCode: ignoreExitCode
        )

        let endTime = Date()
        let durationMs = Int(endTime.timeIntervalSince(startTime) * 1000)

        // After await, task or log may have been deleted (user deleted task during execution).
        // Re-fetch from context to check they still exist before writing.
        let logDescriptor = FetchDescriptor<ExecutionLog>(predicate: #Predicate { $0.id == logId })
        let taskDescriptor = FetchDescriptor<ScheduledTask>(predicate: #Predicate { $0.id == taskId })
        let fetchedLog = try? modelContext.fetch(logDescriptor).first
        let fetchedTask = try? modelContext.fetch(taskDescriptor).first

        if let fetchedLog {
            fetchedLog.stdout = ExecutionLog.truncateOutput(result.stdout)
            fetchedLog.stderr = ExecutionLog.truncateOutput(result.stderr)
            fetchedLog.exitCode = result.exitCode
            fetchedLog.status = result.status
            fetchedLog.finishedAt = endTime
            fetchedLog.durationMs = durationMs
        }

        if let fetchedTask {
            fetchedTask.lastRunAt = endTime
            fetchedTask.updatedAt = endTime
        }

        try? modelContext.save()

        // Send notification using pre-captured properties (safe even if task was deleted)
        let globalNotificationsEnabled = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
        let durationText = "\(L10n.tr("notification.duration")) \(durationMs)ms"

        if globalNotificationsEnabled && notifyOnFailure && result.status != .success {
            let exitInfo = "Exit code: \(result.exitCode ?? -1)"
            let stderrLine = result.stderr.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
            let body = [exitInfo, durationText, stderrLine].filter { !$0.isEmpty }.joined(separator: " · ")
            NotificationManager.shared.sendNotification(
                title: "[\(L10n.tr("notification.failed"))] \(taskName)",
                body: body
            )
        } else if globalNotificationsEnabled && notifyOnSuccess && result.status == .success {
            let stdoutLine = result.stdout.components(separatedBy: .newlines).first(where: {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return false }
                let stripped = trimmed.filter { !("─═—–-=_*#~".contains($0)) }
                return !stripped.isEmpty
            }) ?? ""
            let body = [durationText, stdoutLine].filter { !$0.isEmpty }.joined(separator: " · ")
            NotificationManager.shared.sendNotification(
                title: "[\(L10n.tr("notification.succeeded"))] \(taskName)",
                body: body.isEmpty ? L10n.tr("notification.success") : body
            )
        }

        // Strong reminder: show floating panel with full output
        if result.status == .success && strongReminder {
            StrongReminderPanel.shared.show(
                taskName: taskName,
                output: result.stdout,
                durationMs: durationMs
            )
        }

        return log
    }

    /// Cancel a running task
    func cancel(taskId: UUID) {
        if let process = runningProcesses[taskId], process.isRunning {
            process.terminate()
        }
        runningProcesses.removeValue(forKey: taskId)
    }

    // MARK: - Private

    private struct ProcessResult: Sendable {
        let stdout: String
        let stderr: String
        let exitCode: Int?
        let status: ExecutionStatus
    }

    private func runProcess(
        shell: String,
        script: String,
        workingDirectory: String?,
        environmentVariables: [String: String]?,
        timeoutSeconds: Int,
        taskId: UUID,
        ignoreExitCode: Bool = false
    ) async -> ProcessResult {
        // Run the entire process on a background queue to avoid blocking the main thread
        await withCheckedContinuation { (continuation: CheckedContinuation<ProcessResult, Never>) in
            // Limit concurrent executions to prevent resource exhaustion
            self.executionSemaphore.wait()
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()

                process.executableURL = URL(fileURLWithPath: shell)
                process.arguments = ["-l", "-c", script]
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                if let dir = workingDirectory, !dir.isEmpty {
                    process.currentDirectoryURL = URL(fileURLWithPath: dir)
                }

                if let envVars = environmentVariables {
                    var env = ProcessInfo.processInfo.environment
                    for (key, value) in envVars {
                        env[key] = value
                    }
                    process.environment = env
                }

                // Collect output asynchronously to prevent pipe buffer deadlock
                let stdoutHandle = stdoutPipe.fileHandleForReading
                let stderrHandle = stderrPipe.fileHandleForReading
                let group = DispatchGroup()

                var stdoutData = Data()
                var stderrData = Data()
                let lock = NSLock()

                group.enter()
                DispatchQueue.global().async {
                    let data = stdoutHandle.readDataToEndOfFile()
                    lock.lock()
                    stdoutData = data
                    lock.unlock()
                    group.leave()
                }

                group.enter()
                DispatchQueue.global().async {
                    let data = stderrHandle.readDataToEndOfFile()
                    lock.lock()
                    stderrData = data
                    lock.unlock()
                    group.leave()
                }

                do {
                    try process.run()
                } catch {
                    self.executionSemaphore.signal()
                    continuation.resume(returning: ProcessResult(
                        stdout: "",
                        stderr: "Failed to start process: \(error.localizedDescription)",
                        exitCode: nil,
                        status: .failure
                    ))
                    return
                }

                // Store process reference for cancellation
                Task { @MainActor in
                    self.runningProcesses[taskId] = process
                }

                // Timeout handling
                let timeoutWorkItem = DispatchWorkItem {
                    if process.isRunning {
                        process.terminate()
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: timeoutWorkItem)

                // Wait for process to finish (on background thread — won't block UI)
                process.waitUntilExit()
                timeoutWorkItem.cancel()

                // Wait for output collection
                group.wait()

                // Remove from running processes
                Task { @MainActor in
                    self.runningProcesses.removeValue(forKey: taskId)
                }

                lock.lock()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                lock.unlock()

                let exitCode = Int(process.terminationStatus)

                let status: ExecutionStatus
                switch process.terminationReason {
                case .uncaughtSignal:
                    status = .timeout
                case .exit:
                    status = (exitCode == 0 || ignoreExitCode) ? .success : .failure
                @unknown default:
                    status = .failure
                }

                self.executionSemaphore.signal()
                continuation.resume(returning: ProcessResult(
                    stdout: stdout,
                    stderr: stderr,
                    exitCode: exitCode,
                    status: status
                ))
            }
        }
    }
}
