import Foundation

/// Watches a single file on disk and fires `onChange` (on the main queue)
/// whenever its content changes. Survives atomic saves (write-temp-then-
/// rename, the way most editors save) by re-arming on rename/delete events,
/// with a retry ladder for editors that delete first and write the new file
/// slowly. Rapid event bursts are debounced into a single callback.
/// All failure modes are silent: if the file can't be opened the watcher is
/// simply inert — callers degrade to their non-live behavior.
final class FileWatcher {
    private let path: String
    private let onChange: () -> Void
    private let debounce: TimeInterval
    /// Delays for re-opening the path after a rename/delete event. Covers
    /// both atomic saves (new file already in place → first try wins) and
    /// slow delete-then-write editors (later tries win).
    private static let rearmDelays: [TimeInterval] = [0.1, 0.5, 2.0]

    /// Serial queue owns all source/fd state, so event handling, debounce,
    /// re-arm and cancel never race.
    private let queue = DispatchQueue(label: "com.lifedever.TaskTick.FileWatcher")
    private var source: DispatchSourceFileSystemObject?
    private var pendingNotify: DispatchWorkItem?
    private var cancelled = false

    init(path: String, onChange: @escaping () -> Void, debounce: TimeInterval = 0.3) {
        self.path = path
        self.onChange = onChange
        self.debounce = debounce
        // Arm synchronously so no event between init and first edit is lost.
        // The private queue is empty at this point, so sync can't deadlock.
        queue.sync { start() }
    }

    /// Must run on `queue`. Returns whether the source was armed.
    @discardableResult
    private func start() -> Bool {
        guard !cancelled, source == nil else { return false }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return false } // file missing/unreadable → inert

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self, !self.cancelled, let src = self.source else { return }
            let events = src.data
            self.scheduleNotify()
            if events.contains(.rename) || events.contains(.delete) {
                // Atomic save (or delete) replaced the inode — the old fd now
                // points at a dead file. Drop it and re-open the path.
                self.source?.cancel()
                self.source = nil
                self.scheduleRearm(attempt: 0)
            }
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
        return true
    }

    /// Must run on `queue`. Debounces bursts of events into one callback.
    private func scheduleNotify() {
        pendingNotify?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.cancelled else { return }
            self.pendingNotify = nil
            DispatchQueue.main.async(execute: self.onChange)
        }
        pendingNotify = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    /// Retry ladder for re-arming after rename/delete. On success, fires a
    /// notify: the recreated file's content is what the rename/delete-time
    /// read may have missed, and no further event will arrive until the next
    /// edit.
    private func scheduleRearm(attempt: Int) {
        guard attempt < Self.rearmDelays.count else { return } // give up; next onAppear rebuilds
        queue.asyncAfter(deadline: .now() + Self.rearmDelays[attempt]) { [weak self] in
            guard let self, !self.cancelled, self.source == nil else { return }
            if self.start() {
                self.scheduleNotify()
            } else {
                self.scheduleRearm(attempt: attempt + 1)
            }
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            self.cancelled = true
            self.pendingNotify?.cancel()
            self.pendingNotify = nil
            self.source?.cancel()
            self.source = nil
        }
    }

    deinit {
        // deinit means no strong refs remain; handlers hold only weak self,
        // so cancelling directly here is safe even off-queue.
        pendingNotify?.cancel()
        source?.cancel()
    }
}
