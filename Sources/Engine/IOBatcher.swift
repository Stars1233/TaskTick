import Foundation

/// Per-task pipe-output coalescer. Accumulates stdout/stderr `Data` chunks
/// across the 50ms throttle window, then dispatches a single batched call
/// into `LiveOutputManager` on the main thread.
///
/// Why: a busy script (npm run dev + Spring Boot together easily emit
/// 100+ chunks/sec) fired one `DispatchQueue.main.async` per chunk under
/// the previous design — main-queue churn alone was enough to glaze the
/// UI even before SwiftUI Text layout costs hit. Batching reduces that
/// to ~20 hops/sec at most, regardless of pipe firing rate.
///
/// Concurrency: the readabilityHandler runs on an arbitrary GCD thread,
/// so all internal mutation goes through an NSLock. The main-side flush
/// is scheduled via `DispatchQueue.main.asyncAfter` and only when no
/// flush is already pending — first chunk schedules, subsequent chunks
/// pile onto the same scheduled flush.
final class IOBatcher: @unchecked Sendable {
    private let taskId: UUID
    private let flushInterval: TimeInterval

    private let lock = NSLock()
    private var pendingStdout = Data()
    private var pendingStderr = Data()
    private var scheduled = false

    init(taskId: UUID, flushInterval: TimeInterval = 0.05) {
        self.taskId = taskId
        self.flushInterval = flushInterval
    }

    func appendStdout(_ data: Data) {
        let shouldSchedule = mutate { self.pendingStdout.append(data) }
        if shouldSchedule { scheduleFlush() }
    }

    func appendStderr(_ data: Data) {
        let shouldSchedule = mutate { self.pendingStderr.append(data) }
        if shouldSchedule { scheduleFlush() }
    }

    /// Force-flush pending data through the main queue immediately. Called
    /// at process exit so the last frame lands before tracking is torn down.
    func flushNow() {
        DispatchQueue.main.async { [weak self] in
            self?.flush()
        }
    }

    /// Atomically apply a mutation, then report whether a flush should be
    /// scheduled (true only when no flush is already pending).
    private func mutate(_ block: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        block()
        if scheduled { return false }
        scheduled = true
        return true
    }

    private func scheduleFlush() {
        DispatchQueue.main.asyncAfter(deadline: .now() + flushInterval) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        lock.lock()
        let so = pendingStdout
        let se = pendingStderr
        pendingStdout = Data()
        pendingStderr = Data()
        scheduled = false
        lock.unlock()

        if so.isEmpty && se.isEmpty { return }
        // `LiveOutputManager.shared.appendStdout` is @MainActor. We're on the
        // main queue because of asyncAfter/async, so it's safe to assume
        // isolation and call directly without an extra hop.
        let id = taskId
        MainActor.assumeIsolated {
            if !so.isEmpty {
                LiveOutputManager.shared.appendStdout(taskId: id, data: so)
            }
            if !se.isEmpty {
                LiveOutputManager.shared.appendStderr(taskId: id, data: se)
            }
        }
    }
}
