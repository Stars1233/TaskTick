import Foundation
import TaskTickCore

/// Whether a finished run raises a system notification and whether it pushes.
///
/// The two are configured on separate editor tabs and decided independently
/// (issue #55): before the split, the success/failure switches only gated the
/// macOS banner while push went out on every run, yet "only when output" gated
/// both — three rules sharing one tab, each with a different reach. Captured
/// from the task before the script runs, like every other property the
/// executor reads, so a task deleted mid-run still alerts the way it was set up.
struct CompletionAlertRules: Equatable, Sendable {

    struct Rule: Equatable, Sendable {
        var onSuccess: Bool
        var onFailure: Bool
        /// Success only: a run that printed nothing stays silent. Failures
        /// always alert — an empty stdout is often *why* it failed.
        var onlyWhenOutput: Bool

        func fires(succeeded: Bool, hasOutput: Bool) -> Bool {
            succeeded ? onSuccess && (hasOutput || !onlyWhenOutput) : onFailure
        }
    }

    var notification: Rule
    /// nil when the task doesn't push at all.
    var push: Rule?

    init(notification: Rule, push: Rule?) {
        self.notification = notification
        self.push = push
    }

    init(task: ScheduledTask) {
        notification = Rule(
            onSuccess: task.notifyOnSuccess,
            onFailure: task.notifyOnFailure,
            onlyWhenOutput: task.notifyOnlyWhenOutput
        )
        push = task.pushEnabled
            ? Rule(
                onSuccess: task.pushOnSuccess,
                onFailure: task.pushOnFailure,
                onlyWhenOutput: task.pushOnlyWhenOutput
            )
            : nil
    }

    /// Whitespace-only stdout counts as no output — a script ending in a stray
    /// newline shouldn't count as having said something.
    static func hasOutput(stdout: String) -> Bool {
        !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
