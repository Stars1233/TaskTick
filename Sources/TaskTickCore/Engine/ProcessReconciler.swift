import Foundation
import Darwin

/// PID-level liveness + start-time fingerprinting for the running-process
/// reconciler. All functions are pure and safe to call from any thread.
///
/// `isAlive` is a POSIX `kill(pid, 0)` probe — returns true iff a process
/// with that PID exists AND we have permission to signal it. On macOS,
/// processes started by the same user (the only ones TaskTick spawns) are
/// always signalable, so EPERM here means the PID has been recycled to a
/// process owned by another user — treat that as "not the same process".
///
/// `startTime` runs `ps -p <pid> -o lstart=` and returns the trimmed output
/// (e.g. `Mon May 12 14:23:45 2026`). The value is locale-formatted but
/// stable across calls for the same process, which is all the reconciler
/// needs — we compare strings, never parse.
public enum ProcessReconciler {

    public static func isAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        // kill(pid, 0): no signal sent, just permission/existence check.
        // Returns 0 on success. ESRCH = no such process. EPERM = exists but
        // we can't signal it (different uid) — for our purposes, treat as
        // "not us, don't touch".
        if kill(pid, 0) == 0 { return true }
        return false
    }

    public static func startTime(pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-p", "\(pid)", "-o", "lstart="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()  // swallow stderr ("no such process" noise)
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        // ps exits non-zero (1) when the pid doesn't exist.
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
