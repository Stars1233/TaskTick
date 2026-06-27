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

### New: `NotificationDirectiveScanner` (pure, in `TaskTickCore`)

A small, stateful-but-pure parser, instantiated once per execution (like
`outputBuffer` / `batcher`). Lives in `TaskTickCore` so it is unit-testable with
no running process.

```swift
public struct NotificationDirective: Equatable, Sendable {
    public let title: String
    public let body: String?
}

public final class NotificationDirectiveScanner {
    /// Feed a raw stdout chunk. Returns the bytes that should pass through to
    /// the log / live view (directive lines removed), plus any complete
    /// directives recognized in this chunk.
    public func feed(_ data: Data) -> (passthrough: Data, directives: [NotificationDirective])

    /// Call once after the process exits: treats any buffered partial line as a
    /// final line (handles a last directive printed without a trailing newline).
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
    for d in directives { fireDirectiveNotification(d) }   // hop to @MainActor
    outputBuffer.appendStdout(passthrough)
    logFileWriter?.append(passthrough)
    batcher.appendStdout(passthrough)
}
```

After `process.waitUntilExit()` and the post-exit drain, call
`scanner.flush()` and route its passthrough/directives the same way.

`fireDirectiveNotification` hops to `@MainActor`, checks the global
`notificationsEnabled` toggle and the per-run cap, then calls the existing
`NotificationManager.shared.sendNotification(title:body:)`. No changes needed to
`NotificationManager`.

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
  the grammar with a copy-pasteable example.
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

## Out of scope

- Progress/status protocol (percentages, live status text) — this spec is
  notifications only.
- `tasktick notify` CLI subcommand.
- Auto-suppressing the built-in completion notification when directives fire.
- Custom sound / actions / images in the notification (JSON is extensible, but
  only `title`/`body` are honored now).
- stderr directive detection.
- Script-editor insert-template button.
