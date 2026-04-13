import Foundation

@MainActor
final class LiveOutputManager: ObservableObject {
    static let shared = LiveOutputManager()

    @Published private(set) var liveOutputs: [UUID: LiveOutput] = [:]

    struct LiveOutput {
        var stdout: String = ""
        var stderr: String = ""
    }

    private var pendingUpdates: [UUID: LiveOutput] = [:]
    private var throttleWorkItem: DispatchWorkItem?

    private init() {}

    /// Append stdout chunk for a task (called from background thread via DispatchQueue.main)
    func appendStdout(taskId: UUID, data: Data) {
        // Drop late chunks that land after stopTracking — otherwise they resurrect a buffer
        // that the next execution of the same task would inherit as "ghost" output.
        guard liveOutputs[taskId] != nil else { return }
        let str = String(decoding: data, as: UTF8.self)
        guard !str.isEmpty else { return }
        var output = pendingUpdates[taskId] ?? liveOutputs[taskId] ?? LiveOutput()
        output.stdout = Self.appendWithCR(existing: output.stdout, chunk: stripANSI(str))
        // Enforce 512KB limit
        if output.stdout.utf8.count > ExecutionLog.maxOutputSize {
            output.stdout = String(output.stdout.suffix(ExecutionLog.maxOutputSize))
        }
        pendingUpdates[taskId] = output
        scheduleFlush()
    }

    /// Append stderr chunk for a task (called from background thread via DispatchQueue.main)
    func appendStderr(taskId: UUID, data: Data) {
        guard liveOutputs[taskId] != nil else { return }
        let str = String(decoding: data, as: UTF8.self)
        guard !str.isEmpty else { return }
        var output = pendingUpdates[taskId] ?? liveOutputs[taskId] ?? LiveOutput()
        output.stderr = Self.appendWithCR(existing: output.stderr, chunk: stripANSI(str))
        if output.stderr.utf8.count > ExecutionLog.maxOutputSize {
            output.stderr = String(output.stderr.suffix(ExecutionLog.maxOutputSize))
        }
        pendingUpdates[taskId] = output
        scheduleFlush()
    }

    /// Simulate terminal \r behavior: \r overwrites the current line from the beginning.
    private static func appendWithCR(existing: String, chunk: String) -> String {
        guard chunk.contains("\r") else { return existing + chunk }
        var result = existing
        for part in chunk.components(separatedBy: "\r") {
            if part.isEmpty { continue }
            if part.hasPrefix("\n") {
                // \r\n = newline, just append
                result += part
            } else {
                // \r without \n = overwrite current line
                if let lastNewline = result.lastIndex(of: "\n") {
                    result = String(result[...lastNewline]) + part
                } else {
                    result = part
                }
            }
        }
        return result
    }

    /// Start tracking a task
    func startTracking(taskId: UUID) {
        liveOutputs[taskId] = LiveOutput()
    }

    /// Stop tracking and clear buffer
    func stopTracking(taskId: UUID) {
        flushNow()
        liveOutputs.removeValue(forKey: taskId)
        pendingUpdates.removeValue(forKey: taskId)
    }

    /// Flush pending updates to published property (throttled to 100ms)
    private func scheduleFlush() {
        throttleWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.flushNow()
        }
        throttleWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
    }

    private func flushNow() {
        throttleWorkItem?.cancel()
        throttleWorkItem = nil
        for (taskId, output) in pendingUpdates {
            liveOutputs[taskId] = output
        }
        pendingUpdates.removeAll()
    }
}
