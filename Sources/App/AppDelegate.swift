import AppKit
import SwiftData
import SwiftUI
import TaskTickCore

/// Show a modal warning alert for a non-fatal error. Use at sites where we previously
/// swallowed errors with `try?` and the user needs to know the action didn't take effect.
@MainActor
func presentErrorAlert(titleKey: String, messageKey: String, error: Error) {
    let alert = NSAlert()
    alert.messageText = L10n.tr(titleKey)
    alert.informativeText = L10n.tr(messageKey, error.localizedDescription)
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.runModal()
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// When true, `NSApp.terminate` actually quits. Otherwise Cmd+Q just closes windows.
    @MainActor static var shouldReallyQuit = false

    private var revealObserver: NSObjectProtocol?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationManager.shared.requestPermission()

        // One-shot launch-time CLI symlink repair: detects /usr/local/bin/tasktick
        // (or /opt/homebrew/bin/tasktick) symlinks left over from v1.8.0/1.8.1
        // pointing at the now-relocated CLI binary, and offers a single-click
        // admin-prompt repair via osascript. No-op when symlinks are already
        // correct or absent.
        CLISymlinkRepair.checkAndRepairIfNeeded()

        // Apply saved appearance mode
        let mode = UserDefaults.standard.string(forKey: "appearanceMode") ?? "system"
        switch mode {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }

        // Wire up the quick launcher's SwiftData container and arm the global
        // hotkey based on persisted settings. Order matters: the controller
        // needs the container BEFORE the hotkey can fire (otherwise the panel
        // would open with no @Query data source).
        Task { @MainActor in
            QuickLauncherController.shared.configure(modelContainer: TaskTickApp._sharedModelContainer)
            QuickLauncherSettings.shared.applyToHotkey()
            // Spawn macOS's CursorUIViewService now so it's already warm
            // when the user later opens QL. Without this, the first
            // text-field focus flashes a default-background overlay frame
            // beneath the search bar.
            QuickLauncherController.shared.prewarmCursorUI()
            cleanupStaleRunningLogs()
        }

        // Quick Launcher's ⌘O posts this notification to ask for the main
        // window to be focused. We listen here (not in MenuBarView) because
        // MenuBarExtra(.window) lazy-instantiates its body — if the user has
        // never clicked the menu bar icon this session, the SwiftUI observer
        // is never wired up and the notification gets dropped.
        revealObserver = NotificationCenter.default.addObserver(
            forName: .revealTaskInMain,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AppDelegate.bringMainWindowForward()
            }
        }

        installSignalHandlers()
    }

    /// Catch SIGTERM / SIGINT / SIGHUP so the shutdown path runs on those too.
    /// AppKit doesn't install signal handlers by default — `pkill TaskTick`,
    /// `kill <pid>`, terminal Ctrl+C, etc. would otherwise drop the process
    /// instantly, leaving spawned scripts re-parented to launchd as orphans
    /// (the exact "zombie task" behavior that fired this fix). SIGKILL we
    /// can't catch — that's just an unfixable hole the OS reserves.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            // Disable the default disposition so the dispatch source can
            // deliver the signal at our event handler instead.
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                MainActor.assumeIsolated {
                    AppDelegate.gracefulShutdown()
                }
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    /// Single shutdown path used by both `applicationWillTerminate` and the
    /// signal handlers. Idempotent: cancelAll snapshots and clears the
    /// running-processes dict, so re-entry is a no-op.
    @MainActor
    static func gracefulShutdown() {
        ScriptExecutor.shared.cancelAll(graceful: 0.2)
        TaskScheduler.shared.stop()
        do {
            try TaskTickApp._sharedModelContainer.mainContext.save()
        } catch {
            NSLog("⚠️ Final save on shutdown failed: \(error.localizedDescription)")
        }
        // save() writes to the -wal sidecar but does NOT merge it into the main store.
        // If the update installer replaces the .app right after this, a -wal left
        // behind can be orphaned and its contents lost. Force a checkpoint now so
        // the main store is self-contained.
        StoreHardener.checkpoint(at: TaskTickApp._storeURL)
    }

    /// Surface the SwiftUI main window. SwiftUI's `Window(id:)` destroys its
    /// NSWindow on close, so we can't just call `makeKeyAndOrderFront` on a
    /// stale reference — we need `openWindow` to resurrect it. The action is
    /// captured by MainWindowView at first appear and stashed in
    /// `WindowOpener.shared`. The activation+raise step runs after a tick so
    /// SwiftUI has time to install the new NSWindow into the window list.
    @MainActor
    static func bringMainWindowForward() {
        NSApp.setActivationPolicy(.regular)
        WindowOpener.shared.openMain?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            for window in NSApp.windows where window.canBecomeMain && !(window is NSPanel) {
                window.makeKeyAndOrderFront(nil)
                break
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Reconcile logs left in `.running` state by a previous session.
    /// Four cases:
    ///   1. log.pid == nil → legacy entry pre-dating this feature. Mark cancelled.
    ///   2. PID dead       → process exited while we were down. Mark cancelled.
    ///   3. PID alive, lstart mismatch → PID was recycled to a different
    ///      process. Mark cancelled. NEVER signal — the new owner may be
    ///      anything (Safari, etc.) and killing it would be catastrophic.
    ///   4. PID alive, lstart match → adopt: register in adoptedProcesses,
    ///      mark in runningTaskIDs so the UI lights up correctly.
    @MainActor
    private func cleanupStaleRunningLogs() {
        let context = TaskTickApp._sharedModelContainer.mainContext
        let runningRaw = ExecutionStatus.running.rawValue
        let descriptor = FetchDescriptor<ExecutionLog>(
            predicate: #Predicate { $0.statusRaw == runningRaw }
        )
        guard let logs = try? context.fetch(descriptor), !logs.isEmpty else { return }

        let now = Date()
        var adopted = 0
        var cancelled = 0

        for log in logs {
            guard let pid = log.pid, let recordedStart = log.processStartTime else {
                // Case 1: legacy entry
                log.status = .cancelled
                log.finishedAt = now
                if log.durationMs == nil {
                    log.durationMs = Int(now.timeIntervalSince(log.startedAt) * 1000)
                }
                cancelled += 1
                continue
            }

            if !ProcessReconciler.isAlive(pid: pid) {
                // Case 2: process exited
                log.status = .cancelled
                log.finishedAt = now
                if log.durationMs == nil {
                    log.durationMs = Int(now.timeIntervalSince(log.startedAt) * 1000)
                }
                if (log.stderr ?? "").isEmpty {
                    log.stderr = "[TaskTick] Process \(pid) exited while the app was not running. Exit code unknown."
                }
                cancelled += 1
                continue
            }

            let currentStart = ProcessReconciler.startTime(pid: pid)
            guard currentStart == recordedStart else {
                // Case 3: PID recycled — do NOT touch the live process
                log.status = .cancelled
                log.finishedAt = now
                if log.durationMs == nil {
                    log.durationMs = Int(now.timeIntervalSince(log.startedAt) * 1000)
                }
                if (log.stderr ?? "").isEmpty {
                    log.stderr = "[TaskTick] PID \(pid) was recycled by macOS to a different process; this log's owner is presumed dead."
                }
                cancelled += 1
                continue
            }

            // Case 4: adopt
            if let taskID = log.task?.id {
                ScriptExecutor.shared.adoptedProcesses[taskID] = pid
                TaskScheduler.shared.runningTaskIDs.insert(taskID)
                if (log.stdout ?? "").isEmpty == false {
                    log.stdout = (log.stdout ?? "") +
                        "\n\n[TaskTick] App was restarted while this script kept running. Output capture is paused — Stop will still work."
                }
                adopted += 1
            } else {
                // Orphan log (task was deleted) — clean up
                log.status = .cancelled
                log.finishedAt = now
                cancelled += 1
            }
        }

        try? context.save()

        if adopted > 0 || cancelled > 0 {
            NSLog("Reconcile: adopted \(adopted) running process(es), cancelled \(cancelled) stale log(s)")
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if AppDelegate.shouldReallyQuit {
            // Block the quit behind a confirmation when scripts are still
            // running. Without this, dev servers / long-running tasks would be
            // SIGKILLed without warning, sometimes losing in-progress work
            // (uncommitted edits in a watcher script, half-written DB rows, …).
            let runningNames = runningTaskNames()
            if !runningNames.isEmpty, !confirmQuitWithRunningScripts(runningNames) {
                AppDelegate.shouldReallyQuit = false
                return .terminateCancel
            }
            return .terminateNow
        }
        // Cmd+Q: just close all windows instead of quitting
        for window in sender.windows {
            if window.isVisible && window.canBecomeMain {
                window.close()
            }
        }
        NSApp.setActivationPolicy(.accessory)
        return .terminateCancel
    }

    @MainActor
    private func runningTaskNames() -> [String] {
        let runningIDs = TaskScheduler.shared.runningTaskIDs
        guard !runningIDs.isEmpty else { return [] }
        let context = TaskTickApp._sharedModelContainer.mainContext
        guard let tasks = try? context.fetch(FetchDescriptor<ScheduledTask>()) else { return [] }
        return tasks.filter { runningIDs.contains($0.id) }.map(\.name)
    }

    @MainActor
    private func confirmQuitWithRunningScripts(_ names: [String]) -> Bool {
        let alert = NSAlert()
        alert.messageText = L10n.tr("quit.confirm.title")
        let bullets = names.map { "• \($0)" }.joined(separator: "\n")
        alert.informativeText = L10n.tr("quit.confirm.message", names.count) + "\n\n" + bullets
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.tr("quit.confirm.cancel"))
        let quitButton = alert.addButton(withTitle: L10n.tr("quit.confirm.quit"))
        quitButton.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Re-open main window when dock icon is clicked
        if !flag {
            for window in sender.windows {
                if window.canBecomeMain {
                    window.makeKeyAndOrderFront(self)
                    break
                }
            }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Switch to accessory mode (menu bar only) when all windows are closed
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppDelegate.gracefulShutdown()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let parsed = CLIBridge.shared.parse(url: url) else {
                NSLog("⚠️ AppDelegate: malformed URL \(url.absoluteString)")
                continue
            }
            CLIBridge.shared.handle(action: parsed.action, taskId: parsed.taskId)
        }
    }
}
