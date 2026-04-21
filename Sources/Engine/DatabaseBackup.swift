import Foundation
import SwiftData
import os

/// Manages automatic data backups.
///
/// Backups are written as a single self-contained JSON file per snapshot. This is
/// deliberately decoupled from SwiftData's on-disk SQLite layout — earlier versions
/// `cp`'d the raw `.store/.shm/.wal` files, which inherits every failure mode of the
/// live database (WAL loss, fd/inode divergence on macOS 15, schema migration corruption).
/// When the live store ever appeared empty, the very next scheduled backup would
/// faithfully capture the empty state and overwrite previous good backups.
///
/// Going through `context.fetch` reads tasks via SwiftData's open file descriptor —
/// which is the in-memory snapshot the user actually sees — so even if the on-disk
/// `.store` file has been replaced underneath us, a JSON backup still captures the
/// real data. Empty-data protection then refuses to overwrite a non-empty backup
/// with a zero-task snapshot.
@MainActor
final class DatabaseBackup: ObservableObject {
    static let shared = DatabaseBackup()

    private static let logger = Logger(subsystem: "com.lifedever.TaskTick", category: "DatabaseBackup")
    private static let fileExtension = "tasktickbackup"
    /// Filenames look like `2026-04-21T10-30-45Z.tasktickbackup` so they sort lexically.
    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private var timer: Timer?
    private var modelContext: ModelContext?

