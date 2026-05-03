import Foundation
import SQLite3

/// Store parking sessions lifecycle — extension Store.
/// Extracted ze Store.swift jako součást big-refactor split (krok #10).
/// Drží open/close/purge session operations + queries.

extension Store {
    /// Vjezd → otevře novou session. Pokud už existuje otevřená (unclosed) session
    /// pro tuto plate (edge case: závěr vyjezd commit se neprovedl), zavři ji tiše
    /// s duration_sec = čas mezi jejím vjezdem a novým vjezdem (auto odjelo bez
    /// detekce výjezdu — pouze rough estimate).
    func openParkingSession(plate: String, at ts: Date) {
        writeLock.lock(); defer { writeLock.unlock() }
        let iso = Self.sharedISO8601.string(from: ts)
        // Zavři orphan open session
        let closeOrphan = "UPDATE sessions SET exit_ts = ?, duration_sec = CAST((julianday(?) - julianday(entry_ts)) * 86400 AS INTEGER) WHERE plate = ? AND exit_ts IS NULL"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, closeOrphan, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, iso, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, iso, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, plate, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt); stmt = nil
        // Insert new
        let insert = "INSERT INTO sessions (plate, entry_ts) VALUES (?, ?)"
        if sqlite3_prepare_v2(db, insert, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, plate, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, iso, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    /// Výjezd → zavře nejnovější otevřenou session pro plate. Pokud žádná open
    /// není (edge case: výjezd bez předchozího vjezdu), vytvoří session s
    /// entry_ts = NULL + exit_ts = ts (duration neznámé).
    func closeParkingSession(plate: String, at ts: Date) {
        writeLock.lock(); defer { writeLock.unlock() }
        let iso = Self.sharedISO8601.string(from: ts)
        let update = "UPDATE sessions SET exit_ts = ?, duration_sec = CAST((julianday(?) - julianday(entry_ts)) * 86400 AS INTEGER) WHERE id = (SELECT id FROM sessions WHERE plate = ? AND exit_ts IS NULL ORDER BY id DESC LIMIT 1)"
        var stmt: OpaquePointer?
        var updatedRows = 0
        if sqlite3_prepare_v2(db, update, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, iso, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, iso, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, plate, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_DONE {
                updatedRows = Int(sqlite3_changes(db))
            }
        }
        sqlite3_finalize(stmt); stmt = nil
        if updatedRows == 0 {
            // Orphan exit — insert session without entry_ts
            let orphan = "INSERT INTO sessions (plate, entry_ts, exit_ts, duration_sec) VALUES (?, NULL, ?, NULL)"
            if sqlite3_prepare_v2(db, orphan, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, plate, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, iso, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    /// Vrátí sessions pro plate od daného data, nejnovější první.
    func sessions(plate: String, since: Date) -> [ParkingSession] {
        writeLock.lock(); defer { writeLock.unlock() }
        var out: [ParkingSession] = []
        let sinceIso = Self.sharedISO8601.string(from: since)
        let sql = """
            SELECT id, plate, entry_ts, exit_ts, duration_sec
            FROM sessions
            WHERE plate = ? AND COALESCE(entry_ts, exit_ts) >= ?
            ORDER BY id DESC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, plate, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, sinceIso, -1, SQLITE_TRANSIENT)
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let p = stmt?.textOrNil(1) else { continue }
            let id = sqlite3_column_int64(stmt, 0)
            let entry = stmt?.textOrNil(2).flatMap { Self.sharedISO8601.date(from: $0) }
            let exit = stmt?.textOrNil(3).flatMap { Self.sharedISO8601.date(from: $0) }
            let dur: Int? = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil
                          : Int(sqlite3_column_int64(stmt, 4))
            out.append(ParkingSession(id: id, plate: p, entryTs: entry, exitTs: exit, durationSec: dur))
        }
        return out
    }

    /// Smaže všechny sessions pro SPZ které NEJSOU v poskytnutém allowlistu.
    /// Použito pro cleanup orphanů vzniklých před zavedením whitelist-only
    /// pravidla (session tracking se propustil i cizím SPZ).
    func purgeSessionsNotIn(plates: [String]) {
        writeLock.lock(); defer { writeLock.unlock() }
        // SQLite IN clause generovaný dynamicky — parametrizované binds.
        if plates.isEmpty {
            sqlite3_exec(db, "DELETE FROM sessions", nil, nil, nil)
            return
        }
        let placeholders = Array(repeating: "?", count: plates.count).joined(separator: ",")
        let sql = "DELETE FROM sessions WHERE plate NOT IN (\(placeholders))"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        for (i, p) in plates.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), p, -1, SQLITE_TRANSIENT)
        }
        sqlite3_step(stmt)
    }

    /// Smaže všechny sessions pro konkrétní SPZ — volat když je plate odstraněna
    /// z whitelistu. Vrací počet smazaných řádků.
    @discardableResult
    func purgeSessions(plate: String) -> Int {
        writeLock.lock(); defer { writeLock.unlock() }
        var stmt: OpaquePointer?
        let sql = "DELETE FROM sessions WHERE plate = ?"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, plate, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        return Int(sqlite3_changes(db))
    }

    /// Všechny aktuálně otevřené sessions (nikdo nezaznamenal výjezd) — seznam aut
    /// na parkovišti. Seřazeno od nejnovějšího vjezdu.
    func openSessions() -> [ParkingSession] {
        writeLock.lock(); defer { writeLock.unlock() }
        var out: [ParkingSession] = []
        let sql = "SELECT id, plate, entry_ts, exit_ts, duration_sec FROM sessions WHERE exit_ts IS NULL ORDER BY id DESC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let p = stmt?.textOrNil(1) else { continue }
            let id = sqlite3_column_int64(stmt, 0)
            let entry = stmt?.textOrNil(2).flatMap { Self.sharedISO8601.date(from: $0) }
            out.append(ParkingSession(id: id, plate: p, entryTs: entry, exitTs: nil, durationSec: nil))
        }
        return out
    }
}
