import AppKit
import Foundation

/// Checks GitHub Releases API for app updates, downloads and installs.
@MainActor
final class UpdateChecker: ObservableObject {
    @Published var latestVersion: String?
    @Published var updateAvailable = false
    @Published var releaseNotes: String?
    @Published var downloadURL: URL?
    @Published var isChecking = false

    // Download state
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var downloadedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var downloadComplete = false
    @Published var downloadedFileURL: URL?
    private var periodicTimer: Timer?

    // UI state
    @Published var showUpdateDialog = false

    static let shared = UpdateChecker()

    let repoOwner = "lifedever"
    let repoName = "TaskTick"
    let giteeRepo = "lifedever/task-tick"

    private var downloadTask: URLSessionDownloadTask?
    private var downloadDelegate: DownloadDelegate?
    private var githubFallbackURL: URL?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private init() {}

    struct GitHubRelease: Codable {
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: String
        let assets: [Asset]?

        struct Asset: Codable {
            let name: String
            let browser_download_url: String
            let size: Int?
        }
    }

    private var isDev: Bool {
        Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
    }

    func checkForUpdates(userInitiated: Bool = false) async {
        if isDev { return }
        isChecking = true

        do {
            let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                isChecking = false
                return
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let remoteVersion = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))

            latestVersion = remoteVersion
            releaseNotes = release.body

            // Find the correct DMG for current architecture
            let arch = currentArch()
            let dmgName = "\(repoName)-\(remoteVersion)-\(arch).dmg"
            if let dmgAsset = release.assets?.first(where: { $0.name.contains(arch) && $0.name.hasSuffix(".dmg") }) {
                // GitHub as fallback, Gitee as primary
                githubFallbackURL = URL(string: dmgAsset.browser_download_url)
                downloadURL = URL(string: "https://gitee.com/\(giteeRepo)/releases/download/v\(remoteVersion)/\(dmgName)") ?? githubFallbackURL
                totalBytes = Int64(dmgAsset.size ?? 0)
            } else if let dmgAsset = release.assets?.first(where: { $0.name.hasSuffix(".dmg") }) {
                githubFallbackURL = URL(string: dmgAsset.browser_download_url)
                downloadURL = URL(string: "https://gitee.com/\(giteeRepo)/releases/download/v\(remoteVersion)/\(dmgAsset.name)") ?? githubFallbackURL
                totalBytes = Int64(dmgAsset.size ?? 0)
            } else {
                downloadURL = URL(string: release.html_url)
            }

            // Skip if user has skipped this version
            let skippedVersion = UserDefaults.standard.string(forKey: "skippedVersion")
            if !userInitiated && remoteVersion == skippedVersion {
                updateAvailable = false
            } else {
                updateAvailable = isNewer(remote: remoteVersion, current: currentVersion)
            }

            UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")

