# Script Notify Directive Design

## Goal

Let a running script emit **TaskTick-branded native notifications at any point
during its execution**, as many as it wants, driven by the script's own logic.

Today a script can only get notifications two ways, neither of which fits a
"notify mid-run, conditionally" need:

1. **TaskTick's own completion notification** (`ScriptExecutor.swift:247-276`):
   fires exactly once, *after* the script finishes, body = first meaningful
   stdout line. Cannot express "an update was detected" because that decision
   happens mid-run.
2. **`osascript display notification` from inside the script**: works and can
   fire mid-run, but the banner is attributed to **Script Editor** (not
   TaskTick), and if the task's built-in success/failure notification is also
   on, the user gets duplicate banners from two different apps.

This feature adds a first-class convention: the script prints a **sentinel
line** to stdout; TaskTick detects it on the live output stream and fires a
native notification through its own `NotificationManager`. No `osascript`, no
CLI dependency, language-agnostic (any script that can `echo` a line).

## Decisions

- **Mechanism**: stdout sentinel line, detected on the existing real-time
  output stream. No new IPC, no `tasktick` binary dependency (avoids the CLI
  PATH/bundle pitfalls that bit `L10n` before). Works identically for manual
  and scheduled runs.
- **Grammar** (the spec users will write in scripts):

  ```
  @tasktick:notify {"title":"检测到更新","body":"正在下载 v5.5.2"}
  ```

  - Prefix `@tasktick:notify` at line start (leading whitespace allowed,
    case-sensitive), followed by a single JSON object.
  - `title`: **required, non-empty string**.
  - `body`: optional string.
  - Unknown JSON keys are ignored (forward-compat room for future fields like
    `sound`).
- **Coexistence with the built-in completion notification**: **fully
  independent** (no auto-suppression). If a user wants to avoid a duplicate,
  they turn off the task's "success notification" in task settings. Predictable,
  no magic.
- **Detection only on stdout**, never stderr (stderr stays reserved for errors).
- **Directive lines are stripped from every sink** (stored stdout, tee file, live
  view), so they never show up as raw output. Two consequences to keep in mind:
  (a) a user `tail -f`-ing the `~/Library/Logs` tee file won't see their own
  directive lines — surface this in the docs; (b) if a script's *only* stdout is
  directive lines, the built-in completion notification in **"notify only when
  output present"** mode (`ScriptExecutor.swift:261`) stays silent, because the
  stripped stdout is empty. That's the desired behavior (the directive already
  sent its own banner), just not obvious.
- **Respect the global notification toggle**: honors the `notificationsEnabled`
  UserDefaults key, same as `ActionToast`. Global-off silences directives too.
- **Per-run cap**: at most **20** directive notifications per execution; further
  directives are dropped silently (runaway-script backstop for Notification
  Center).
- **Fault tolerance is a hard requirement** — see its own section below.

## Architecture

Reuse the existing live-stream pipeline. Today the stdout `readabilityHandler`
(`ScriptExecutor.swift:583-592`) does:

```swift
outputBuffer.appendStdout(data)   // stored stdout (DB log)
logFileWriter?.append(data)       // ~/Library/Logs tee file
batcher.appendStdout(data)        // IOBatcher -> LiveOutputManager (live view)
```

### New: `NotificationDirectiveScanner` (in `TaskTickCore`)

A stateful, line-buffering parser, instantiated once per execution (like
`outputBuffer` / `batcher`). Lives in `TaskTickCore` so its parsing logic is
unit-testable with no running process.

**Thread-safety is required, not optional.** The scanner is fed from two
different queues, so it must guard its internal line buffer exactly the way the
other per-run sinks do — `@unchecked Sendable` + an `NSLock` around every
mutation. This mirrors the established pattern in this file: `PipeOutputBuffer`
(`ScriptExecutor.swift:402`) and `IOBatcher` (`IOBatcher.swift:18`), whose own
note reads *"the readabilityHandler runs on an arbitrary GCD thread, so all
internal mutation goes through an NSLock."* The two callers are:

1. the stdout `readabilityHandler` (`ScriptExecutor.swift:583`) — an arbitrary
   GCD thread, and
