import Foundation
import SwiftData

/// Strip ANSI escape sequences and terminal control codes.
/// Safe for plain text — only removes invisible control characters.
func stripANSI(_ text: String) -> String {
    text.replacingOccurrences(
        of: "\\x1b\\[[0-9;]*[A-Za-z]|\\x1b\\][^\u{07}]*\u{07}|\\x1b[()][A-Za-z0-9]|[\\x00-\\x08\\x0e-\\x1f]",
        with: "",
        options: .regularExpression
    )
}

/// Strip ANSI codes, simulate \r overwrites, and collapse consecutive empty lines.
/// Use for final output (not live streaming).
func cleanTerminalOutput(_ text: String) -> String {
    var cleaned = stripANSI(text)
    // Simulate \r: for lines containing \r, keep only the text after the last \r
    if cleaned.contains("\r") {
        cleaned = cleaned
            .components(separatedBy: "\n")
            .map { line in
                guard line.contains("\r") else { return line }
                let parts = line.components(separatedBy: "\r")
                return parts.last(where: { !$0.isEmpty }) ?? ""
            }
            .joined(separator: "\n")
    }
    // Collapse runs of blank lines into a single blank line
    cleaned = cleaned.replacingOccurrences(
        of: "\\n{3,}",
        with: "\n\n",
        options: .regularExpression
    )
    return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Decode process output data, stripping ANSI escape sequences at the byte level first
/// to avoid corrupted multi-byte UTF-8 sequences (ANSI codes can split CJK characters).
func decodeProcessOutput(_ data: Data) -> String {
    var cleaned = Data()
    cleaned.reserveCapacity(data.count)
    var i = data.startIndex
    while i < data.endIndex {
        if data[i] == 0x1B { // ESC
            i = data.index(after: i)
            guard i < data.endIndex else { break }
            if data[i] == 0x5B { // [ → CSI: skip until letter
                i = data.index(after: i)
                while i < data.endIndex {
                    let b = data[i]; i = data.index(after: i)
                    if (0x40...0x7E).contains(b) { break }
                }
            } else if data[i] == 0x5D { // ] → OSC: skip until BEL
                i = data.index(after: i)
                while i < data.endIndex && data[i] != 0x07 { i = data.index(after: i) }
                if i < data.endIndex { i = data.index(after: i) }
            } else if data[i] == 0x28 || data[i] == 0x29 { // charset
                i = data.index(after: i)
                if i < data.endIndex { i = data.index(after: i) }
            }
        } else if data[i] < 0x20 && data[i] != 0x09 && data[i] != 0x0A && data[i] != 0x0D {
            i = data.index(after: i) // strip control chars except tab/newline/CR
        } else {
            cleaned.append(data[i]); i = data.index(after: i)
        }
    }
    return String(decoding: cleaned, as: UTF8.self)
}

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
        do { try modelContext.save() } catch { NSLog("⚠️ ScriptExecutor save failed: \(error)") }

        let startTime = Date()

        // Capture task properties before going off main actor
        let shell = task.shell
        let preRunCommand = task.preRunCommand
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
        let effectiveShell: String
        if let filePath = task.scriptFilePath, !filePath.isEmpty {
            if let content = try? String(contentsOfFile: filePath, encoding: .utf8) {
                scriptBody = content
                // Respect shebang in script file if present
                effectiveShell = ScriptExecutor.parseShebang(from: content) ?? shell
            } else {
                // File not readable
                log.status = .failure
                log.stderr = "Cannot read script file: \(filePath)"
                log.finishedAt = Date()
                log.durationMs = 0
                do { try modelContext.save() } catch { NSLog("⚠️ ScriptExecutor save failed: \(error)") }
                return log
            }
        } else {
            scriptBody = task.scriptBody
            effectiveShell = shell
        }

        // Prepend pre-run commands (e.g. proxy exports) into the same shell invocation
        // so exported env vars are visible to the script that follows.
        let finalScript: String = {
            let trimmed = preRunCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? scriptBody : trimmed + "\n" + scriptBody
        }()

        LiveOutputManager.shared.startTracking(taskId: taskId)
        let result = await runProcess(
            shell: effectiveShell,
            script: finalScript,
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
            // Keep executionCount in sync for both manual and scheduled runs so the UI
            // badge and any downstream checks reflect actual completed executions.
            fetchedTask.executionCount = fetchedTask.executionLogs
                .filter { $0.modelContext != nil }
                .count
        }

        do { try modelContext.save() } catch { NSLog("⚠️ ScriptExecutor save failed: \(error)") }
        LiveOutputManager.shared.stopTracking(taskId: taskId)

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
            // Prefer stdout, fall back to stderr when stdout has no meaningful content
            let outputSource = ScriptExecutor.hasMeaningfulContent(result.stdout) ? result.stdout : result.stderr
            let outputLine = outputSource.components(separatedBy: .newlines).first(where: {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return false }
                let stripped = trimmed.filter { !("─═—–-=_*#~".contains($0)) }
                return !stripped.isEmpty
            }) ?? ""
            let body = [durationText, outputLine].filter { !$0.isEmpty }.joined(separator: " · ")
            NotificationManager.shared.sendNotification(
                title: "[\(L10n.tr("notification.succeeded"))] \(taskName)",
                body: body.isEmpty ? L10n.tr("notification.success") : body
            )
        }

        // Strong reminder: show floating panel with full output
        // Prefer stdout (actual results); fall back to stderr only if stdout is truly empty
        if result.status == .success && strongReminder {
            let trimmedStdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let output = trimmedStdout.isEmpty ? result.stderr : result.stdout
            StrongReminderPanel.shared.show(
                taskName: taskName,
                output: output,
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

    /// Thread-safe buffer for collecting pipe output from readabilityHandler closures.
    private final class PipeOutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private let _stdout = MutableDataBox()
        private let _stderr = MutableDataBox()

        func appendStdout(_ data: Data) {
            lock.lock()
            _stdout.data.append(data)
            lock.unlock()
        }

        func appendStderr(_ data: Data) {
            lock.lock()
            _stderr.data.append(data)
            lock.unlock()
        }

        func read() -> (stdout: Data, stderr: Data) {
            lock.lock()
            let result = (_stdout.data, _stderr.data)
            lock.unlock()
            return result
        }

        private final class MutableDataBox: @unchecked Sendable {
            var data = Data()
        }
    }

    /// Extract the interpreter path from a shebang line (e.g. "#!/opt/homebrew/bin/bash" → "/opt/homebrew/bin/bash").
    /// Returns nil if no valid shebang or the interpreter doesn't exist on disk.
    static func parseShebang(from script: String) -> String? {
        guard let firstLine = script.components(separatedBy: .newlines).first,
              firstLine.hasPrefix("#!") else { return nil }
        // Strip "#!" and trim whitespace, take the first token (ignore arguments like "#!/usr/bin/env bash")
        let interpreterLine = firstLine.dropFirst(2).trimmingCharacters(in: .whitespaces)
        let parts = interpreterLine.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard let first = parts.first, !first.isEmpty else { return nil }
        // Handle "#!/usr/bin/env <interpreter>" — resolve via PATH
        if first == "/usr/bin/env", let cmd = parts.dropFirst().first {
            // Use the full command path if it's absolute, otherwise just return nil and fall back to UI shell
            if cmd.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: cmd) {
                return cmd
            }
            return nil
        }
        // Direct path like "#!/opt/homebrew/bin/bash"
        if FileManager.default.isExecutableFile(atPath: first) {
            return first
        }
        return nil
    }

    /// Check if a string contains meaningful printable content (not just whitespace).
    static func hasMeaningfulContent(_ text: String) -> Bool {
        text.contains(where: { !$0.isWhitespace && !$0.isNewline && ($0.asciiValue.map({ $0 >= 32 }) ?? true) })
    }

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
                // Use login shell (-l) for .zprofile, then source .zshrc/.bashrc
                // for user environment variables without full interactive mode
                // (which would load oh-my-zsh etc. and slow down execution).
                let rcFile: String
                if shell.hasSuffix("zsh") {
                    rcFile = "[ -f ~/.zshrc ] && source ~/.zshrc 2>/dev/null; "
                } else if shell.hasSuffix("bash") {
                    // For Homebrew bash, ensure brew shellenv is loaded for PATH
                    let brewPrefix = shell.hasPrefix("/opt/homebrew/")
                        ? "eval $(/opt/homebrew/bin/brew shellenv 2>/dev/null); "
                        : ""
                    rcFile = brewPrefix + "[ -f ~/.bashrc ] && source ~/.bashrc 2>/dev/null; "
                } else {
                    rcFile = ""
                }
                process.arguments = ["-l", "-c", rcFile + script]
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

                // Collect output incrementally via readabilityHandler for real-time streaming
                let stdoutHandle = stdoutPipe.fileHandleForReading
                let stderrHandle = stderrPipe.fileHandleForReading

                let outputBuffer = PipeOutputBuffer()

                stdoutHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else {
                        stdoutHandle.readabilityHandler = nil
                        return
                    }
                    outputBuffer.appendStdout(data)
                    DispatchQueue.main.async {
                        LiveOutputManager.shared.appendStdout(taskId: taskId, data: data)
                    }
                }

                stderrHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else {
                        stderrHandle.readabilityHandler = nil
                        return
                    }
                    outputBuffer.appendStderr(data)
                    DispatchQueue.main.async {
                        LiveOutputManager.shared.appendStderr(taskId: taskId, data: data)
                    }
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

                // Timeout handling: send SIGTERM first, then SIGKILL 3s later if still alive.
                // Prevents scripts that ignore SIGTERM from blocking waitUntilExit forever,
                // which would leak the execution semaphore slot.
                let timeoutWorkItem = DispatchWorkItem {
                    if process.isRunning {
                        process.terminate()
                    }
                }
                let killWorkItem = DispatchWorkItem {
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: timeoutWorkItem)
                DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSeconds + 3), execute: killWorkItem)

                // Wait for process to finish (on background thread — won't block UI)
                process.waitUntilExit()
                timeoutWorkItem.cancel()
                killWorkItem.cancel()

                // Drain remaining pipe data after process exits
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
                let remainingStdout = stdoutHandle.readDataToEndOfFile()
                let remainingStderr = stderrHandle.readDataToEndOfFile()
                if !remainingStdout.isEmpty { outputBuffer.appendStdout(remainingStdout) }
                if !remainingStderr.isEmpty { outputBuffer.appendStderr(remainingStderr) }

                // Remove from running processes
                Task { @MainActor in
                    self.runningProcesses.removeValue(forKey: taskId)
                }

                let (stdoutData, stderrData) = outputBuffer.read()
                let stdout = cleanTerminalOutput(decodeProcessOutput(stdoutData))
                let stderr = cleanTerminalOutput(decodeProcessOutput(stderrData))

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
