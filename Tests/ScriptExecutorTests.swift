import Testing
import Foundation
@testable import TaskTick

@Suite("ScriptExecutor Tests")
struct ScriptExecutorTests {

    @Test("Executor singleton exists")
    @MainActor
    func executorExists() {
        let executor = ScriptExecutor.shared
        #expect(executor != nil)
    }

    /// Reproduces the ipcheck output-truncation bug: runs the same ipcheck
    /// script through the exact Process+Pipe+decode+clean pipeline the app
    /// uses, and asserts that the proxycheck section and 综合建议 block — both
    /// emitted from a single inline `python3 -c` heredoc — survive intact.
    ///
    /// Skipped automatically when the script or a local proxy on 127.0.0.1:7890
    /// isn't available, so CI without network doesn't fail.
    @Test("ipcheck output is not silently truncated")
    func ipcheckOutputSurvivesProcessingPipeline() async throws {
        let scriptPath = "/Users/gefangshuai/Documents/Dev/script/paths/ipcheck"
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            // Local dev machine fixture — not available in CI
            return
        }
        guard let scriptBody = try? String(contentsOfFile: scriptPath, encoding: .utf8) else {
            return
        }

        let preRun = """
        export https_proxy=http://127.0.0.1:7890
        export http_proxy=http://127.0.0.1:7890
        export all_proxy=socks5://127.0.0.1:7891
        """
        // Exactly matches ScriptExecutor.runProcess assembly
        let fm = FileManager.default
        let brewPrefix: String
        if fm.isExecutableFile(atPath: "/opt/homebrew/bin/brew") {
            brewPrefix = "eval \"$(/opt/homebrew/bin/brew shellenv 2>/dev/null)\"; "
        } else if fm.isExecutableFile(atPath: "/usr/local/bin/brew") {
            brewPrefix = "eval \"$(/usr/local/bin/brew shellenv 2>/dev/null)\"; "
        } else {
            brewPrefix = ""
        }
        let rcFile = brewPrefix + "[ -f ~/.bashrc ] && source ~/.bashrc 2>/dev/null; "
        let fullScript = rcFile + preRun + "\n" + scriptBody

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-l", "-c", fullScript]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var data = Data()
            func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
            func read() -> Data { lock.lock(); defer { lock.unlock() }; return data }
        }
        let stdoutBox = Box()
        let stderrBox = Box()

        let outHandle = stdoutPipe.fileHandleForReading
        let errHandle = stderrPipe.fileHandleForReading
        outHandle.readabilityHandler = { handle in
            let d = handle.availableData
            guard !d.isEmpty else { handle.readabilityHandler = nil; return }
            stdoutBox.append(d)
        }
        errHandle.readabilityHandler = { handle in
            let d = handle.availableData
            guard !d.isEmpty else { handle.readabilityHandler = nil; return }
            stderrBox.append(d)
        }

        try process.run()
        process.waitUntilExit()

        outHandle.readabilityHandler = nil
        errHandle.readabilityHandler = nil
        stdoutBox.append(outHandle.readDataToEndOfFile())
        stderrBox.append(errHandle.readDataToEndOfFile())
        let stdoutData = stdoutBox.read()
        let stderrData = stderrBox.read()

        // Pipeline the app applies to captured bytes
        let rawStdout = decodeProcessOutput(stdoutData)
        let cleanedStdout = cleanTerminalOutput(rawStdout)
        let rawStderr = decodeProcessOutput(stderrData)

        // If there's no proxy locally, skip — otherwise the script fails as
        // expected and the assertions wouldn't be meaningful.
        if cleanedStdout.contains("无法获取出口 IP") {
            return
        }

        // These three fragments are each emitted by a different layer of the
        // script. If any single one is missing, we know which layer got eaten.
        let expectations: [(label: String, needle: String)] = [
            ("ipinfo.io bash section",          "归属信息 (ipinfo.io)"),
            ("proxycheck header (bash echo)",   "风控评分 (proxycheck.io)"),
            ("proxycheck details (python3)",    "Risk Score"),
            ("综合建议 block (python3)",         "💡 综合建议"),
            ("链接尾部 (bash echo)",             "查住宅代理挂靠"),
        ]

        for (label, needle) in expectations {
            #expect(
                cleanedStdout.contains(needle),
                "Missing '\(label)' in app-processed output.\nSTDOUT:\n\(cleanedStdout)\n\nSTDERR:\n\(rawStderr)"
            )
        }
    }
}
