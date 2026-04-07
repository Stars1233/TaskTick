import Foundation
import os

/// Manages automatic database backups to prevent data loss.
/// Backs up .store, .store-shm, and .store-wal files before ModelContainer opens.
enum DatabaseBackup {
    private static let logger = Logger(subsystem: "com.lifedever.TaskTick", category: "DatabaseBackup")
    private static let maxBackups = 5

    /// Backup the database files before opening ModelContainer.
    /// Returns true if backup was created successfully.
    @discardableResult
    static func backupBeforeOpen(storeURL: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storeURL.path) else { return false }

        // Skip backup if the store is empty (no data worth backing up)
        if isStoreEmpty(storeURL: storeURL) {
            logger.info("Store is empty, skipping backup")
            return false
        }

        let backupDir = backupDirectory(for: storeURL)
        do {
            try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create backup directory: \(error.localizedDescription)")
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

            logger.info("Database backed up to \(backupSubdir.path)")
            pruneOldBackups(backupDir: backupDir)
            return true
        } catch {
            logger.error("Failed to backup database: \(error.localizedDescription)")
            return false
        }
    }

    /// Try to restore from the most recent backup.
    /// Returns true if restoration was successful.
    static func restoreFromLatestBackup(storeURL: URL) -> Bool {
        let fm = FileManager.default
        let backupDir = backupDirectory(for: storeURL)

        guard let backups = try? fm.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: [.creationDateKey])
            .filter({ $0.hasDirectoryPath })
            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) else {
            logger.warning("No backups found")
            return false
        }

        for backup in backups {
            if restoreFrom(backup: backup, storeURL: storeURL) {
                logger.info("Restored database from backup: \(backup.lastPathComponent)")
                return true
            }
        }

        logger.error("All backup restoration attempts failed")
        return false
    }

    // MARK: - Private

    private static func backupDirectory(for storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent().appendingPathComponent("backups")
    }

    private static func isStoreEmpty(storeURL: URL) -> Bool {
        // A store file under 200KB with no WAL data is likely empty (just schema)
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: storeURL.path),
              let size = attrs[.size] as? Int else { return true }

        let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
        let walSize: Int
        if let walAttrs = try? fm.attributesOfItem(atPath: walURL.path),
           let ws = walAttrs[.size] as? Int {
            walSize = ws
        } else {
            walSize = 0
        }

        // If main file is small AND wal is empty, likely no real data
        return size < 250_000 && walSize == 0
    }

    private static func restoreFrom(backup: URL, storeURL: URL) -> Bool {
        let fm = FileManager.default
        let baseName = storeURL.lastPathComponent
        let backupStore = backup.appendingPathComponent(baseName)

        guard fm.fileExists(atPath: backupStore.path) else { return false }

        // Check that the backup itself isn't empty
        if isStoreEmpty(storeURL: backupStore) {
            logger.info("Skipping empty backup: \(backup.lastPathComponent)")
            return false
        }

        do {
            // Remove current corrupt files
            let extensions = ["", "-shm", "-wal"]
            for ext in extensions {
                let fileURL = storeURL.deletingLastPathComponent()
                    .appendingPathComponent(baseName + ext)
                if fm.fileExists(atPath: fileURL.path) {
                    try fm.removeItem(at: fileURL)
                }
            }

            // Copy backup files
            for ext in extensions {
                let sourceURL = backup.appendingPathComponent(baseName + ext)
                if fm.fileExists(atPath: sourceURL.path) {
                    let destURL = storeURL.deletingLastPathComponent()
                        .appendingPathComponent(baseName + ext)
                    try fm.copyItem(at: sourceURL, to: destURL)
                }
            }

            return true
        } catch {
            logger.error("Failed to restore from backup \(backup.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }

    private static func pruneOldBackups(backupDir: URL) {
        let fm = FileManager.default
        guard let backups = try? fm.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: nil)
            .filter({ $0.hasDirectoryPath })
            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) else { return }

        if backups.count > maxBackups {
            for old in backups.dropFirst(maxBackups) {
                try? fm.removeItem(at: old)
                logger.info("Pruned old backup: \(old.lastPathComponent)")
            }
        }
    }
}
