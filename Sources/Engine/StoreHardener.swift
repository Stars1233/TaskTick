import Foundation
import SQLite3
import os

/// Hardens the SwiftData SQLite store against the "data stranded in WAL" class of bug.
///
/// SwiftData opens SQLite in WAL journal mode by default. Writes land in a `-wal`
/// sidecar file first and are only merged into the main `.store` on checkpoint. If
/// the app is replaced/killed/restored before a checkpoint, whatever sat in the WAL
/// can be discarded on the next open, silently losing data.
///
/// This type forces a checkpoint and switches the file to DELETE journal mode, so
/// every transaction writes straight to the main file. It must run BEFORE any
/// `ModelContainer` opens the store, otherwise SwiftData will hold the connection
/// and SQLite won't let us change the mode.
enum StoreHardener {
    private static let logger = Logger(subsystem: "com.lifedever.TaskTick", category: "StoreHardener")

    /// Flush any pending WAL into the main DB and switch to DELETE journal mode.
    /// No-op if the store doesn't exist yet (first launch).
    static func hardenStore(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil)
        guard openResult == SQLITE_OK, let db else {
            let msg = errorMessage(db) ?? "open failed"
            logger.error("Cannot open store for hardening: \(msg) (code \(openResult))")
            sqlite3_close(db)
            return
        }
        defer { sqlite3_close(db) }

        // Force any WAL contents into the main DB file and truncate the -wal file.
        // TRUNCATE is the strongest checkpoint mode — it blocks until all writers
        // have drained and shrinks the -wal file to zero bytes. This is the key
        // safety net: any data stranded in a -wal left by a previous launch gets
        // merged into the main store here, before SwiftData even opens the file.
        runPragma(db: db, sql: "PRAGMA wal_checkpoint(TRUNCATE);", action: "checkpoint WAL")
    }

    /// Flush any pending WAL into the main DB. Safe to call while SwiftData holds
    /// the store open — SQLite coordinates concurrent checkpoints via its own
    /// locking. Used after a backup restore to merge the restored -wal immediately.
    static func checkpoint(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return
        }
        defer { sqlite3_close(db) }
        runPragma(db: db, sql: "PRAGMA wal_checkpoint(TRUNCATE);", action: "checkpoint WAL")
    }

    private static func runPragma(db: OpaquePointer, sql: String, action: String) {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            logger.error("Failed to \(action): \(msg) (code \(rc))")
            sqlite3_free(errMsg)
        }
    }

    private static func errorMessage(_ db: OpaquePointer?) -> String? {
        guard let db, let cStr = sqlite3_errmsg(db) else { return nil }
        return String(cString: cStr)
    }
}
