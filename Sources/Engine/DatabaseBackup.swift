import Foundation
import SwiftData
import os

/// Manages automatic database backups.
/// Supports scheduled periodic backups with configurable directory and retention count.
@MainActor
final class DatabaseBackup: ObservableObject {
    static let shared = DatabaseBackup()

    private static let logger = Logger(subsystem: "com.lifedever.TaskTick", category: "DatabaseBackup")
    private var timer: Timer?
    private var storeURL: URL?
    private var modelContext: ModelContext?

    // MARK: - Settings (persisted via UserDefaults)

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "backupEnabled") }
    }
    /// Backup interval in hours
    @Published var intervalHours: Int {
        didSet { UserDefaults.standard.set(intervalHours, forKey: "backupIntervalHours") }
    }
    @Published var maxBackups: Int {
        didSet { UserDefaults.standard.set(maxBackups, forKey: "backupMaxCount") }
    }
    @Published var customDirectory: String {
        didSet { UserDefaults.standard.set(customDirectory, forKey: "backupDirectory") }
    }
    @Published var lastBackupDate: Date?
    @Published var nextBackupDate: Date?

    private init() {
        self.isEnabled = UserDefaults.standard.object(forKey: "backupEnabled") as? Bool ?? true
        self.intervalHours = UserDefaults.standard.object(forKey: "backupIntervalHours") as? Int ?? 24
        self.maxBackups = UserDefaults.standard.object(forKey: "backupMaxCount") as? Int ?? 5
        let bundleId = Bundle.main.bundleIdentifier ?? "com.lifedever.TaskTick"
        let subDir = bundleId.hasSuffix(".dev") ? "backups-dev" : "backups"
        let defaultDir = NSHomeDirectory() + "/.tasktick/" + subDir
        self.customDirectory = UserDefaults.standard.string(forKey: "backupDirectory") ?? defaultDir
    }

    // MARK: - Lifecycle

    func configure(storeURL: URL, modelContext: ModelContext? = nil) {
        self.storeURL = storeURL
        self.modelContext = modelContext
    }

    func startScheduledBackups() {
        timer?.invalidate()
        timer = nil
        guard isEnabled else {
            nextBackupDate = nil
            return
        }

        let interval = TimeInterval(intervalHours * 3600)

        // Check when the last backup was made to avoid duplicate backups on restart
        let backups = listBackups()
        let lastBackup = backups.first
        lastBackupDate = lastBackup?.date

        let firstDelay: TimeInterval
        if let lastDate = lastBackup?.date {
            let elapsed = Date().timeIntervalSince(lastDate)
            if elapsed >= interval {
                // Overdue: backup now
                performBackup()
                firstDelay = interval
            } else {
                // Wait remaining time
                firstDelay = interval - elapsed
            }
        } else {
            // No backups yet: backup now
            performBackup()
            firstDelay = interval
        }

        nextBackupDate = Date().addingTimeInterval(firstDelay)
        timer = Timer.scheduledTimer(withTimeInterval: firstDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.performBackup()
                self?.startPeriodicTimer(interval: interval)
            }
        }
    }

    private func startPeriodicTimer(interval: TimeInterval) {
        nextBackupDate = Date().addingTimeInterval(interval)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.performBackup()
                self?.nextBackupDate = Date().addingTimeInterval(interval)
            }
        }
    }

    func stopScheduledBackups() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Backup

    @discardableResult
    func performBackup() -> Bool {
        guard let storeURL else {
            Self.logger.warning("No store URL configured, skipping backup")
            return false
        }

        // Flush pending writes to disk before copying files. Abort on failure —
        // otherwise we'd stamp lastBackupDate with a stale snapshot.
        if let modelContext {
            do {
                try modelContext.save()
            } catch {
                Self.logger.error("Pre-backup save failed, skipping backup: \(error.localizedDescription)")
                return false
            }
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: storeURL.path) else { return false }

        let backupDir = URL(fileURLWithPath: customDirectory)
        do {
            try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        } catch {
            Self.logger.error("Failed to create backup directory: \(error.localizedDescription)")
            return false
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupSubdir = backupDir.appendingPathComponent(timestamp)

        do {
            try fm.createDirectory(at: backupSubdir, withIntermediateDirectories: true)

            let baseName = storeURL.lastPathComponent
            let extensions = ["", "-shm", "-wal"]
            for ext in extensions {
                let sourceURL = storeURL.deletingLastPathComponent()
                    .appendingPathComponent(baseName + ext)
                if fm.fileExists(atPath: sourceURL.path) {
                    let destURL = backupSubdir.appendingPathComponent(baseName + ext)
                    try fm.copyItem(at: sourceURL, to: destURL)
                }
            }

            Self.logger.info("Database backed up to \(backupSubdir.path)")
            pruneOldBackups(backupDir: backupDir)
            lastBackupDate = Date()
            return true
        } catch {
            Self.logger.error("Failed to backup database: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Restore

    func restoreFromLatestBackup() -> Bool {
        guard let storeURL else { return false }
        let backups = listBackups()
        for backup in backups {
            if restoreFrom(backup: backup.url, storeURL: storeURL) {
                Self.logger.info("Restored database from backup: \(backup.name)")
                return true
            }
        }
        Self.logger.error("All backup restoration attempts failed")
        return false
    }

    func restoreFrom(backupName: String) -> Bool {
        guard let storeURL else { return false }
        let backupDir = URL(fileURLWithPath: customDirectory)
        let backupURL = backupDir.appendingPathComponent(backupName)
        return restoreFrom(backup: backupURL, storeURL: storeURL)
    }

    // MARK: - List Backups

    struct BackupEntry: Identifiable {
        let id: String
        let name: String
        let date: Date
        let sizeBytes: Int
        let url: URL
    }

    func listBackups() -> [BackupEntry] {
        let fm = FileManager.default
        let backupDir = URL(fileURLWithPath: customDirectory)

        guard let contents = try? fm.contentsOfDirectory(
            at: backupDir,
            includingPropertiesForKeys: [.creationDateKey, .totalFileAllocatedSizeKey]
        ) else { return [] }

        let formatter = ISO8601DateFormatter()

        return contents
            .filter { $0.hasDirectoryPath }
            .compactMap { url -> BackupEntry? in
                let name = url.lastPathComponent
                // Parse timestamp from directory name (format: 2026-04-08T01-39-56Z)
                let dateStr = name.replacingOccurrences(of: "-", with: ":")
                    .replacingFirstDashGroup()
                let date = formatter.date(from: dateStr) ?? (try? fm.attributesOfItem(atPath: url.path))?[.creationDate] as? Date ?? Date.distantPast

                // Calculate total size of backup files
                var totalSize = 0
                if let files = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    for file in files {
                        if let attrs = try? fm.attributesOfItem(atPath: file.path),
                           let size = attrs[.size] as? Int {
                            totalSize += size
                        }
                    }
                }

                return BackupEntry(id: name, name: name, date: date, sizeBytes: totalSize, url: url)
            }
            .sorted { $0.name > $1.name }
    }

    func deleteBackup(_ entry: BackupEntry) {
        try? FileManager.default.removeItem(at: entry.url)
        objectWillChange.send()
    }

    // MARK: - Private

    @discardableResult
    private func restoreFrom(backup: URL, storeURL: URL) -> Bool {
        let fm = FileManager.default
        let baseName = storeURL.lastPathComponent
        let backupStore = backup.appendingPathComponent(baseName)

        guard fm.fileExists(atPath: backupStore.path) else { return false }

        do {
            let extensions = ["", "-shm", "-wal"]
            for ext in extensions {
                let fileURL = storeURL.deletingLastPathComponent()
                    .appendingPathComponent(baseName + ext)
                if fm.fileExists(atPath: fileURL.path) {
                    try fm.removeItem(at: fileURL)
                }
            }

            for ext in extensions {
                let sourceURL = backup.appendingPathComponent(baseName + ext)
                if fm.fileExists(atPath: sourceURL.path) {
                    let destURL = storeURL.deletingLastPathComponent()
                        .appendingPathComponent(baseName + ext)
                    try fm.copyItem(at: sourceURL, to: destURL)
                }
            }

            // Backups can contain a large -wal. Merge it into the main store
            // immediately so the data survives even if the next launch somehow
            // can't replay the WAL (stale -shm salt, permission change, etc).
            StoreHardener.checkpoint(at: storeURL)

            return true
        } catch {
            Self.logger.error("Failed to restore from backup \(backup.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }

    private func pruneOldBackups(backupDir: URL) {
        let fm = FileManager.default
        guard let backups = try? fm.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: nil)
            .filter({ $0.hasDirectoryPath })
            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) else { return }

        if backups.count > maxBackups {
            for old in backups.dropFirst(maxBackups) {
                try? fm.removeItem(at: old)
                Self.logger.info("Pruned old backup: \(old.lastPathComponent)")
            }
        }
    }
}

// Helper to parse backup directory name back to ISO8601
private extension String {
    /// Converts "2026-04-08T01-39-56Z" back to "2026-04-08T01:39:56Z"
    func replacingFirstDashGroup() -> String {
        // The date part uses dashes naturally; only the time part needs colon restoration
        // Format: YYYY-MM-DDTHH-MM-SSZ → only replace dashes after T
        guard let tIndex = self.firstIndex(of: "T") else { return self }
        let datePart = self[self.startIndex...tIndex]
        let timePart = self[self.index(after: tIndex)...]
        return datePart + timePart.replacingOccurrences(of: "-", with: ":")
    }
}