            if updateAvailable {
                showUpdateDialog = true
            } else if userInitiated {
                // Show "up to date" alert
                showUpToDateAlert()
            }
        } catch {
            // Silently fail
        }

        isChecking = false
    }

    func skipVersion(_ version: String) {
        UserDefaults.standard.set(version, forKey: "skippedVersion")
        updateAvailable = false
        showUpdateDialog = false
    }

    func downloadUpdate() {
        guard let url = downloadURL else { return }
        startDownload(from: url)
    }

    private func startDownload(from url: URL) {
        isDownloading = true
        downloadProgress = 0
        downloadedBytes = 0
        downloadComplete = false

        let delegate = DownloadDelegate { [weak self] progress, received, total in
            Task { @MainActor in
                self?.downloadProgress = progress
                self?.downloadedBytes = received
                self?.totalBytes = total
            }
        } onComplete: { [weak self] fileURL in
            Task { @MainActor in
                self?.downloadComplete = true
                self?.downloadedFileURL = fileURL
                self?.isDownloading = false
            }
        } onError: { [weak self] errorMessage in
            Task { @MainActor in
                guard let self = self else { return }
                // If Gitee failed and we have a GitHub fallback, try it
                if let fallback = self.githubFallbackURL, url != fallback {
                    self.githubFallbackURL = nil
                    self.startDownload(from: fallback)
                } else {
                    self.isDownloading = false
                    self.downloadComplete = false
                    self.downloadProgress = 0
                    self.showDownloadErrorAlert(errorMessage)
                }
            }
        }
        self.downloadDelegate = delegate

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        downloadTask = session.downloadTask(with: url)
        downloadTask?.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = 0
        downloadComplete = false
    }

    func installAndRestart() {
        guard let fileURL = downloadedFileURL else { return }

        let dmgPath = fileURL.path

        // Verify DMG can be mounted BEFORE quitting the app
        let verifyProcess = Process()
        verifyProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        verifyProcess.arguments = ["attach", dmgPath, "-nobrowse", "-noverify"]
        let pipe = Pipe()
        verifyProcess.standardOutput = pipe
        verifyProcess.standardError = FileHandle.nullDevice

        do {
            try verifyProcess.run()
            verifyProcess.waitUntilExit()
        } catch {
            showDMGErrorAlert()
            return
        }

        guard verifyProcess.terminationStatus == 0 else {
            showDMGErrorAlert()
            return
        }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let mountLine = output.components(separatedBy: "\n").first(where: { $0.contains("/Volumes/") }),
              let volumeRange = mountLine.range(of: "/Volumes/") else {
            showDMGErrorAlert()
            return
        }
        let mountPoint = String(mountLine[volumeRange.lowerBound...]).trimmingCharacters(in: .whitespaces)
        let sourceApp = "\(mountPoint)/TaskTick.app"

        guard FileManager.default.fileExists(atPath: sourceApp) else {
            // Detach and show error
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", mountPoint, "-quiet"]
            try? detach.run()
            detach.waitUntilExit()
            showDMGErrorAlert()
            return
        }

        // DMG is valid and mounted — now safe to quit and replace
        let destApp = Bundle.main.bundlePath
        let script = """
        #!/bin/bash
        MOUNT_POINT="\(mountPoint)"
        SOURCE_APP="\(sourceApp)"
        DEST_APP="\(destApp)"

        # Wait for the app to quit
        sleep 2

        # Replace and relaunch
        rm -rf "$DEST_APP"
        cp -R "$SOURCE_APP" "$DEST_APP"
        hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null
        open "$DEST_APP"
        rm -f "$0"
        """

        do {
            let scriptPath = NSTemporaryDirectory() + "tasktick_update.sh"
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptPath]
            try process.run()

            // DMG verified, script launched — safe to quit
            AppDelegate.shouldReallyQuit = true
            NSApp.terminate(nil)
        } catch {
            // Detach DMG on failure
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", mountPoint, "-quiet"]
            try? detach.run()
            detach.waitUntilExit()
            NSWorkspace.shared.open(fileURL)
        }
    }

    private func showDownloadErrorAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("update.download_error")
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showDMGErrorAlert() {
        let alert = NSAlert()
        alert.messageText = L10n.tr("update.dmg_error")
        alert.informativeText = L10n.tr("update.dmg_error.message")
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()

        // Reset download state so user can retry
        downloadComplete = false
        downloadedFileURL = nil
        isDownloading = false
        downloadProgress = 0
    }

    // MARK: - Private

    private func currentArch() -> String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    private func isNewer(remote: String, current: String) -> Bool {
        let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(remoteParts.count, currentParts.count) {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let c = i < currentParts.count ? currentParts[i] : 0
            if r > c { return true }
            if r < c { return false }
        }
        return false
    }

    private func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = L10n.tr("update.no_updates")
        alert.informativeText = L10n.tr("update.no_updates.message", currentVersion)
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func startPeriodicChecks() {
        periodicTimer?.invalidate()
        let interval = UserDefaults.standard.integer(forKey: "updateCheckInterval")
        let hours = interval > 0 ? interval : 24

        periodicTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(hours * 3600), repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard UserDefaults.standard.bool(forKey: "autoCheckUpdates") else { return }
                await self?.checkForUpdates()
            }
        }
    }
}

// MARK: - Download Delegate

final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let onProgress: @Sendable (Double, Int64, Int64) -> Void
    let onComplete: @Sendable (URL) -> Void
    let onError: @Sendable (String) -> Void

    init(
        onProgress: @escaping @Sendable (Double, Int64, Int64) -> Void,
        onComplete: @escaping @Sendable (URL) -> Void,
        onError: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.onProgress = onProgress
        self.onComplete = onComplete
        self.onError = onError
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("TaskTick-update.dmg")
        try? FileManager.default.removeItem(at: dest)

        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            // Move failed — try copy as fallback
            do {
                try FileManager.default.copyItem(at: location, to: dest)
            } catch {
                onComplete(location)
                return
            }
        }

        // Verify file size matches expected download size
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
           let fileSize = attrs[.size] as? Int64,
           let response = downloadTask.response as? HTTPURLResponse,
           let expectedSize = response.expectedContentLength as Int64?,
           expectedSize > 0,
           fileSize != expectedSize {
            // File size mismatch — download likely incomplete
            try? FileManager.default.removeItem(at: dest)
            onComplete(dest) // will fail at DMG verification stage
            return
        }

        onComplete(dest)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : 1
        let progress = Double(totalBytesWritten) / Double(total)
        onProgress(progress, totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error = error {
            onError(error.localizedDescription)
        }
    }
}
