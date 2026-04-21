import SwiftUI
import SwiftData

@main
struct TaskTickApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var scheduler = TaskScheduler.shared
    @StateObject private var updateChecker = UpdateChecker.shared
    @StateObject private var templateStore = ScriptTemplateStore.shared
    @Environment(\.openWindow) private var openWindow
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @State private var showingCrontabImport = false
    @State private var showingRecoveryAlert = false

    /// Set to true when ModelContainer failed and app is running with in-memory fallback
    private(set) static var _needsRecovery = false

    init() {
        let container = Self._sharedModelContainer
        let scheduler = TaskScheduler.shared
        scheduler.configure(modelContext: container.mainContext)
        scheduler.start()

        let backup = DatabaseBackup.shared
        backup.configure(storeURL: Self._storeURL, modelContext: container.mainContext)
        backup.startScheduledBackups()
    }

    var sharedModelContainer: ModelContainer { Self._sharedModelContainer }

    static let _storeURL: URL = StoreMigration.resolveStoreURL()

    static let _sharedModelContainer: ModelContainer = {
        let schema = Schema([
            ScheduledTask.self,
            ExecutionLog.self,
        ])
        let storeURL = _storeURL

        // Flush any WAL left by previous versions into the main store and switch the
        // file to DELETE journal mode. Runs before ModelContainer opens so SQLite
        // will honor the mode change. Any crash/kill between here and the next launch
        // can no longer strand data in a -wal sidecar.
        StoreHardener.hardenStore(at: storeURL)

        let modelConfiguration = ModelConfiguration(
            schema: schema,
            url: storeURL,
            allowsSave: true
        )

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            // Do NOT overwrite the store from a backup here. An open failure can be
            // transient (file lock held by a zombie process, permission flap, etc)
            // and silently replacing the user's data with a days-old backup is the
            // exact failure mode this version is shipping to fix. Fall back to an
            // in-memory store, flag recovery mode, and let the user choose from
            // Settings → Backup whether to restore.
            NSLog("⚠️ ModelContainer failed: \(error). Falling back to in-memory; on-disk files left untouched at \(storeURL.path)")
            _needsRecovery = true
            let fallbackConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                return try ModelContainer(for: schema, configurations: [fallbackConfig])
            } catch {
                fatalError("Could not create even in-memory ModelContainer: \(error)")
            }
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

                    if Self._needsRecovery {
                        showingRecoveryAlert = true
                    }

                    Task {
                        if UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true {
                            await updateChecker.checkForUpdates()
                        }
                        updateChecker.startPeriodicChecks()
                    }
                }
                .alert(L10n.tr("recovery.title"), isPresented: $showingRecoveryAlert) {
                    Button(L10n.tr("recovery.open_settings")) {
                        openWindow(id: "settings")
                    }
                    Button(L10n.tr("recovery.open_folder")) {
                        NSWorkspace.shared.selectFile(Self._storeURL.path, inFileViewerRootedAtPath: Self._storeURL.deletingLastPathComponent().path)
                    }
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(L10n.tr("recovery.message"))
                }
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 960, height: 640)
        .commands {
            appCommands
        }

        // Menu bar
        MenuBarExtra(L10n.tr("app.name"), systemImage: menuBarIcon, isInserted: $showMenuBarIcon) {
            MenuBarView()
                .modelContainer(sharedModelContainer)
                .localized()
        }
        .menuBarExtraStyle(.window)

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

        // Template editor window
        Window(TemplateEditorState.shared.templateToEdit != nil ? L10n.tr("template.edit.title") : L10n.tr("template.add"), id: "template-editor") {
            TemplateEditorSheet()
                .localized()
        }
        .defaultSize(width: 500, height: 560)
        .windowResizability(.contentSize)

        // Template management window
        Window(L10n.tr("template.manage.title"), id: "templates") {
            TemplateManagementView()
                .localized()
        }
        .defaultSize(width: 860, height: 560)

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

            Divider()

            Button {
                if let url = URL(string: "https://www.lifedever.com/sponsor/") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label(L10n.tr("command.sponsor"), systemImage: "heart")
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

        CommandMenu(L10n.tr("template.menu")) {
            ForEach(templateStore.groupedTemplates, id: \.category) { group in
                if group.category.isEmpty {
                    ForEach(group.templates) { template in
                        Button(template.name) {
                            EditorState.shared.openNewFromTemplate(template)
                            openWindow(id: "editor")
                        }
                    }
                } else {
                    Menu(group.category) {
                        ForEach(group.templates) { template in
                            Button(template.name) {
                                EditorState.shared.openNewFromTemplate(template)
                                openWindow(id: "editor")
                            }
                        }
                    }
                }
            }

            Divider()
            Button(L10n.tr("template.manage")) {
                openWindow(id: "templates")
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])

            Button(L10n.tr("template.restore_defaults")) {
                templateStore.restoreDefaults()
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
        // Only mark the seed as done if we actually persisted it, otherwise a transient
        // save failure would prevent the welcome task from ever appearing.
        do {
            try context.save()
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            NSLog("⚠️ Seed default task save failed: \(error.localizedDescription)")
        }
    }
}
