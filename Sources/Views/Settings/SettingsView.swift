import SwiftUI
import ServiceManagement

struct SettingsView: View {
    // General
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("defaultShell") private var defaultShell = "/bin/zsh"
    @AppStorage("defaultTimeout") private var defaultTimeout = 300
    @AppStorage("appearanceMode") private var appearanceMode = "system"

    // Notifications
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true

    // Logs
    @AppStorage("logRetentionDays") private var logRetentionDays = 30

    // Updates
    @AppStorage("autoCheckUpdates") private var autoCheckUpdates = true
    @AppStorage("updateCheckInterval") private var updateCheckInterval = 24

    @StateObject private var updateChecker = UpdateChecker.shared
    @ObservedObject private var languageManager = LanguageManager.shared

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label(L10n.tr("settings.general"), systemImage: "gear") }

            logsTab
                .tabItem { Label(L10n.tr("settings.logs"), systemImage: "doc.text") }

            updatesTab
                .tabItem { Label(L10n.tr("settings.updates"), systemImage: "arrow.triangle.2.circlepath") }

            aboutTab
                .tabItem { Label(L10n.tr("settings.about"), systemImage: "info.circle") }
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section(L10n.tr("settings.appearance")) {
                Picker(L10n.tr("settings.appearance"), selection: $appearanceMode) {
                    Text(L10n.tr("settings.appearance.system")).tag("system")
                    Text(L10n.tr("settings.appearance.light")).tag("light")
                    Text(L10n.tr("settings.appearance.dark")).tag("dark")
                }
                .onChange(of: appearanceMode) { _, newValue in
                    applyAppearance(newValue)
                }
            }

            Section(L10n.tr("settings.general.language.section")) {
                Picker(L10n.tr("settings.general.language"), selection: $languageManager.current) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }

                Text(L10n.tr("settings.general.language.restart_hint"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section(L10n.tr("settings.general.startup")) {
                Toggle(L10n.tr("settings.general.launch_at_login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        toggleLaunchAtLogin(newValue)
                    }
            }

            Section(L10n.tr("settings.notifications")) {
                Toggle(L10n.tr("settings.notifications.enable"), isOn: $notificationsEnabled)

                Text(L10n.tr("settings.notifications.hint"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
