import Foundation
import SQLite3

/// Store vehicle attributes + confidence histogram queries — extension Store.
/// Extracted ze Store.swift jako součást big-refactor split (krok #10).

extension Store {
    func vehicleTypeDistribution(since: Date) -> [(type: String, count: Int)] {
        writeLock.lock(); defer { writeLock.unlock() }
        let iso = Self.sharedISO8601.string(from: since)
        let sql = """
            SELECT vehicle_type, COUNT(*) FROM detections
            WHERE ts >= ? AND vehicle_type IS NOT NULL
            GROUP BY vehicle_type
            ORDER BY COUNT(*) DESC
        """
        var stmt: OpaquePointer?
        var out: [(String, Int)] = []
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return out }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, iso, -1, SQLITE_TRANSIENT)
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let t = stmt?.textOrNil(0) else { continue }
            let c = Int(sqlite3_column_int64(stmt, 1))
            out.append((t, c))
        }
        return out
    }

    /// Vehicle color distribution — za posledních N dní, grouped by vehicle_color column.
    func vehicleColorDistribution(since: Date) -> [(color: String, count: Int)] {
        writeLock.lock(); defer { writeLock.unlock() }
        let iso = Self.sharedISO8601.string(from: since)
        let sql = """
            SELECT vehicle_color, COUNT(*) FROM detections
            WHERE ts >= ? AND vehicle_color IS NOT NULL
            GROUP BY vehicle_color
            ORDER BY COUNT(*) DESC
        """
        var stmt: OpaquePointer?
        var out: [(String, Int)] = []
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return out }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, iso, -1, SQLITE_TRANSIENT)
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c = stmt?.textOrNil(0) else { continue }
            let n = Int(sqlite3_column_int64(stmt, 1))
            out.append((c, n))
        }
        return out
    }

    /// Confidence histogram — detekce grouped do buckets po 0.05 od 0.5 do 1.0.
    /// Returns seřazené pole [(bucket_midpoint, count)] pro UI plot.
    /// Použití v StatsView: kontroluj quality distribution detekcí.
    func confidenceHistogram(since: Date) -> [(conf: Double, count: Int)] {
        writeLock.lock(); defer { writeLock.unlock() }
        let iso = Self.sharedISO8601.string(from: since)
        // SQL rounds confidence down na bucket of 0.05 width: FLOOR(conf * 20) / 20
        let sql = """
            SELECT CAST(CAST(confidence * 20 AS INTEGER) AS REAL) / 20.0 AS bucket,
                   COUNT(*)
            FROM detections
            WHERE ts >= ? AND confidence >= 0.5
            GROUP BY bucket
            ORDER BY bucket ASC
        """
        var stmt: OpaquePointer?
        var out: [(Double, Int)] = []
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return out }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, iso, -1, SQLITE_TRANSIENT)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let bucket = sqlite3_column_double(stmt, 0)
            let count = Int(sqlite3_column_int64(stmt, 1))
            out.append((bucket + 0.025, count))  // midpoint pro plot
        }
        return out
    }

}
