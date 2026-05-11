import AppKit
import ArgumentParser
import Foundation
import TaskTickCore

@main
struct TaskTickCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tasktick",
        abstract: "Control TaskTick scheduled tasks from the command line.",
        version: "0.1.0",
        subcommands: [
            ListCommand.self,
            StatusCommand.self,
            LogsCommand.self,
            CreateCommand.self,
            RunCommand.self,
            StopCommand.self,
            RestartCommand.self,
            RevealCommand.self,
            TailCommand.self,
            WaitCommand.self,
            EventsCommand.self,
            CompletionCommand.self
        ]
    )

    /// Override default ArgumentParser entry to hide the Dock icon before
    /// any AppKit code runs. The CLI binary lives inside `.app/Contents/MacOS/`,
    /// which makes macOS treat each invocation as a foreground GUI app
    /// — every `tasktick list` / `tasktick events` call would otherwise
    /// pop a clock icon in the Dock. `.prohibited` keeps it backgrounded.
    static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            var command = try parseAsRoot()
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            exit(withError: error)
        }
    }
}