2. the post-exit drain + `flush()` (`ScriptExecutor.swift:665-684`) —
   `DispatchQueue.global(qos: .userInitiated)`.

A scanner holding its buffer in an unlocked field would be a data race, so it is
explicitly **not** a "pure" value type — it is a locked, mutable object.

**Encoding contract.** `feed` matches the sentinel on text decoded with the same
`decodeProcessOutput` helper the downstream sinks use (`ScriptExecutor.swift:41`),
so a directive line carrying leading ANSI (colored logs, `set -x`) is still
recognized — matching on raw bytes would miss it. The returned `passthrough`
`Data` is the original chunk with only the recognized directive lines removed;
ANSI stripping / `\r` simulation stays downstream in `decodeProcessOutput` +
`cleanTerminalOutput`, unchanged.

```swift
public struct NotificationDirective: Equatable, Sendable {
    public let title: String
    public let body: String?
}

/// `@unchecked Sendable`: the internal line buffer is mutated from both the
/// readabilityHandler thread and the post-exit drain queue, guarded by NSLock.
public final class NotificationDirectiveScanner: @unchecked Sendable {
    /// Feed a raw stdout chunk. Returns the bytes that should pass through to
    /// the log / live view (directive lines removed), plus any complete
    /// directives recognized in this chunk.
    public func feed(_ data: Data) -> (passthrough: Data, directives: [NotificationDirective])

    /// Call once after the process exits AND after the final drain chunk has
    /// been `feed()`-ed: treats any buffered partial line as a final line
    /// (handles a last directive printed without a trailing newline).
    public func flush() -> (passthrough: Data, directives: [NotificationDirective])
}
```

### Wiring in `ScriptExecutor.runProcess`

The stdout handler runs the scanner **first**, then feeds the *passthrough*
(directive-stripped) bytes to the three existing sinks, so directive lines never
appear in the stored stdout, the tee file, or the live view:

```swift
stdoutHandle.readabilityHandler = { handle in
    let data = handle.availableData
    guard !data.isEmpty else { stdoutHandle.readabilityHandler = nil; return }
    let (passthrough, directives) = scanner.feed(data)
    for d in directives { fireDirectiveNotification(d) }
    outputBuffer.appendStdout(passthrough)
    logFileWriter?.append(passthrough)
    batcher.appendStdout(passthrough)
}
```

**The post-exit drain must go through the scanner too.** After
`process.waitUntilExit()`, the code reads `readDataToEndOfFile()`
(`ScriptExecutor.swift:668`) — and that tail is real stdout, often the bulk of a
script that buffers until exit. So the drained bytes are **`feed()`-ed first**,
and only then is `flush()` called for any directive left without a trailing
newline. Routing drain bytes straight to the sinks (skipping `feed`) would both
miss a directive in the tail **and** leak the directive line verbatim into the
log / tee file / live view:

```swift
// after waitUntilExit(), in place of the raw drain append:
let remaining = stdoutHandle.readDataToEndOfFile()
let (drainPass, drainDirs) = scanner.feed(remaining)   // feed BEFORE flush
let (flushPass, flushDirs) = scanner.flush()
for d in drainDirs + flushDirs { fireDirectiveNotification(d) }
let tail = drainPass + flushPass
if !tail.isEmpty {
    outputBuffer.appendStdout(tail)
    logFileWriter?.append(tail)
    batcher.appendStdout(tail)
}
```

`fireDirectiveNotification` checks the global `notificationsEnabled` toggle
(read via thread-safe `UserDefaults.standard`) and the per-run cap, then calls
the existing `NotificationManager.shared.sendNotification(title:body:)` — whose
`body` parameter is **non-optional `String`**, so pass `d.body ?? ""`. No changes
needed to `NotificationManager`.

