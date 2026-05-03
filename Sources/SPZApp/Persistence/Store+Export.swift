import Foundation
import SQLite3

/// Store CSV export — extension Store.
/// Extracted ze Store.swift jako součást big-refactor split (krok #10).
/// Drží exportDetectionsCSV / exportSessionsCSV + csvEscape helper.

extension Store {
    /// id, ts (ISO8601), camera, plate, region, confidence, snapshot_path, known.
    /// Vrací počet exportovaných řádků, nebo -1 při chybě.
    @discardableResult
    func exportDetectionsCSV(to url: URL) -> Int {
        writeLock.lock(); defer { writeLock.unlock() }
        let sql = """
            SELECT id, ts, camera, plate, region, confidence, snapshot_path, known
            FROM detections ORDER BY id ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        var csv = "id,cas,kamera,spz,region,jistota,fotka,zname\n"
        var rows = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let ts = stmt?.textOrNil(1) ?? ""
            let camera = stmt?.textOrNil(2) ?? ""
            let plate = stmt?.textOrNil(3) ?? ""
            let region = stmt?.textOrNil(4) ?? PlateRegion.unknown.rawValue
            let conf = sqlite3_column_double(stmt, 5)
            let snap = stmt?.textOrNil(6) ?? ""
            let known = sqlite3_column_int(stmt, 7)
            csv += "\(id),\(ts),\(csvEscape(camera)),\(csvEscape(plate)),\(region),\(String(format: "%.3f", conf)),\(csvEscape(snap)),\(known == 1 ? "ano" : "ne")\n"
            rows += 1
        }
        do {
            try csv.data(using: .utf8)?.write(to: url, options: .atomic)
            return rows
        } catch {
            return -1
        }
    }

    /// Exportuje parkovací sessions (vjezd+výjezd s dobou stání) do CSV.
    /// Sloupce: id, plate, entry_ts, exit_ts, duration_sec, duration_hm.
    @discardableResult
    func exportSessionsCSV(to url: URL) -> Int {
        writeLock.lock(); defer { writeLock.unlock() }
        let sql = """
            SELECT id, plate, entry_ts, exit_ts, duration_sec
            FROM sessions ORDER BY id ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        var csv = "id,spz,vjezd,vyjezd,doba_s,doba_hm\n"
        var rows = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let plate = stmt?.textOrNil(1) ?? ""
            let entry = stmt?.textOrNil(2) ?? ""
            let exit = stmt?.textOrNil(3) ?? ""
            let duration: Int64 = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? 0 : sqlite3_column_int64(stmt, 4)
            let hm: String = duration > 0 ? "\(duration / 3600)h \((duration % 3600) / 60)m" : ""
            csv += "\(id),\(csvEscape(plate)),\(entry),\(exit),\(duration),\(hm)\n"
            rows += 1
        }
        do {
            try csv.data(using: .utf8)?.write(to: url, options: .atomic)
            return rows
        } catch {
            return -1
        }
    }

    func csvEscape(_ s: String) -> String {
        // RFC 4180: pokud obsahuje čárku/newline/uvozovky → obalit do "" a zdvojit "
        if s.contains(",") || s.contains("\n") || s.contains("\"") {
            return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return s
    }
}