    // MARK: - Settings (persisted via UserDefaults)

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "backupEnabled") }
    }
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
    /// Set when the most recent automatic backup was skipped to protect against
    /// overwriting good data. UI surfaces this so the user knows why their backup
    /// list isn't growing.
    @Published var lastSkipReason: String?

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

    /// `storeURL` is no longer used (kept for API compat with the old call site).
    func configure(storeURL: URL, modelContext: ModelContext? = nil) {
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
        let backups = listBackups()
        let lastBackup = backups.first
        lastBackupDate = lastBackup?.date

        let firstDelay: TimeInterval
        if let lastDate = lastBackup?.date {
            let elapsed = Date().timeIntervalSince(lastDate)
            if elapsed >= interval {
                performBackup()
                firstDelay = interval
            } else {
                firstDelay = interval - elapsed
            }
        } else {
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

    /// Writes a JSON backup. Returns true on success. Returns false (and sets
    /// `lastSkipReason`) when a non-empty previous backup would be overwritten by
    /// an empty snapshot — the safety guard that addresses the original bug.
    @discardableResult
    func performBackup() -> Bool {
        guard let modelContext else {
            Self.logger.warning("No modelContext configured, skipping backup")
            return false
        }

        let tasks: [ScheduledTask]
        do {
            tasks = try modelContext.fetch(FetchDescriptor<ScheduledTask>())
        } catch {
            Self.logger.error("Pre-backup fetch failed, skipping: \(error.localizedDescription)")
            return false
        }

        let templates = ScriptTemplateStore.shared.templates

        // Empty-data protection: if we're about to write zero tasks but a previous
        // backup might have data, refuse the overwrite. Treats unknown task counts
        // (legacy `.store` dirs, partially-written JSON) as "possibly non-empty" so
        // a corrupted live store can never silently clobber the last good snapshot.
        if tasks.isEmpty {
            let existing = listBackups()
            if let latest = existing.first {
                let mightHaveData = latest.taskCount.map { $0 > 0 } ?? true
                if mightHaveData {
                    let countDesc = latest.taskCount.map(String.init) ?? "unknown"
                    let reason = "Live database has 0 tasks but most recent backup has \(countDesc). Refusing to overwrite."
                    Self.logger.warning("\(reason)")
                    lastSkipReason = reason
                    return false
                }
            }
        }

        let exportedTasks = tasks.map(TaskExporter.makeExported)
        let payload = BackupPayload(
            format: BackupPayload.currentFormat,
            appVersion: appVersion,
            exportDate: Date(),
            taskCount: exportedTasks.count,
            templateCount: templates.count,
            tasks: exportedTasks,
            templates: templates
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data: Data
        do {
            data = try encoder.encode(payload)
        } catch {
            Self.logger.error("Backup encode failed: \(error.localizedDescription)")
            return false
        }

        let fm = FileManager.default
        let backupDir = URL(fileURLWithPath: customDirectory)
        do {
            try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        } catch {
            Self.logger.error("Failed to create backup directory: \(error.localizedDescription)")
            return false
        }

        let timestamp = Self.timestampFormatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let fileURL = backupDir.appendingPathComponent("\(timestamp).\(Self.fileExtension)")

        do {
            // Atomic write: data lands at a temp path then is renamed into place,
            // so a crash mid-write never leaves a half-written .tasktickbackup behind.
            try data.write(to: fileURL, options: .atomic)
            Self.logger.info("Backup written to \(fileURL.path) (\(exportedTasks.count) tasks, \(templates.count) templates)")
            pruneOldBackups(in: backupDir)
            lastBackupDate = Date()
            lastSkipReason = nil
            return true
        } catch {
            Self.logger.error("Backup write failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Restore

    enum RestoreResult {
        case success(taskCount: Int, templateCount: Int)
        case failed(message: String)
    }

    /// Restore from a backup file (or legacy directory). The SwiftData rewrite
    /// runs on a detached background ModelContext so the UI thread never blocks —
    /// even with a backup that wipes thousands of accumulated execution logs via
    /// cascade delete. The main `mainContext` picks up the changes through the
    /// shared ModelContainer once the background save commits.
    @discardableResult
    func restore(from entry: BackupEntry) async -> RestoreResult {
        let payload: BackupPayload
        switch entry.format {
        case .json:
            do {
                payload = try Self.readPayload(at: entry.url)
            } catch {
                return .failed(message: "Cannot read backup file: \(error.localizedDescription)")
            }
        case .legacy:
            // Legacy `.store` dirs predate the JSON format. Fall back to the old
            // file-copy restore so users with backups from v1.4.0/v1.4.1 are not
            // stranded after upgrading. Returns a sentinel that triggers an app
            // restart (legacy restore swaps SQLite files under SwiftData, which
            // can't be reloaded in-place).
            return restoreLegacy(from: entry)
        }

        // Heavy SwiftData work off main: capture the container on main, then detach
        // a task that builds its own ModelContext from it. Returning only the
        // primitive RestoreResult keeps the SwiftData objects on their original actor.
        let container = TaskTickApp._sharedModelContainer
        let result: RestoreResult = await Task.detached(priority: .userInitiated) {
            let bgContext = ModelContext(container)
            return Self.applyPayloadOnBackground(payload, in: bgContext)
        }.value

        guard case .success = result else { return result }

        // Post-save bookkeeping that must happen on main: templates (UserDefaults),
        // serial counter (UserDefaults), nextRunAt computation (@MainActor scheduler),
        // and final scheduler rebuild.
        if !payload.templates.isEmpty {
            ScriptTemplateStore.shared.replaceAll(payload.templates)
        }
        let maxSerial = payload.tasks.compactMap { $0.serialNumber }.max() ?? 0
        let currentCounter = UserDefaults.standard.integer(forKey: "taskSerialCounter")
        if maxSerial > currentCounter {
            UserDefaults.standard.set(maxSerial, forKey: "taskSerialCounter")
        }
        // Restored tasks have no `nextRunAt` (we only persist user-authored config in
        // backups). Without this, the scheduler skips them — they'd display in the
        // list but never fire until the user toggled them off and back on.
        if let mainContext = self.modelContext {
            let descriptor = FetchDescriptor<ScheduledTask>(
                predicate: #Predicate { $0.isEnabled && $0.nextRunAt == nil }
            )
            if let restoredTasks = try? mainContext.fetch(descriptor) {
                for task in restoredTasks {
                    task.nextRunAt = TaskScheduler.shared.computeNextRunDate(for: task)
                }
                try? mainContext.save()
            }
        }
        TaskScheduler.shared.rebuildSchedule()
        return result
    }

    /// Restore the most recent JSON backup, used by Recovery Mode.
    @discardableResult
    func restoreFromLatestBackup() async -> Bool {
        let backups = listBackups()
        for backup in backups {
            if case .success = await restore(from: backup) { return true }
        }
        return false
    }

    /// Background-actor implementation. Runs entirely off the main queue using a
    /// dedicated ModelContext bound to the shared container. SwiftData merges the
    /// committed changes back into the main context via the container.
    nonisolated private static func applyPayloadOnBackground(_ payload: BackupPayload, in context: ModelContext) -> RestoreResult {
        let existingTasks: [ScheduledTask]
        do {
            existingTasks = try context.fetch(FetchDescriptor<ScheduledTask>())
        } catch {
            return .failed(message: "Failed to read existing tasks: \(error.localizedDescription)")
        }

        // Insert new first, then delete old. If save fails the rollback leaves the
        // original data intact (vs. delete-then-insert which would wipe everything).
        for item in payload.tasks {
            let task = TaskExporter.makeTask(from: item)
            context.insert(task)
        }
        for task in existingTasks {
            context.delete(task)
        }

        do {
            try context.save()
        } catch {
            context.rollback()
            return .failed(message: "Save failed: \(error.localizedDescription)")
        }

        return .success(taskCount: payload.tasks.count, templateCount: payload.templates.count)
    }

    /// Legacy restore: same logic as the old DatabaseBackup did — copy the SQLite
    /// files from the backup dir into the live store path. Returns a sentinel that
    /// the UI translates to "restart now" because SwiftData cannot reload after the
    /// underlying file changes.
    private func restoreLegacy(from entry: BackupEntry) -> RestoreResult {
        let storeURL = TaskTickApp._storeURL
        let baseName = storeURL.lastPathComponent
        let backupStore = entry.url.appendingPathComponent(baseName)
        let fm = FileManager.default

        guard fm.fileExists(atPath: backupStore.path) else {
            return .failed(message: "Legacy backup is missing the main store file")
        }

        do {
            // Since v1.4.2 the store lives in a bundleID-namespaced subdirectory.
            // Make sure it exists before writing — on a fresh install that has
            // never opened a store, the directory won't have been created yet.
            let storeDir = storeURL.deletingLastPathComponent()
            try fm.createDirectory(at: storeDir, withIntermediateDirectories: true)

            let extensions = ["", "-shm", "-wal"]
            for ext in extensions {
                let fileURL = storeDir.appendingPathComponent(baseName + ext)
                if fm.fileExists(atPath: fileURL.path) {
                    try fm.removeItem(at: fileURL)
                }
            }
            for ext in extensions {
                let sourceURL = entry.url.appendingPathComponent(baseName + ext)
                if fm.fileExists(atPath: sourceURL.path) {
                    let destURL = storeDir.appendingPathComponent(baseName + ext)
                    try fm.copyItem(at: sourceURL, to: destURL)
                }
            }
            // Match the old behavior — flush WAL into the main file before the
            // process restarts so the next launch sees a self-contained store.
            StoreHardener.checkpoint(at: storeURL)
        } catch {
            return .failed(message: "Legacy restore failed: \(error.localizedDescription)")
        }

        // Caller (SettingsView) must trigger a restart for legacy restores.
        return .success(taskCount: 0, templateCount: 0)
    }

    // MARK: - List Backups

    struct BackupEntry: Identifiable {
        enum Format { case json, legacy }
        let id: String
        let name: String
        let date: Date
        let sizeBytes: Int
        let url: URL
        let format: Format
        /// Only populated for JSON backups (cheap to read from the meta header).
        /// Nil for legacy entries — peeking into the SQLite file just to count rows
        /// would require opening it under a read lock and isn't worth the complexity
        /// for a deprecated format.
        let taskCount: Int?
        let templateCount: Int?
    }

    func listBackups() -> [BackupEntry] {
        let fm = FileManager.default
        let backupDir = URL(fileURLWithPath: customDirectory)
        guard let contents = try? fm.contentsOfDirectory(
            at: backupDir,
            includingPropertiesForKeys: [.creationDateKey, .totalFileAllocatedSizeKey]
        ) else { return [] }

        var entries: [BackupEntry] = []
        for url in contents {
            if url.pathExtension == Self.fileExtension {
                if let entry = makeJSONEntry(at: url) {
                    entries.append(entry)
                }
            } else if url.hasDirectoryPath {
                if let entry = makeLegacyEntry(at: url) {
                    entries.append(entry)
                }
            }
        }

        // Newest first. JSON filenames sort lexically (ISO timestamps); legacy dirs
        // share the same naming scheme so a single sort handles both.
        return entries.sorted { $0.name > $1.name }
    }

    func deleteBackup(_ entry: BackupEntry) {
        try? FileManager.default.removeItem(at: entry.url)
        objectWillChange.send()
    }

    // MARK: - Private helpers

    private func makeJSONEntry(at url: URL) -> BackupEntry? {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0

        // Try reading the meta. If the file is corrupt or partial, still surface it
        // so the user can delete it from the UI.
        let payload = try? Self.readPayload(at: url)
        let date = payload?.exportDate ?? Self.parseDate(fromName: url.deletingPathExtension().lastPathComponent)
                   ?? (attrs?[.creationDate] as? Date) ?? Date.distantPast

        return BackupEntry(
            id: url.lastPathComponent,
            name: url.deletingPathExtension().lastPathComponent,
            date: date,
            sizeBytes: size,
            url: url,
            format: .json,
            taskCount: payload?.taskCount,
            templateCount: payload?.templateCount
        )
    }

    private func makeLegacyEntry(at url: URL) -> BackupEntry? {
        let fm = FileManager.default
        let storeURL = TaskTickApp._storeURL
        let baseName = storeURL.lastPathComponent
        let backupStore = url.appendingPathComponent(baseName)
        guard fm.fileExists(atPath: backupStore.path) else { return nil }

        var totalSize = 0
        if let files = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            for file in files {
                if let s = try? fm.attributesOfItem(atPath: file.path)[.size] as? Int {
                    totalSize += s
                }
            }
        }

        let name = url.lastPathComponent
        let date = Self.parseDate(fromName: name)
            ?? (try? fm.attributesOfItem(atPath: url.path))?[.creationDate] as? Date
            ?? Date.distantPast

        return BackupEntry(
            id: name,
            name: name,
            date: date,
            sizeBytes: totalSize,
            url: url,
            format: .legacy,
            taskCount: nil,
            templateCount: nil
        )
    }

    private static func parseDate(fromName name: String) -> Date? {
        // Format: "2026-04-21T10-30-45Z" — colons replaced with dashes for filename safety.
        guard let tIndex = name.firstIndex(of: "T") else { return nil }
        let datePart = name[name.startIndex...tIndex]
        let timePart = name[name.index(after: tIndex)...].replacingOccurrences(of: "-", with: ":")
        let restored = String(datePart) + timePart
        return timestampFormatter.date(from: restored)
    }

    private static func readPayload(at url: URL) throws -> BackupPayload {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupPayload.self, from: data)
    }

    private func pruneOldBackups(in backupDir: URL) {
        let fm = FileManager.default
        // Prune both JSON files and legacy dirs together; the user picked maxBackups
        // for "total slots", not "JSON only". Sort by name desc (ISO timestamps).
        guard let entries = try? fm.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: nil) else { return }
        let sorted = entries
            .filter { $0.pathExtension == Self.fileExtension || $0.hasDirectoryPath }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        if sorted.count > maxBackups {
            for old in sorted.dropFirst(maxBackups) {
                try? fm.removeItem(at: old)
                Self.logger.info("Pruned old backup: \(old.lastPathComponent)")
            }
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}

// MARK: - Backup Payload

/// On-disk format for a single JSON backup. Versioned via `format`; older readers
/// reject unknown formats rather than silently mis-decoding.
struct BackupPayload: Codable {
    static let currentFormat = "tasktick-backup-v1"

    let format: String
    let appVersion: String
    let exportDate: Date
    let taskCount: Int
    let templateCount: Int
    let tasks: [TaskExporter.ExportedTask]
    let templates: [ScriptTemplate]
}