**Ordering & cap counter.** Notifications must fire in the order the script
printed them (`下载 v5.5.1` before `下载 v5.5.2`), and the per-run cap counter is
shared mutable state. Dispatch every `fireDirectiveNotification` via
`DispatchQueue.main.async` — **not** `Task { @MainActor in … }`, whose scheduling
does not guarantee FIFO and can reorder a rapid burst. The main queue serializes
both the firing order and the cap counter, so the counter needs no separate lock.
`NotificationManager` is `@unchecked Sendable` and `sendNotification` is not
`@MainActor`, so this hop is purely for ordering/serialization, not a requirement
of the call itself.

## Stream-safety: do not break live output

The scanner must **not** stall normal live output (e.g. a `curl` progress bar
emits a long run of `\r`-terminated text with no `\n` for many seconds). Rule:

- Bytes pass through **immediately** unless the current incomplete trailing line
  *starts with the sentinel prefix* (or a prefix-of-the-prefix while still
  accumulating).
- Only a trailing partial line that could still become a directive is withheld,
  and only until its terminating `\n` arrives. Everything else streams through
  untouched, preserving live progress bars and partial lines.
- Complete non-directive lines always pass through verbatim.

## Fault tolerance (hard requirement)

A malformed directive must **never** crash, **never** drop the user's real
output, and **never** block the stream. Every failure mode degrades to "treat
it as ordinary output":

| Case | Behavior |
|------|----------|
| Prefix matches, JSON is invalid / not parseable | No notification. The **entire original line is passed through verbatim** to log + live view, so the user sees their typo and can debug. |
| Prefix matches, valid JSON but `title` missing/empty | Same as above: no notification, line passed through verbatim. |
| Prefix matches, valid JSON, `title` present but `body` wrong type (e.g. number) | Notification fires with `title`; `body` ignored (treated as absent). Be liberal in what we accept. |
| Valid JSON with extra unknown keys | Accepted; extra keys ignored. |
| Directive line split across two pipe chunks | Buffered until the `\n`, then parsed once whole. Never partially matched. |
| Directive printed without trailing `\n` (last line) | Recovered by `flush()` at process end. |
| More than 20 directives in one run | First 20 fire; the rest are dropped silently (their lines are still stripped from output for consistency). |
| Garbage bytes / invalid UTF-8 around the prefix | Decoding already tolerant (`decodeProcessOutput` upstream); scanner matches on decoded text and falls back to passthrough on any parse failure. |

Implementation note: the scanner wraps JSON parsing in a non-throwing path
(`try?`); any error → passthrough. No `fatalError`, no force-unwrap.

## Documentation

- Add a short "Script notifications" section to the in-app help / docs describing
  the grammar with a copy-pasteable example. Note that directive lines are
  consumed by TaskTick and do **not** appear in the run's output, logs, or tee
  file — so users aren't surprised when `tail -f` doesn't show them.
- (Optional, later) a snippet button in the script editor that inserts the
  directive template. **Out of scope for this spec.**

## Testing

`NotificationDirectiveScanner` is pure → straightforward unit tests in the
package test target:

- Single complete directive (title + body) → 1 directive, line stripped.
- Title-only directive → `body == nil`.
- Directive split across two `feed()` calls (chunk boundary) → 1 directive.
- Directive with no trailing newline recovered by `flush()`.
- Invalid JSON after prefix → 0 directives, original line in passthrough.
- Valid JSON, missing `title` → 0 directives, line in passthrough.
- Non-directive line beginning with `@` but not the prefix → passthrough, no buffering.
- `\r`-heavy progress text with no `\n` → streamed through immediately (not withheld).
- Interleaved normal lines + directives → normal lines preserved in order.
- 25 directives → exactly 20 fire (cap), all 25 lines stripped.
- Leading-whitespace-indented directive → recognized.
- Directive carrying a leading ANSI color sequence → recognized (scanner matches
  on decoded text, not raw bytes).
- Directive present only in the post-exit drain tail → recognized via
  feed-then-flush (drain bytes pass through `feed()` before `flush()`).

## Out of scope

- Progress/status protocol (percentages, live status text) — this spec is
  notifications only.
- `tasktick notify` CLI subcommand.
- Auto-suppressing the built-in completion notification when directives fire.
- Custom sound / actions / images in the notification (JSON is extensible, but
  only `title`/`body` are honored now).
- stderr directive detection.
- Script-editor insert-template button.
