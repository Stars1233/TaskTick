# Run-On-Launch Design

GitHub issue: [lifedever/TaskTick#25](https://github.com/lifedever/TaskTick/issues/25)

## Goal

Allow a task to run **once every time the App finishes launching**, independent
of any time-based schedule. Useful for "no-schedule, fire-on-launch" tasks
(maintenance scripts, environment setup, status pings).

This is **distinct from** the existing `runMissedExecution` flag. The latter
catches up *missed scheduled runs* when their `nextRunAt` is overdue; the new
flag fires unconditionally on every launch even if the task has no schedule or
already ran today.

## Decisions

- **Approach**: independent additive boolean field `runOnLaunch: Bool = false`
  on `ScheduledTask`. Coexists with all existing schedule fields and with
  `runMissedExecution`.
- **Trigger timing**: 3 seconds after `TaskScheduler.start()`. Lets the model
  context, scheduler, and main window finish initializing before scripts fire.
- **Trigger identity**: a new `TriggerType.launch` case is added so logs show
  `Trigger: Launch` (or 启动) instead of being misclassified as Scheduled.
- **Dedup with `runMissedExecution`**: if a launch sweep fires a task whose
  `nextRunAt` was already overdue, the launch run *replaces* the missed-run
  catch-up — the task's `nextRunAt` is advanced past the overdue moment so the
  subsequent `rebuildSchedule()` does not fire it a second time.

## Changes

### Model
`Sources/Models/ScheduledTask.swift`:

```swift
var runOnLaunch: Bool = false
```

Default `false` — preserves existing behavior on SwiftData lightweight
migration.

### Trigger enum
`Sources/Models/ExecutionLog.swift`:

```swift
enum TriggerType: String, Codable, Sendable {
    case schedule = "schedule"
    case manual   = "manual"
    case launch   = "launch"   // new
}
```

### Scheduler
`Sources/Engine/TaskScheduler.swift`:

1. In `start()`, after `rebuildSchedule()`, schedule a one-shot launch sweep:

   ```swift
   DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
       Task { @MainActor in self?.fireLaunchTasks() }
   }
   ```

2. New private method `fireLaunchTasks()`:
   - Fetch enabled tasks with `runOnLaunch == true`.
   - For each task: call `fireTask(_:triggeredBy: .launch)`.
   - After firing, advance `nextRunAt` to the next scheduled occurrence (so
     `runMissedExecution` does not catch it up again).

   `fireTask` already guards against concurrent execution via `runningTaskIDs`,
   handles log writes, and updates `lastRunAt` / `executionCount`. The only
   addition is plumbing `triggeredBy: TriggerType` through `fireTask` so the
   launch case can pass `.launch` while the existing scheduler path keeps
   passing `.schedule`.

### Editor UI
`Sources/Views/Editor/TaskEditorView.swift`:

A new section at the top of the **Schedule** tab, above the existing Date/Time
section:

```
─── 启动 ───
[ ] 每次 App 启动时执行一次
    无论是否有定时计划，每次 App 启动都会运行
```

State variable `@State private var runOnLaunch = false` plus load/save plumbing
matching the existing `runMissedExecution` pattern.

### Log views
`Sources/Views/Main/TaskLogsView.swift` and `Sources/Views/Logs/LogDetailView.swift`
currently use a binary ternary `triggeredBy == .manual ? manual : schedule`
that would misclassify `.launch` as Scheduled. Replace with a switch over
`TriggerType` returning the matching localized label.

### Localization
`Sources/Localization/{en,zh-Hans}.lproj/Localizable.strings`:

- `log.detail.trigger.launch` = `Launch` / `启动`
- `schedule.launch_section` = `Launch` / `启动`
- `schedule.run_on_launch` = `Run once every time the app launches` / `每次 App 启动时执行一次`
- `schedule.run_on_launch.help` = `Runs whether or not a schedule is set` / `无论是否有定时计划，每次 App 启动都会运行`

### Export/import
`Sources/Engine/TaskExporter.swift` already follows a pattern of optional
fields with default fallbacks — add `runOnLaunch: Bool?` to the codable
struct, mirror in encode/decode (default `false` on missing).

## Out of scope

- Configurable launch delay (locked at 3s).
- Distinguishing "App became active after relaunch from background" vs "fresh
  launch" — only fires on `TaskScheduler.start()`, which runs once per
  process lifetime.
- Retry / failure-handling specific to launch runs (uses the same path as
  scheduled runs, including timeouts and error logs).
