import Foundation

/// Checks GitHub Releases API for app updates.
@MainActor
final class UpdateChecker: ObservableObject {
    @Published var latestVersion: String?
    @Published var updateAvailable = false
    @Published var releaseNotes: String?
    @Published var downloadURL: URL?
    @Published var isChecking = false

    static let shared = UpdateChecker()

    let repoOwner = "lifedever"
    let repoName = "TaskTick"

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private init() {}

    private struct GitHubRelease: Codable {
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: String
        let assets: [Asset]?

        struct Asset: Codable {
            let name: String
            let browser_download_url: String
        }
    }

    func checkForUpdates() async {
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

            if let dmgAsset = release.assets?.first(where: { $0.name.hasSuffix(".dmg") }) {
                downloadURL = URL(string: dmgAsset.browser_download_url)
            } else {
                downloadURL = URL(string: release.html_url)
            }

            // Skip if user has skipped this version
            let skippedVersion = UserDefaults.standard.string(forKey: "skippedVersion")
            if remoteVersion == skippedVersion {
                updateAvailable = false
            } else {
                updateAvailable = isNewer(remote: remoteVersion, current: currentVersion)
            }

            UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
        } catch {
            // Silently fail - update check is non-critical
        }

        isChecking = false
    }

    func skipVersion(_ version: String) {
        UserDefaults.standard.set(version, forKey: "skippedVersion")
        updateAvailable = false
    }

    /// Semantic version comparison
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

    /// Schedule periodic update checks
    func startPeriodicChecks() {
        let interval = UserDefaults.standard.integer(forKey: "updateCheckInterval")
        let hours = interval > 0 ? interval : 24

        Timer.scheduledTimer(withTimeInterval: TimeInterval(hours * 3600), repeats: true) { _ in
            Task { @MainActor in
                guard UserDefaults.standard.bool(forKey: "autoCheckUpdates") else { return }
                await UpdateChecker.shared.checkForUpdates()
            }
        }
    }
}
