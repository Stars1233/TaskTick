import SwiftUI
import ServiceManagement

struct SettingsView: View {
    // General
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("defaultShell") private var defaultShell = "/bin/zsh"
    @AppStorage("defaultTimeout") private var defaultTimeout = 300
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    // Notifications
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true

    // Logs
    @AppStorage("logRetentionDays") private var logRetentionDays = 30

    // Updates
    @AppStorage("autoCheckUpdates") private var autoCheckUpdates = true
    @AppStorage("updateCheckInterval") private var updateCheckInterval = 24

    @StateObject private var updateChecker = UpdateChecker.shared
    @ObservedObject private var languageManager = LanguageManager.shared

    @StateObject private var backupManager = DatabaseBackup.shared
    @State private var backupToRestore: DatabaseBackup.BackupEntry?
    @State private var showRestoreConfirm = false
    @State private var showRestoreResult = false
    @State private var restoreSuccess = false
    @State private var showBackupList = false
    @State private var backupToDelete: DatabaseBackup.BackupEntry?
    @State private var showDeleteConfirm = false
    @State private var showBackupSuccess = false

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label(L10n.tr("settings.general"), systemImage: "gear") }

            backupTab
                .tabItem { Label(L10n.tr("settings.backup"), systemImage: "externaldrive.badge.timemachine") }

            logsTab
                .tabItem { Label(L10n.tr("settings.logs"), systemImage: "doc.text") }

            updatesTab
                .tabItem { Label(L10n.tr("settings.updates"), systemImage: "arrow.triangle.2.circlepath") }

            aboutTab
                .tabItem { Label(L10n.tr("settings.about"), systemImage: "info.circle") }
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onExitCommand {
            NSApp.keyWindow?.close()
        }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section(L10n.tr("settings.general")) {
                Picker(L10n.tr("settings.appearance"), selection: $appearanceMode) {
                    Text(L10n.tr("settings.appearance.system")).tag("system")
                    Text(L10n.tr("settings.appearance.light")).tag("light")
                    Text(L10n.tr("settings.appearance.dark")).tag("dark")
                }
                .onChange(of: appearanceMode) { _, newValue in
                    applyAppearance(newValue)
                }

                Picker(L10n.tr("settings.general.language"), selection: $languageManager.current) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }

                Toggle(L10n.tr("settings.general.launch_at_login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        toggleLaunchAtLogin(newValue)
                    }

                Toggle(L10n.tr("settings.general.show_menubar_icon"), isOn: $showMenuBarIcon)
            }

            Section {
                Toggle(L10n.tr("settings.notifications.enable"), isOn: $notificationsEnabled)
            } header: {
                Text(L10n.tr("settings.notifications"))
            } footer: {
                Text(L10n.tr("settings.notifications.hint"))
            }

            Section(L10n.tr("settings.general.defaults")) {
                Picker(L10n.tr("settings.general.default_shell"), selection: $defaultShell) {
                    Text("/bin/zsh").tag("/bin/zsh")
                    Text("/bin/bash").tag("/bin/bash")
                    Text("/bin/sh").tag("/bin/sh")
                }

                LabeledContent(L10n.tr("settings.general.default_timeout")) {
                    HStack(spacing: 6) {
                        TextField("", value: $defaultTimeout, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                        Text(L10n.tr("settings.general.seconds"))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Backup

    private var backupTab: some View {
        Form {
            Section {
                Toggle(L10n.tr("settings.backup.enable"), isOn: $backupManager.isEnabled)
                    .onChange(of: backupManager.isEnabled) { _, _ in
                        backupManager.startScheduledBackups()
                    }

                if let lastDate = backupManager.lastBackupDate {
                    LabeledContent(L10n.tr("settings.backup.last_backup"), value: formatBackupDate(lastDate))
                }

                if backupManager.isEnabled, let nextDate = backupManager.nextBackupDate {
                    LabeledContent(L10n.tr("settings.backup.next_backup"), value: formatBackupDate(nextDate))
                }

                Picker(L10n.tr("settings.backup.frequency"), selection: $backupManager.intervalHours) {
                    Text(L10n.tr("settings.backup.frequency.1h")).tag(1)
                    Text(L10n.tr("settings.backup.frequency.6h")).tag(6)
                    Text(L10n.tr("settings.backup.frequency.12h")).tag(12)
                    Text(L10n.tr("settings.backup.frequency.24h")).tag(24)
                }
                .disabled(!backupManager.isEnabled)
                .onChange(of: backupManager.intervalHours) { _, _ in
                    backupManager.startScheduledBackups()
                }

                Picker(L10n.tr("settings.backup.max_count"), selection: $backupManager.maxBackups) {
                    ForEach(1...10, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .disabled(!backupManager.isEnabled)

                LabeledContent(L10n.tr("settings.backup.directory")) {
                    HStack(spacing: 6) {
                        Text(backupManager.customDirectory)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Button(L10n.tr("settings.backup.choose_directory")) {
                            chooseBackupDirectory()
                        }
                        .pointerCursor()
                    }
                }
                .disabled(!backupManager.isEnabled)

                HStack(spacing: 12) {
                    Button(L10n.tr("settings.backup.backup_now")) {
                        if backupManager.performBackup() {
                            showBackupSuccess = true
                        }
                    }
                    .disabled(!backupManager.isEnabled)
                    .pointerCursor()

                    Button(L10n.tr("settings.backup.open_directory")) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: backupManager.customDirectory))
                    }
                    .pointerCursor()

                    Button(L10n.tr("settings.backup.list")) {
                        showBackupList = true
                    }
                    .pointerCursor()
                }
            } header: {
                Text(L10n.tr("settings.backup.section"))
            }
        }
        .formStyle(.grouped)
        .alert(L10n.tr("settings.backup.success"), isPresented: $showBackupSuccess) {
            Button("OK") {}
        } message: {
            Text(L10n.tr("settings.backup.success.message"))
        }
        .sheet(isPresented: $showBackupList) {
            backupListSheet
        }
        .alert(L10n.tr("settings.backup.restore_confirm.title"), isPresented: $showRestoreConfirm) {
            Button(L10n.tr("settings.backup.restore_confirm.cancel"), role: .cancel) {}
            Button(L10n.tr("settings.backup.restore_confirm.confirm"), role: .destructive) {
                if let backup = backupToRestore {
                    // Flush pending writes before replacing database files. A failure here
                    // is non-blocking (restore overwrites the store anyway) but worth logging
                    // since any unsaved edits will be discarded by the restore.
                    do {
                        try TaskTickApp._sharedModelContainer.mainContext.save()
                    } catch {
                        NSLog("⚠️ Pre-restore save failed (unsaved edits will be lost): \(error.localizedDescription)")
                    }

                    let success = backupManager.restoreFrom(backupName: backup.name)
                    if success {
                        // Restart: wait for this process to exit before relaunching
                        let appPath = Bundle.main.bundlePath
                        let pid = ProcessInfo.processInfo.processIdentifier
                        let script = """
                        while kill -0 \(pid) 2>/dev/null; do sleep 0.5; done
                        open "\(appPath)"
                        """
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/bin/sh")
                        process.arguments = ["-c", script]
                        try? process.run()
                        AppDelegate.shouldReallyQuit = true
                        NSApp.terminate(nil)
                    } else {
                        restoreSuccess = false
                        showRestoreResult = true
                    }
                }
            }
        } message: {
            Text(L10n.tr("settings.backup.restore_confirm.message"))
        }
        .alert(L10n.tr("settings.backup.restore_failed"), isPresented: $showRestoreResult) {
            Button("OK") {}
        } message: {
            Text(L10n.tr("settings.backup.restore_failed.message"))
        }
    }

    private var backupListSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.tr("settings.backup.list"))
                    .font(.headline)
                Spacer()
                Button(L10n.tr("editor.cancel")) {
                    showBackupList = false
                }
                .pointerCursor()
            }
            .padding()

            Divider()

            let backups = backupManager.listBackups()
            if backups.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text(L10n.tr("settings.backup.no_backups"))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                List(backups) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(formatBackupDate(entry.date))
                                .font(.body)
                            Text(formatFileSize(entry.sizeBytes))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L10n.tr("settings.backup.restore")) {
                            backupToRestore = entry
                            showBackupList = false
                            showRestoreConfirm = true
                        }
                        .controlSize(.small)
                        .pointerCursor()
                        Button(role: .destructive) {
                            backupToDelete = entry
                            showDeleteConfirm = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .controlSize(.small)
                        .pointerCursor()
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(width: 400, height: 320)
        .alert(L10n.tr("settings.backup.delete_confirm.title"), isPresented: $showDeleteConfirm) {
            Button(L10n.tr("settings.backup.restore_confirm.cancel"), role: .cancel) {}
            Button(L10n.tr("delete.confirm"), role: .destructive) {
                if let backup = backupToDelete {
                    backupManager.deleteBackup(backup)
                }
            }
        } message: {
            Text(L10n.tr("settings.backup.delete_confirm.message"))
        }
    }

    private func chooseBackupDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            backupManager.customDirectory = url.path
        }
    }

    private func formatBackupDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    private func formatFileSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    // MARK: - Logs

    private var logsTab: some View {
        Form {
            Section(L10n.tr("settings.logs.section")) {
                LabeledContent(L10n.tr("settings.logs.retention")) {
                    HStack(spacing: 6) {
                        TextField("", value: $logRetentionDays, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                        Text(L10n.tr("settings.logs.retention.days"))
                            .foregroundStyle(.secondary)
                    }
                }

                Button(L10n.tr("settings.logs.cleanup"), role: .destructive) {
                    // Phase 6: implement log cleanup
                }
                .pointerCursor()
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Updates

    private var updatesTab: some View {
        Form {
            Section(L10n.tr("settings.updates.section")) {
                Toggle(L10n.tr("settings.updates.auto_check"), isOn: $autoCheckUpdates)

                Picker(L10n.tr("settings.updates.frequency"), selection: $updateCheckInterval) {
                    Text(L10n.tr("settings.updates.frequency.12h")).tag(12)
                    Text(L10n.tr("settings.updates.frequency.24h")).tag(24)
                    Text(L10n.tr("settings.updates.frequency.3d")).tag(72)
                    Text(L10n.tr("settings.updates.frequency.1w")).tag(168)
                }
                .disabled(!autoCheckUpdates)

                HStack(spacing: 12) {
                    Button(L10n.tr("settings.updates.check_now")) {
                        Task { await updateChecker.checkForUpdates(userInitiated: true) }
                    }
                    .disabled(updateChecker.isChecking)
                    .pointerCursor()

                    if updateChecker.isChecking {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if updateChecker.updateAvailable, let version = updateChecker.latestVersion {
                        Text(L10n.tr("settings.updates.new_version", version))
                            .font(.caption)
                            .foregroundStyle(.green)
                            .fontWeight(.medium)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - About

    private var aboutTab: some View {
        Form {
            Section(L10n.tr("settings.about.section")) {
                LabeledContent(L10n.tr("settings.about.version"), value: updateChecker.currentVersion)
                LabeledContent(L10n.tr("settings.about.build"), value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")

                Text("A native macOS app for managing scheduled tasks.\nNo crontab, no launchd — just TaskTick.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)

                Text("一款原生 macOS 定时任务管理应用。\n无需 crontab，无需 launchd，交给 TaskTick。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)

                Link(L10n.tr("settings.about.github"), destination: URL(string: "https://github.com/lifedever/TaskTick")!)
                    .pointerCursor()
                Link(L10n.tr("settings.about.issues"), destination: URL(string: "https://github.com/lifedever/TaskTick/issues")!)
                    .pointerCursor()
                Link(L10n.tr("settings.about.sponsor"), destination: URL(string: "https://www.lifedever.com/sponsor/")!)
                    .pointerCursor()

                Text(L10n.tr("settings.about.copyright"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }

    private func applyAppearance(_ mode: String) {
        switch mode {
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default:
            NSApp.appearance = nil // follow system
        }
    }

    private func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to toggle launch at login: \(error)")
        }
    }
}
