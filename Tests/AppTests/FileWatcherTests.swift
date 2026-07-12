import Testing
import Foundation
@testable import TaskTickApp

@Suite("FileWatcher Tests")
struct FileWatcherTests {

    /// Thread-safe callback counter (onChange fires on the main queue,
    /// assertions poll from the test thread).
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func makeTempFile(_ content: String = "initial") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("filewatcher-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("script.sh")
        try content.write(to: url, atomically: false, encoding: .utf8)
        return url
    }

    /// Polls `condition` for up to `timeout` seconds.
    private func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    @Test("文件被直接写入 → onChange 触发")
    func directWriteFires() async throws {
        let url = try makeTempFile()
        let counter = Counter()
        let watcher = FileWatcher(path: url.path) { counter.bump() }
        defer { watcher.cancel() }

        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data("echo hi\n".utf8))
        try handle.close()

        #expect(await waitFor { counter.count >= 1 }, "直接写入后应收到回调")
    }

    @Test("原子保存（写临时文件后 rename 覆盖）→ 触发且监听自动续上")
    func atomicReplaceRearms() async throws {
        let url = try makeTempFile()
        let counter = Counter()
        let watcher = FileWatcher(path: url.path) { counter.bump() }
        defer { watcher.cancel() }

        // 编辑器典型的原子保存：换 inode
        try "version 2".write(to: url, atomically: true, encoding: .utf8)
        #expect(await waitFor { counter.count >= 1 }, "原子替换后应收到回调")

        // 等 re-arm 完成后再次修改，验证监听没有断
        try await Task.sleep(nanoseconds: 400_000_000)
        let before = counter.count
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data("more\n".utf8))
        try handle.close()

        #expect(await waitFor { counter.count > before }, "原子替换后的再次写入仍应收到回调（re-arm）")
    }

    @Test("cancel 之后的修改不再触发")
    func cancelStopsEvents() async throws {
        let url = try makeTempFile()
        let counter = Counter()
        let watcher = FileWatcher(path: url.path) { counter.bump() }
        watcher.cancel()

        try await Task.sleep(nanoseconds: 100_000_000)
        let before = counter.count
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data("after cancel\n".utf8))
        try handle.close()

        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(counter.count == before, "cancel 后不应再有回调")
    }

    @Test("路径不存在 → 不崩溃、无回调、cancel 安全")
    func missingFileIsInert() async throws {
        let counter = Counter()
        let watcher = FileWatcher(path: "/nonexistent/path/script.sh") { counter.bump() }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(counter.count == 0)
        watcher.cancel()
        watcher.cancel() // 重复 cancel 也安全
    }

    @Test("重复 cancel 与释放不崩溃（fd 生命周期）")
    func doubleCancelAndDeinit() async throws {
        let url = try makeTempFile()
        var watcher: FileWatcher? = FileWatcher(path: url.path) {}
        watcher?.cancel()
        watcher?.cancel()
        watcher = nil // deinit 路径
        #expect(Bool(true))
    }

    @Test("连续多次写入被防抖合并为一次回调")
    func debounceCoalescesRapidWrites() async throws {
        let url = try makeTempFile()
        let counter = Counter()
        let watcher = FileWatcher(path: url.path) { counter.bump() }
        defer { watcher.cancel() }

        // 5 次写入，间隔 50ms —— 都落在防抖窗口内
        for i in 0..<5 {
            let handle = try FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            handle.write(Data("line \(i)\n".utf8))
            try handle.close()
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // 等防抖窗口完全结束
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(counter.count == 1, "5 次密集写入应合并为 1 次回调，实际 \(counter.count) 次")
    }

    @Test("文件被删除且延迟重建 → 重试梯队接管，重建后自动恢复监听并通知")
    func deleteThenSlowRecreateRecovers() async throws {
        let url = try makeTempFile()
        let counter = Counter()
        let watcher = FileWatcher(path: url.path) { counter.bump() }
        defer { watcher.cancel() }

        try FileManager.default.removeItem(at: url)
        // 拖过前两次重试（0.1s / 0.5s），模拟慢速「删除再写入」型编辑器
        try await Task.sleep(nanoseconds: 800_000_000)
        let beforeRecreate = counter.count

        try "recreated".write(to: url, atomically: false, encoding: .utf8)

        // 2s 档重试应重挂成功并主动通知一次（此后不再写入）
        let recovered = await waitFor({ counter.count > beforeRecreate }, timeout: 4)
        #expect(recovered, "重建文件后应通过重试梯队恢复监听并触发回调")

        // 恢复后的监听是活的：再写一次仍能收到
        try await Task.sleep(nanoseconds: 200_000_000)
        let beforeWrite = counter.count
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data("more\n".utf8))
        try handle.close()
        #expect(await waitFor({ counter.count > beforeWrite }, timeout: 2), "恢复后的写入仍应触发回调")
    }
}
