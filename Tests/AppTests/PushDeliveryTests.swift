import Testing
import Foundation
import SwiftData
import TaskTickCore
@testable import TaskTickApp

/// End to end for issue #55: run a real task through `ScriptExecutor` and read
/// the push request that actually leaves the app. A URLProtocol stub answers
/// for one made-up host only, so nothing else in the suite is intercepted.
@Suite("Push delivery", .serialized)
@MainActor
struct PushDeliveryTests {

    @Test("推送用推送端自己的自定义内容，不用通知端的")
    func pushUsesItsOwnTemplate() async throws {
        let body = try await runAndCapture { task in
            task.notificationTemplateEnabled = true
            task.notificationTemplate = "NOTIFY {{lastLine}}"
            task.pushTemplateEnabled = true
            task.pushTemplate = "PUSH {{lastLine}}"
        }
        let sent = try #require(body, "没有发出推送")
        #expect(sent.contains("PUSH hello"))
        #expect(!sent.contains("NOTIFY"))
    }

    @Test("推送端没设过内容的老任务，沿用通知端的自定义内容")
    func preSplitTaskStillPushesTheNotificationTemplate() async throws {
        let body = try await runAndCapture { task in
            task.notificationTemplateEnabled = true
            task.notificationTemplate = "NOTIFY {{lastLine}}"
        }
        let sent = try #require(body, "没有发出推送")
        #expect(sent.contains("NOTIFY hello"))
    }

    @Test("关掉推送端的自定义内容，回到默认文案")
    func pushTemplateOffFallsBackToDefaultWording() async throws {
        let body = try await runAndCapture { task in
            task.notificationTemplateEnabled = true
            task.notificationTemplate = "NOTIFY {{lastLine}}"
            task.pushTemplateEnabled = false
            task.pushTemplate = "PUSH {{lastLine}}"
        }
        let sent = try #require(body, "没有发出推送")
        #expect(sent.contains("hello"))
        #expect(!sent.contains("PUSH"))
        #expect(!sent.contains("NOTIFY"))
    }

    @Test("关掉成功时推送，成功的运行不发推送")
    func pushOnSuccessOffSendsNothing() async throws {
        let body = try await runAndCapture(waitSeconds: 1.5) { task in
            task.pushOnSuccess = false
        }
        #expect(body == nil)
    }

    // MARK: - Harness

    /// Runs `echo hello` with push pointed at the stub and returns the body of
    /// the first push request, or nil if none arrived within `waitSeconds`.
    private func runAndCapture(
        waitSeconds: Double = 5,
        configure: (ScheduledTask) -> Void
    ) async throws -> String? {
        let channel = PushChannel(
            kind: .webhook,
            name: "capture",
            serverURL: "http://\(CapturingURLProtocol.host)/hook"
        )
        let defaults = UserDefaults.standard
        let savedChannels = defaults.data(forKey: PushChannelStore.defaultsKey)
        PushChannelStore.save([channel], to: defaults)
        URLProtocol.registerClass(CapturingURLProtocol.self)
        CapturingURLProtocol.capture.reset()
        defer {
            URLProtocol.unregisterClass(CapturingURLProtocol.self)
            if let savedChannels {
                defaults.set(savedChannels, forKey: PushChannelStore.defaultsKey)
            } else {
                defaults.removeObject(forKey: PushChannelStore.defaultsKey)
            }
        }

        let schema = Schema([ScheduledTask.self, ExecutionLog.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = container.mainContext
        let task = ScheduledTask(name: "push-e2e", scriptBody: "echo hello")
        // Keep the macOS banner out of a test run; push is decided on its own.
        task.notifyOnSuccess = false
        task.notifyOnFailure = false
        task.pushEnabled = true
        task.pushChannelIDs = [channel.id]
        configure(task)
        context.insert(task)
        try context.save()

        let log = await ScriptExecutor.shared.execute(task: task, modelContext: context)
        #expect(log.status == .success)

        let deadline = Date().addingTimeInterval(waitSeconds)
        while Date() < deadline {
            if let body = CapturingURLProtocol.capture.first { return body }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }
}

/// Answers requests for `host` with 200 and records their bodies.
final class CapturingURLProtocol: URLProtocol, @unchecked Sendable {
    static let host = "push-capture.tasktick.test"
    static let capture = Capture()

    final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [String] = []
        var first: String? { lock.withLock { bodies.first } }
        func reset() { lock.withLock { bodies.removeAll() } }
        func append(_ body: String) { lock.withLock { bodies.append(body) } }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        // URLSession moves the body into a stream before it reaches a protocol.
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
        }
        Self.capture.append(String(decoding: data, as: UTF8.self))
        if let url = request.url,
           let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
