import CoreServices
import XCTest
@testable import TaskTickApp

final class QuitFlowTests: XCTestCase {

    // MARK: - Session-end quit reasons

    /// Logout / restart / shutdown quit events must bypass the quit dialog —
    /// cancelling (or blocking on a modal) aborts the user's whole logout.
    func testSessionEndReasonsRecognized() {
        let reasons = [
            kAELogOut, kAEReallyLogOut,
            kAEShowRestartDialog, kAERestart,
            kAEShowShutdownDialog, kAEShutDown,
        ]
        for reason in reasons {
            XCTAssertTrue(
                AppDelegate.isSessionEndQuitReason(OSType(reason)),
                "reason \(reason) should be treated as session end"
            )
        }
    }

    /// A plain user quit carries no session-end reason — it must fall through
    /// to the confirmation dialog path.
    func testNonSessionEndReasonsRejected() {
        XCTAssertFalse(AppDelegate.isSessionEndQuitReason(0))
        XCTAssertFalse(AppDelegate.isSessionEndQuitReason(OSType(kAEQuitApplication)))
    }

    // MARK: - Installer script abort guard

    /// If the app is still alive when the wait window expires (quit cancelled
    /// or hung), the installer must NOT replace the bundle of a running app.
    func testInstallerScriptAbortsWhenAppStillAlive() throws {
        let env = try makeInstallEnvironment()
        defer { env.cleanup() }

        let script = UpdateChecker.installerScript(
            mountPoint: env.dir.appendingPathComponent("no-mount").path,
            sourceApp: env.source.path,
            destApp: env.dest.path,
            appPid: ProcessInfo.processInfo.processIdentifier, // our own pid — definitely alive
            waitSeconds: 1
        )
        let status = try runScript(script, in: env.dir)

        XCTAssertEqual(status, 1, "script should exit 1 when the app never quit")
        XCTAssertEqual(try env.destPayload(), "old", "running app's bundle must be left untouched")
    }

    /// Normal path: app has exited, bundle gets replaced.
    func testInstallerScriptReplacesWhenAppExited() throws {
        let env = try makeInstallEnvironment()
        defer { env.cleanup() }

        // Spawn a short-lived process and wait for it to die to get a pid
        // that is guaranteed dead.
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try probe.run()
        probe.waitUntilExit()

        let script = UpdateChecker.installerScript(
            mountPoint: env.dir.appendingPathComponent("no-mount").path,
            sourceApp: env.source.path,
            destApp: env.dest.path,
            appPid: probe.processIdentifier,
            waitSeconds: 1
        )
        let status = try runScript(script, in: env.dir)

        XCTAssertEqual(status, 0)
        XCTAssertEqual(try env.destPayload(), "new", "bundle should be replaced once the app is gone")
    }

    // MARK: - Helpers

    private struct InstallEnvironment {
        let dir: URL
        let source: URL
        let dest: URL

        func destPayload() throws -> String {
            try String(contentsOf: dest.appendingPathComponent("payload"), encoding: .utf8)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func makeInstallEnvironment() throws -> InstallEnvironment {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tasktick-quitflow-\(UUID().uuidString)")
        let source = dir.appendingPathComponent("Source.app")
        let dest = dir.appendingPathComponent("Dest.app")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try "new".write(to: source.appendingPathComponent("payload"), atomically: true, encoding: .utf8)
        try "old".write(to: dest.appendingPathComponent("payload"), atomically: true, encoding: .utf8)
        return InstallEnvironment(dir: dir, source: source, dest: dest)
    }

    private func runScript(_ script: String, in dir: URL) throws -> Int32 {
        let path = dir.appendingPathComponent("install.sh")
        try script.write(to: path, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [path.path]
        // `open` on the fake .app fails noisily; keep test output clean.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
