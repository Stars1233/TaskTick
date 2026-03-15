import SwiftUI
import SwiftData

@main
struct TaskTickApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var scheduler = TaskScheduler.shared
    @StateObject private var updateChecker = UpdateChecker.shared
    @Environment(\.openWindow) private var openWindow
    @State private var showingCrontabImport = false

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
            MainWindowView(showingCrontabImport: $showingCrontabImport)
                .localized()
                .sheet(isPresented: $updateChecker.showUpdateDialog) {
                    UpdateDialogView(updater: updateChecker)
                }
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    seedDefaultTask(context: sharedModelContainer.mainContext)
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

        // Editor window
        Window(EditorState.shared.taskToEdit != nil ? L10n.tr("editor.title.edit") : L10n.tr("editor.title.new"), id: "editor") {
            TaskEditorView()
                .localized()
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 500, height: 560)
        .windowResizability(.contentSize)

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
                Task { await updateChecker.checkForUpdates(userInitiated: true) }
            }
        }

        CommandGroup(replacing: .newItem) {
            Button(L10n.tr("command.new_task")) {
                EditorState.shared.openNew()
                openWindow(id: "editor")
            }
            .keyboardShortcut("n", modifiers: .command)

            Divider()

            Button(L10n.tr("command.import")) {
                let count = TaskExporter.importTasks(into: sharedModelContainer.mainContext)
                if count > 0 {
                    scheduler.rebuildSchedule()
                }
            }

            Button(L10n.tr("command.export")) {
                TaskExporter.exportTasks(from: sharedModelContainer.mainContext)
            }

            Divider()

            Button(L10n.tr("command.import_crontab")) {
                showingCrontabImport = true
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

    private func seedDefaultTask(context: ModelContext) {
        let key = "hasSeededDefaultTask"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        let descriptor = FetchDescriptor<ScheduledTask>()
        let count = (try? context.fetchCount(descriptor)) ?? 0
        guard count == 0 else {
            UserDefaults.standard.set(true, forKey: key)
            return
        }

        let task = ScheduledTask(
            name: "Hello TaskTick",
            scriptBody: "echo \"Hello from TaskTick! 🎉\"\necho \"Current time: $(date)\"\necho \"Host: $(hostname)\"",
            shell: "/bin/zsh",
            scheduledDate: Date(),
            repeatType: .everyMinute,
            endRepeatType: .never,
            isEnabled: true,
            notifyOnSuccess: true,
            notifyOnFailure: true
        )
        context.insert(task)
        try? context.save()
        UserDefaults.standard.set(true, forKey: key)
    }
}
