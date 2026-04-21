import Foundation
import os

/// One-time migration from the shared Application Support root to a bundleID-
/// namespaced subdirectory.
///
/// Background: pre-v1.4.2 builds wrote `default.store` (release) or
/// `tasktick-dev.store` (dev) directly into `~/Library/Application Support/`.
/// Apple explicitly warns against this:
///
/// > Two or more apps that use the default location and name will either
/// > overwrite each other's models, or crash because the model on disk doesn't
/// > match the model described in the app.
///
/// `default.store` is the SwiftData convention any other unsandboxed SwiftData
/// app defaults to. When such an app runs, macOS 15's persistent-history logic
/// sees TaskTick's entities as "removed" and truncates the tables — the silent
/// data-loss failure mode in issue #22 (`dfface` report).
///
/// This migration moves the store into a per-bundleID subdirectory so no other
/// app can ever touch it.
///
/// **Safety invariants** (re-read these before changing anything):
///
/// 1. **Never delete the legacy files.** They stay as a permanent safety net.
///    Worst case the user can manually swap them back in.
/// 2. **Copy-to-tmp-then-rename.** Every file is copied to `<name>.migrating`
///    first; the atomic rename to the final name only happens after ALL tmp
///    copies succeed.
/// 3. **Rename order: `-wal` → `-shm` → `.store`.** SwiftData decides "the
///    store exists" by checking the main `.store` file. If we renamed `.store`
///    first and crashed, the next launch would see "migrated" but the
///    companion files would still be `.migrating` — SQLite would open a
///    partially-configured store. Keeping `.store` last guarantees that as
///    soon as it exists at the final name, its companions already do too.
/// 4. **Size sanity-check after every copy.** A short write on a full disk
///    would corrupt the new store. Size mismatch ⇒ rollback, leave legacy
///    alone, return the (still-empty) new URL so SwiftData triggers recovery.
/// 5. **Ambiguous states fail safe.** If both legacy and new already have data,
///    use new (don't auto-merge). The operator can recover either manually.
/// 6. **Never throw.** Migration runs inside a `static let` initializer; a
///    throw there would crash the app on launch. Any failure is logged and
///    the caller falls back to opening the (possibly empty) new path.
enum StoreMigration {
    private static let logger = Logger(subsystem: "com.lifedever.TaskTick", category: "StoreMigration")
    private static let tmpSuffix = ".migrating"
    /// All three SwiftData SQLite sidecars. Order matters for the rename phase.
    private static let extensions = ["-wal", "-shm", ""]

    /// Returns the URL TaskTick should pass to `ModelConfiguration`. Migrates
    /// legacy data into a per-bundleID subdirectory on first run of v1.4.2+.
    /// Idempotent — safe to call on every launch.
    static func resolveStoreURL() -> URL {
        let appSupport = URL.applicationSupportDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "com.lifedever.TaskTick"
        let isDev = bundleID.hasSuffix(".dev")
        // Filename kept identical to legacy so old DatabaseBackup `.store`-dir
        // backups keep working (they record the legacy filename verbatim).
        let filename = isDev ? "tasktick-dev.store" : "default.store"

        let legacyURL = appSupport.appendingPathComponent(filename)
        let namespaceDir = appSupport.appendingPathComponent(bundleID)
        let newURL = namespaceDir.appendingPathComponent(filename)

        let fm = FileManager.default
        let newExists = fm.fileExists(atPath: newURL.path)
        let legacyExists = fm.fileExists(atPath: legacyURL.path)

        // Case A: new already has a store. Authoritative. Don't migrate or merge.
        if newExists {
            if legacyExists {
                logger.notice("""
                Both new and legacy stores exist. Using new; legacy preserved as a \
                safety net at \(legacyURL.path)
                """)
            }
            return newURL
        }

        // Case B: neither exists → fresh install. Use new path.
        if !legacyExists {
            return newURL
        }

        // Case C: legacy exists, new does not → do the migration.
        logger.notice("Starting store migration: \(legacyURL.path) → \(newURL.path)")
        let migrated = migrate(from: legacyURL, to: newURL, namespaceDir: namespaceDir)
        if migrated {
            logger.notice("Store migration succeeded. Legacy preserved at \(legacyURL.path)")
        } else {
            // Failure already rolled back to the pre-migration state. The caller
            // will open an empty store at newURL, flip `_needsRecovery`, and the
            // user can restore from a JSON backup.
            logger.error("""
            Store migration FAILED. Legacy files left untouched at \(legacyURL.path). \
            New path will open empty and recovery mode will trigger.
            """)
        }
        return newURL
    }

    // MARK: - Private

