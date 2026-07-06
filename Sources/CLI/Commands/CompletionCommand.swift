import ArgumentParser
import Foundation
import TaskTickCore

/// Hidden subcommand invoked by the generated zsh/bash/fish completion
/// scripts to fetch dynamic task name candidates.
struct CompletionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__complete",
        abstract: "Internal — emit task candidates for shell completion.",
        shouldDisplay: false
    )

    @Argument(help: "Prefix the user has typed so far.")
    var prefix: String = ""

    @MainActor
    func run() async throws {
        let store = try ReadOnlyStore()
        let tasks = try store.fetchTasks().filter(\.isEnabled)
        let q = prefix.lowercased()
        let candidates = tasks.filter {
            q.isEmpty || $0.name.lowercased().contains(q)
        }
        for t in candidates {
            // zsh _describe format: <value>:<description>
            let desc = t.isManualOnly ? "manual" : t.repeatDisplayName
            print("\(t.name):\(desc)")
        }
    }
}
