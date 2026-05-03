import Foundation
import SQLite3

/// Store NL Query helpers — extension Store.
/// Extracted ze Store.swift jako součást big-refactor split (krok #10).
/// Generic single-value + row queries pro NLQueryEngine (Fáze 4.3).

extension Store {
    // MARK: - NL Query helpers (Fáze 4.3)

    /// Generic single-value integer query pro NLQueryEngine. Parametrized přes
    /// positional binds ("?") — SQL statement je vždy od autora (ne-user-input),
    /// user input jde výhradně přes `params` arg → SQL injection safe.
    func querySingleInt(sql: String, params: [String]) -> Int? {
        writeLock.lock(); defer { writeLock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        for (i, v) in params.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), v, -1, SQLITE_TRANSIENT)
        }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return nil
    }

    func querySingleDouble(sql: String, params: [String]) -> Double? {
        writeLock.lock(); defer { writeLock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        for (i, v) in params.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), v, -1, SQLITE_TRANSIENT)
        }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_double(stmt, 0)
        }
        return nil
    }

    func querySingleString(sql: String, params: [String]) -> String? {
        writeLock.lock(); defer { writeLock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        for (i, v) in params.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), v, -1, SQLITE_TRANSIENT)
        }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return stmt?.textOrNil(0)
        }
        return nil
    }

    /// Multi-row query pro seznamové dotazy (posledních N průjezdů). Vrací
    /// [[columnName: value]]. Jen string columns — číselné columns se konvertují.
    func queryRows(sql: String, params: [String]) -> [[String: String]] {
        writeLock.lock(); defer { writeLock.unlock() }
        var stmt: OpaquePointer?
        var rows: [[String: String]] = []
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return rows }
        defer { sqlite3_finalize(stmt) }
        for (i, v) in params.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), v, -1, SQLITE_TRANSIENT)
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: String] = [:]
            let ncol = sqlite3_column_count(stmt)
            for c in 0..<ncol {
                guard let cstrName = sqlite3_column_name(stmt, c) else { continue }
                let name = String(cString: cstrName)
                if let val = stmt?.textOrNil(c) {
                    row[name] = val
                }
            }
            rows.append(row)
        }
        return rows
    }

    /// Vehicle type distribution — za posledních N dní, grouped by vehicle_type column.
}
