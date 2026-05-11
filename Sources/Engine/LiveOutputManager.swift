@preconcurrency import Combine
import Foundation
import TaskTickCore

struct LiveChunkEvent {
    let taskId: UUID
    let stream: String   // "stdout" or "stderr"
    let text: String
}

/// O(1)-per-chunk append-only line buffer. Replaces the previous design that
/// re-allocated the entire stdout/stderr String on every chunk via
/// `String(s.suffix(maxOutputSize))` — that was the smoking gun behind
/// issue #28 (single-core pegged at 100% by `appendStdout`, UI freeze).
///
/// Design:
/// - Lines accumulate in a normal `[String]`. Each newline-terminated chunk
///   becomes one entry. Append is O(1) amortized.
/// - Over the cap, we `removeFirst(N)` in a batch (amortized O(1) per append).
/// - The trailing incomplete line lives in `pending` so a chunk that ends
///   mid-line doesn't get stranded as a half-line in `lines`.
/// - `\r` (carriage return) resets the current line — that's the same
///   terminal semantics the old `appendWithCR` simulated, but O(C) on chunk
///   size only, never O(N) on existing buffer.
public struct LineBuffer: Sendable {
    /// Cap on retained lines. Beyond `maxLines + trimChunk`, drop oldest
    /// `trimChunk` lines. The batched trim is what keeps append amortized O(1).
    let maxLines: Int
    let trimChunk: Int
    /// Cap on the pending incomplete line. Without this, a script emitting
    /// long lines without newlines (e.g. `printf` progress) could grow
    /// `pending` unbounded.
    let maxPendingBytes: Int

    private(set) var lines: [String] = []
    private(set) var pending: String = ""

    public init(maxLines: Int = 5000, trimChunk: Int = 1000, maxPendingBytes: Int = 8 * 1024) {
        self.maxLines = maxLines
        self.trimChunk = trimChunk
        self.maxPendingBytes = maxPendingBytes
    }

    /// Append a chunk. The chunk may contain zero or more newlines.
    public mutating func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        // Normalize CRLF → LF. Swift String treats "\r\n" as a SINGLE
        // grapheme cluster, which means `firstIndex(of: "\n")` on a chunk
        // like "Line1\r\nLine2" returns nil — the LF inside the CRLF pair
        // is invisible to Character-level search. Without this normalization
        // Windows-style line endings would never split into lines.
        let normalized: String = chunk.contains("\r\n")
            ? chunk.replacingOccurrences(of: "\r\n", with: "\n")
            : chunk
        var remaining = Substring(normalized)
        while let newlineIdx = remaining.firstIndex(of: "\n") {
            let segment = remaining[..<newlineIdx]
            var line = pending + segment
            // CRLF is normalized away above. Any remaining trailing "\r" is
            // a real CR — but if it's the entire suffix with nothing after,
            // drop it (defensive — a chunk ending in just "\r\n" already got
            // normalized, but a bare "\r" followed by EOL has no useful
            // content to emit).
            if line.hasSuffix("\r") {
                line = String(line.dropLast())
            }
            if line.contains("\r") {
                // CR semantics: everything after the last CR overwrites the
                // current line. e.g. "abc\rxy" → "xy". This matches what
                // a real terminal would display.
                if let lastCR = line.lastIndex(of: "\r") {
                    line = String(line[line.index(after: lastCR)...])
                }
            }
            lines.append(line)
            pending = ""
            remaining = remaining[remaining.index(after: newlineIdx)...]
        }
        // Whatever's left after the last \n is incomplete — keep it in pending.
        var p = pending + remaining
        if p.contains("\r") {
            if let lastCR = p.lastIndex(of: "\r") {
                p = String(p[p.index(after: lastCR)...])
            }
        }
        if p.utf8.count > maxPendingBytes {
            // Pending overflows — promote the suffix as a "line" so it shows
            // in materialize() and reset pending. Otherwise an output without
            // newlines (rare but possible) would get stranded.
            let suffix = String(p.suffix(maxPendingBytes))
            lines.append(String(suffix.dropLast(maxPendingBytes / 2)))
            p = String(suffix.suffix(maxPendingBytes / 2))
        }
        pending = p

