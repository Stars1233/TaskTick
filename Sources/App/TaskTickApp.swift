import SwiftUI
import SwiftData

@main
struct TaskTickApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var scheduler = TaskScheduler.shared
    @StateObject private var updateChecker = UpdateChecker.shared
    @Environment(\.openWindow) private var openWindow

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            ScheduledTask.self,
            ExecutionLog.self,
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        // Main window
        Window(L10n.tr("app.name"), id: "main") {
            MainWindowView()
                .localized()
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    scheduler.configure(modelContext: sharedModelContainer.mainContext)
                    scheduler.start()

                    Task {
                        await updateChecker.checkForUpdates()
                        updateChecker.startPeriodicChecks()
                    }
                }
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 960, height: 640)
        .commands {
            appCommands
        }

        // Menu bar
        MenuBarExtra(L10n.tr("app.name"), systemImage: menuBarIcon) {
            MenuBarView()
                .localized()
        }
        .menuBarExtraStyle(.window)
        .modelContainer(sharedModelContainer)

        // Settings
        Settings {
            SettingsView()
                .localized()
        }
        .modelContainer(sharedModelContainer)

        // Logs window
        Window(L10n.tr("log.title"), id: "logs") {
            LogListView()
                .localized()
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 860, height: 540)
    }

    private var menuBarIcon: String {
        if !scheduler.runningTaskIDs.isEmpty {
            return "clock.arrow.2.circlepath"
        }
        return "clock.badge.checkmark"
    }

    @CommandsBuilder
    private var appCommands: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(L10n.tr("command.about")) {
                NSApp.orderFrontStandardAboutPanel(options: [
                    .applicationName: L10n.tr("app.name"),
                    .applicationVersion: updateChecker.currentVersion,
                ])
            }
        }

        CommandGroup(after: .appInfo) {
            Button(L10n.tr("command.check_updates")) {
                Task { await updateChecker.checkForUpdates() }
            }
        }

        CommandGroup(replacing: .newItem) {
            Button(L10n.tr("command.new_task")) {
                openWindow(id: "main")
            }
            .keyboardShortcut("n", modifiers: .command)

            Divider()

            Button(L10n.tr("command.import")) {
                // TODO: implement import
            }

            Button(L10n.tr("command.export")) {
                // TODO: implement export
            }
        }

        CommandMenu(L10n.tr("command.task_menu")) {
            Button(L10n.tr("command.run_selected")) {
                // TODO: implement run selected
            }
            .keyboardShortcut("r", modifiers: .command)

            Button(L10n.tr("command.stop_task")) {
                // TODO: implement stop
            }

            Divider()

            Button(L10n.tr("command.toggle_enabled")) {
                // TODO: implement toggle
            }

            Button(L10n.tr("command.delete_task")) {
                // TODO: implement delete
            }
        }

        CommandGroup(after: .toolbar) {
            Button(L10n.tr("command.show_logs")) {
                openWindow(id: "logs")
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Button(L10n.tr("command.refresh")) {
                scheduler.rebuildSchedule()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .help) {
            Link(L10n.tr("command.github_home"), destination: URL(string: "https://github.com/lifedever/TaskTick")!)
            Link(L10n.tr("command.report_issue"), destination: URL(string: "https://github.com/lifedever/TaskTick/issues")!)
        }
    }
}