    /// Copy the legacy `.store`/`.store-shm`/`.store-wal` trio into `newURL`'s
    /// parent directory using the copy-tmp-then-rename pattern. Returns true on
    /// full success; on any failure, rolls back every partially-staged tmp/final
    /// file and leaves the legacy files untouched.
    private static func migrate(from legacyURL: URL, to newURL: URL, namespaceDir: URL) -> Bool {
        let fm = FileManager.default
        let legacyDir = legacyURL.deletingLastPathComponent()
        let legacyBase = legacyURL.lastPathComponent
        let newBase = newURL.lastPathComponent

        // Make sure the namespaced subdirectory exists. Other steps assume it.
        do {
            try fm.createDirectory(at: namespaceDir, withIntermediateDirectories: true)
        } catch {
            logger.error("Cannot create namespace directory \(namespaceDir.path): \(error.localizedDescription)")
            return false
        }

        // Phase 1: copy every existing legacy file into its `.migrating` tmp.
        // `staged` tracks which tmps we created so rollback can reach them.
        var staged: [(sourceName: String, tmp: URL, finalURL: URL, size: Int)] = []

        for ext in extensions {
            let source = legacyDir.appendingPathComponent(legacyBase + ext)
            guard fm.fileExists(atPath: source.path) else { continue }
            let finalURL = namespaceDir.appendingPathComponent(newBase + ext)
            let tmp = namespaceDir.appendingPathComponent(newBase + ext + tmpSuffix)

            // Clear a stale tmp from a previously-interrupted migration attempt.
            if fm.fileExists(atPath: tmp.path) {
                do {
                    try fm.removeItem(at: tmp)
                } catch {
                    logger.error("Cannot remove stale tmp \(tmp.path): \(error.localizedDescription)")
                    rollback(staged: staged)
                    return false
                }
            }

            // An existing final at the target would mean we're in case A, which
            // resolveStoreURL already handled. Refuse defensively rather than
            // overwrite.
            if fm.fileExists(atPath: finalURL.path) {
                logger.error("Unexpected existing file at migration target \(finalURL.path). Aborting.")
                rollback(staged: staged)
                return false
            }

            do {
                try fm.copyItem(at: source, to: tmp)
            } catch {
                logger.error("Copy failed for \(source.lastPathComponent): \(error.localizedDescription)")
                rollback(staged: staged)
                return false
            }

            // Size sanity check. Mismatch on the SQLite files is always a bug
            // (fm.copyItem is supposed to be exact), so treat it as a rollback
            // trigger rather than continue and hand SwiftData a truncated DB.
            let sourceSize = (try? fm.attributesOfItem(atPath: source.path))?[.size] as? Int
            let tmpSize = (try? fm.attributesOfItem(atPath: tmp.path))?[.size] as? Int
            guard let s = sourceSize, let t = tmpSize, s == t else {
                logger.error("Size mismatch for \(source.lastPathComponent): source=\(String(describing: sourceSize)) tmp=\(String(describing: tmpSize))")
                rollback(staged: staged)
                return false
            }

            staged.append((sourceName: source.lastPathComponent, tmp: tmp, finalURL: finalURL, size: s))
            logger.info("Staged \(source.lastPathComponent) (\(s) bytes)")
        }

        // Edge case: no legacy files existed after all (shouldn't happen — we
        // verified `legacyExists` at the call site — but defend anyway).
        guard !staged.isEmpty else {
            logger.error("No files staged; nothing to migrate.")
            return false
        }

        // Phase 2: rename tmps to their final names. Order is CRITICAL:
        // companions first, main `.store` last, so the "is this DB present"
        // check based on the main file is true only when everything is ready.
        let renameOrder = staged.sorted { lhs, rhs in
            let lhsIsMain = lhs.finalURL.lastPathComponent == newBase
            let rhsIsMain = rhs.finalURL.lastPathComponent == newBase
            // Main file goes LAST (i.e., should be "greater" in sort).
            if lhsIsMain && !rhsIsMain { return false }
            if !lhsIsMain && rhsIsMain { return true }
            return false
        }

        var renamed: [URL] = []
        for item in renameOrder {
            do {
                try fm.moveItem(at: item.tmp, to: item.finalURL)
                renamed.append(item.finalURL)
            } catch {
                logger.error("Rename failed for \(item.tmp.lastPathComponent) → \(item.finalURL.lastPathComponent): \(error.localizedDescription)")
                // Rollback: remove anything we already renamed, plus any tmps
                // that haven't been renamed yet.
                for url in renamed {
                    try? fm.removeItem(at: url)
                }
                rollback(staged: staged)
                return false
            }
        }

        return true
    }

    /// Remove any `.migrating` tmp files from a failed run. Never touches
    /// anything except `.migrating` siblings in the namespaced directory.
    private static func rollback(staged: [(sourceName: String, tmp: URL, finalURL: URL, size: Int)]) {
        let fm = FileManager.default
        for item in staged where fm.fileExists(atPath: item.tmp.path) {
            try? fm.removeItem(at: item.tmp)
        }
    }
}