        // Amortized trim: drop a batch of oldest lines when significantly
        // over cap. This keeps append amortized O(1).
        if lines.count > maxLines + trimChunk {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    /// Build a single string for display. O(N) but called only from UI
    /// (~10 Hz at most), not on every chunk arrival.
    public func materialize() -> String {
        if pending.isEmpty {
            return lines.joined(separator: "\n")
        }
        if lines.isEmpty {
            return pending
        }
        return lines.joined(separator: "\n") + "\n" + pending
    }

    public var isEmpty: Bool {
        lines.isEmpty && pending.isEmpty
    }
}

private struct TaskBuffer {
    var stdout = LineBuffer()
    var stderr = LineBuffer()
}

@MainActor
final class LiveOutputManager: ObservableObject {
    static let shared = LiveOutputManager()

    /// Per-task tick counter. Incremented when a task's buffer changes and
    /// the throttle window expires. SwiftUI observers re-render when this
    /// dict changes, then read the materialized string via `stdout(for:)`.
    ///
    /// We don't `@Published` the buffer directly because (a) materializing
    /// to a String on every chunk is what we're escaping, and (b) buffers
    /// contain `[String]` whose diff cost is irrelevant to SwiftUI — only
    /// the tick matters as a re-render trigger.
    @Published private(set) var tick: [UUID: Int] = [:]

    nonisolated let chunkPublisher = PassthroughSubject<LiveChunkEvent, Never>()

    private var buffers: [UUID: TaskBuffer] = [:]
    private var pendingFlush: Set<UUID> = []
    private var throttleWorkItem: DispatchWorkItem?

    private init() {}

    // MARK: - Tracking lifecycle

    func startTracking(taskId: UUID) {
        buffers[taskId] = TaskBuffer()
        tick[taskId] = 0
    }

    func stopTracking(taskId: UUID) {
        flushNow()
        buffers.removeValue(forKey: taskId)
        tick.removeValue(forKey: taskId)
        pendingFlush.remove(taskId)
    }

    // MARK: - Append

    func appendStdout(taskId: UUID, data: Data) {
        guard buffers[taskId] != nil else { return }
        let str = String(decoding: data, as: UTF8.self)
        guard !str.isEmpty else { return }
        let cleaned = stripANSI(str)
        buffers[taskId]?.stdout.append(cleaned)
        chunkPublisher.send(LiveChunkEvent(taskId: taskId, stream: "stdout", text: str))
        pendingFlush.insert(taskId)
        scheduleFlush()
    }

    func appendStderr(taskId: UUID, data: Data) {
        guard buffers[taskId] != nil else { return }
        let str = String(decoding: data, as: UTF8.self)
        guard !str.isEmpty else { return }
        let cleaned = stripANSI(str)
        buffers[taskId]?.stderr.append(cleaned)
        chunkPublisher.send(LiveChunkEvent(taskId: taskId, stream: "stderr", text: str))
        pendingFlush.insert(taskId)
        scheduleFlush()
    }

    // MARK: - Read API (materialize on demand)

    func stdout(for taskId: UUID) -> String? {
        guard let buf = buffers[taskId] else { return nil }
        return buf.stdout.isEmpty ? nil : buf.stdout.materialize()
    }

    func stderr(for taskId: UUID) -> String? {
        guard let buf = buffers[taskId] else { return nil }
        return buf.stderr.isEmpty ? nil : buf.stderr.materialize()
    }

    func isTracking(_ taskId: UUID) -> Bool {
        buffers[taskId] != nil
    }

    // MARK: - Throttled flush

    private func scheduleFlush() {
        // Coalesce the per-task tick increment into a single trailing-edge
        // flush every 100ms. The first chunk after a quiet period still
        // gets a 100ms latency hit before the user sees it — acceptable for
        // live log streaming and well under perceptible UI lag.
        if throttleWorkItem != nil { return }
        let item = DispatchWorkItem { [weak self] in
            self?.flushNow()
        }
        throttleWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
    }

    private func flushNow() {
        throttleWorkItem?.cancel()
        throttleWorkItem = nil
        guard !pendingFlush.isEmpty else { return }
        for id in pendingFlush {
            tick[id, default: 0] += 1
        }
        pendingFlush.removeAll()
    }
}
