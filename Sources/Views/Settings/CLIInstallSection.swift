import AppKit
import SwiftUI
import TaskTickCore

/// Settings → Command Line section. Detects whether the `tasktick` symlink
/// already points at the current .app, and offers a one-shot dialog with
/// the sudo command pre-filled (1Password 7 pattern).
struct CLIInstallSection: View {

    @State private var installState: InstallState = .unknown

    enum InstallState: Equatable {
        case unknown
        case installed(path: String)
        case notInstalled
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("settings.cli.description"))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button(buttonLabel) {
                        switch installState {
                        case .installed(let path):
                            showUninstallDialog(symlinkPath: path)
                        default:
                            showEnableDialog()
                        }
                    }

                    statusLabel
                }

                Link(L10n.tr("settings.cli.raycast_link"),
                     destination: URL(string: "https://www.raycast.com/lifedever/tasktick")!)
                    .font(.callout)
            }
            .padding(.vertical, 4)
        } header: {
            Text(L10n.tr("settings.cli.section.title"))
        }
        .onAppear { refreshState() }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch installState {
        case .unknown:
            EmptyView()
        case .installed(let path):
            Label(L10n.tr("settings.cli.installed", path), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .notInstalled:
            Label(L10n.tr("settings.cli.not_installed"), systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }

    private func refreshState() {
        // Candidate symlink locations, Apple Silicon path first.
        let candidates = ["/opt/homebrew/bin/\(cliName)", "/usr/local/bin/\(cliName)"]
        // The CLI binary the user should symlink to. Resolve from the running
        // GUI's own executable path so this stays correct regardless of
        // whether the user installed to /Applications, ~/Applications, or a
        // custom location.
        let cliInBundle = currentAppCLIPath()
        for path in candidates {
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path),
               target == cliInBundle {
                installState = .installed(path: path)
                return
            }
        }
        installState = .notInstalled
    }

    /// Path to the `tasktick` binary co-located with the running GUI.
    /// Release CLI lives in Contents/cli/ (NOT Contents/MacOS/) — case-
    /// insensitive APFS would otherwise collide 'TaskTick' (GUI) with
    /// 'tasktick' (CLI) and silently overwrite one. Dev CLI stays in
    /// Contents/MacOS/tasktick-dev because the dash-suffixed name doesn't
    /// collide with 'TaskTick Dev'.
    private func currentAppCLIPath() -> String {
        let subdir = BundleContext.isDev ? "Contents/MacOS" : "Contents/cli"
        return Bundle.main.bundleURL
            .appendingPathComponent("\(subdir)/\(cliName)")
            .path
    }

    /// CLI binary / symlink name. Differs by bundle ID so dev and release
    /// can coexist on PATH (`tasktick` for release, `tasktick-dev` for dev).
    private var cliName: String {
        BundleContext.isDev ? "tasktick-dev" : "tasktick"
    }

    private var buttonLabel: String {
        if case .installed = installState {
            return L10n.tr("settings.cli.uninstall_button")
        }
        return L10n.tr("settings.cli.enable_button")
    }

    private func showEnableDialog() {
        // /usr/local/bin is the universal Unix convention and is always in
        // macOS's default PATH (/etc/paths). Homebrew users will still find
        // their existing /opt/homebrew/bin symlinks via refreshState's scan.
        let target = "/usr/local/bin/\(cliName)"
        let cliPath = currentAppCLIPath()
        let cmd = "sudo ln -sf \"\(cliPath)\" \(target)"

        let alert = NSAlert()
        alert.messageText = L10n.tr("settings.cli.install.alert.title")
        alert.informativeText = L10n.tr("settings.cli.install.alert.message", cmd)
        alert.addButton(withTitle: L10n.tr("settings.cli.install.alert.copy"))
        alert.addButton(withTitle: L10n.tr("settings.cli.install.alert.open_terminal"))
        alert.addButton(withTitle: L10n.tr("settings.cli.install.alert.cancel"))

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
        case .alertSecondButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
            // Open Terminal so the user can paste immediately.
            if let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                NSWorkspace.shared.open(terminalURL)
            }
        default:
            break
        }
        // Refresh in case the user already ran the command before clicking.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            refreshState()
        }
    }

    private func showUninstallDialog(symlinkPath: String) {
        let cmd = "sudo rm \(symlinkPath)"

        let alert = NSAlert()
        alert.messageText = L10n.tr("settings.cli.uninstall.alert.title")
        alert.informativeText = L10n.tr("settings.cli.uninstall.alert.message", cmd)
        alert.addButton(withTitle: L10n.tr("settings.cli.install.alert.copy"))
        alert.addButton(withTitle: L10n.tr("settings.cli.install.alert.open_terminal"))
        alert.addButton(withTitle: L10n.tr("settings.cli.install.alert.cancel"))

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
        case .alertSecondButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
            if let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                NSWorkspace.shared.open(terminalURL)
            }
        default:
            break
        }
        // Refresh — if the user ran the command, state should flip back to notInstalled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            refreshState()
        }
    }
}
