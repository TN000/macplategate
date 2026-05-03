import Foundation
import SQLite3

private let SQLITE_TRANSIENT_DEL = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Delete API pro detekce — bez snapshot file unlink (filesystem cleanup
/// je separate, snapshots/snapshots_retention timer se postará podle data).
extension Store {

    /// Smaže detekci podle ID. Vrací true pokud row existoval + byl deleted.
    /// Volitelně smaže i příslušný .heic snapshot file (pokud `unlinkSnapshot=true`).
    @discardableResult
    func deleteDetection(id: Int, unlinkSnapshot: Bool = true) -> Bool {
        writeLock.lock(); defer { writeLock.unlock() }
        // Nejdřív získej snapshot_path (pro file cleanup) — pak smaž row.
        var snapPath: String? = nil
        if unlinkSnapshot {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT snapshot_path FROM detections WHERE id = ?", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, Int64(id))
                if sqlite3_step(stmt) == SQLITE_ROW {
                    snapPath = stmt?.textOrNil(0)
                }
            }
            sqlite3_finalize(stmt)
        }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "DELETE FROM detections WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        sqlite3_bind_int64(stmt, 1, Int64(id))
        guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        let removed = sqlite3_changes(db) > 0

        if removed, let path = snapPath, !path.isEmpty {
            // Odstraň hlavní + raw snapshot soubory. Best-effort, neselhává.
            try? FileManager.default.removeItem(atPath: path)
            let rawPath = path.replacingOccurrences(of: ".heic", with: ".raw.heic")
            if rawPath != path {
                try? FileManager.default.removeItem(atPath: rawPath)
            }
        }
        return removed
    }

    /// Smaže VŠECHNY detekce pro konkrétní SPZ. Vrací počet smazaných řádků.
    /// Bulk delete pro user-driven "smaž všechny záznamy o vozidle".
    @discardableResult
    func deleteAllDetections(plate: String, unlinkSnapshots: Bool = true) -> Int {
        writeLock.lock(); defer { writeLock.unlock() }
        var paths: [String] = []
        if unlinkSnapshots {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT snapshot_path FROM detections WHERE plate = ?", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, plate, -1, SQLITE_TRANSIENT_DEL)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let p = stmt?.textOrNil(0), !p.isEmpty { paths.append(p) }
                }
            }
            sqlite3_finalize(stmt)
        }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "DELETE FROM detections WHERE plate = ?", -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        sqlite3_bind_text(stmt, 1, plate, -1, SQLITE_TRANSIENT_DEL)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
        let removed = Int(sqlite3_changes(db))

        if unlinkSnapshots {
            for path in paths {
                try? FileManager.default.removeItem(atPath: path)
                let rawPath = path.replacingOccurrences(of: ".heic", with: ".raw.heic")
                if rawPath != path {
                    try? FileManager.default.removeItem(atPath: rawPath)
                }
            }
        }
        return removed
    }
}
