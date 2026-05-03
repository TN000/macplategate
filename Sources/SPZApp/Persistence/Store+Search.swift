import AppKit
import Foundation
import SQLite3

/// Store search + per-plate detection count methods — extension Store.
/// Extracted ze Store.swift jako součást big-refactor split (krok #10).

extension Store {
    func searchDetections(plateContains query: String, limit: Int = 50) -> [RecentDetection] {
        writeLock.lock(); defer { writeLock.unlock() }
        var out: [RecentDetection] = []
        // Escape LIKE wildcardů — viz queryDetections() komentář.
        let q = query.uppercased().replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let sql = """
            SELECT id, ts, camera, plate, region, confidence, snapshot_path
            FROM detections
            WHERE REPLACE(UPPER(plate), ' ', '') LIKE ? ESCAPE '\\'
            ORDER BY id DESC LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, "%\(q)%", -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let ts = stmt?.textOrNil(1),
                  let camera = stmt?.textOrNil(2),
                  let plate = stmt?.textOrNil(3) else { continue }
            let id = Int(sqlite3_column_int64(stmt, 0))
            let regionRaw = stmt?.textOrNil(4) ?? PlateRegion.unknown.rawValue
            let conf = Float(sqlite3_column_double(stmt, 5))
            let snapPath = stmt?.textOrNil(6)
            let date = Self.sharedISO8601.date(from: ts) ?? Date()
            let region = PlateRegion(rawValue: regionRaw) ?? .unknown
            var crop: NSImage? = nil
            if let p = snapPath, FileManager.default.fileExists(atPath: p) {
                crop = NSImage(contentsOfFile: p)
            }
            out.append(RecentDetection(
                id: id, timestamp: date, cameraName: camera, plate: plate,
                region: region, confidence: conf, bbox: .zero, cropImage: crop
            ))
        }
        return out
    }

    // MARK: - Parkovací sessions (vjezd/vyjezd páry)

    struct ParkingSession: Identifiable {
        let id: Int64
        let plate: String
        let entryTs: Date?
        let exitTs: Date?
        let durationSec: Int?
        var isOpen: Bool { exitTs == nil }
    }

    // Parking sessions lifecycle (open/close/purge/openSessions) extracted to Store+Sessions.swift.

    /// Počet gate-level detekcí (všech) pro plate od data (bez ohledu na kameru).
    func detectionCount(plate: String, since: Date) -> Int {
        let iso = Self.sharedISO8601.string(from: since)
        return count(sql: "SELECT COUNT(*) FROM detections WHERE plate = ? AND ts >= ?",
                     binds: [plate, iso])
    }

    /// Počet detekcí per kamera (vjezd/vyjezd) za období.
    func detectionCountsByCamera(plate: String, since: Date) -> [String: Int] {
        writeLock.lock(); defer { writeLock.unlock() }
        var out: [String: Int] = [:]
        let sinceIso = Self.sharedISO8601.string(from: since)
        let sql = "SELECT camera, COUNT(*) FROM detections WHERE plate = ? AND ts >= ? GROUP BY camera"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return out }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, plate, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, sinceIso, -1, SQLITE_TRANSIENT)
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cam = stmt?.textOrNil(0) else { continue }
            out[cam] = Int(sqlite3_column_int64(stmt, 1))
        }
        return out
    }

    func count(sql: String, binds: [String]) -> Int {
        var stmt: OpaquePointer?
        var n = 0
        writeLock.lock(); defer { writeLock.unlock() }
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            for (i, v) in binds.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), v, -1, SQLITE_TRANSIENT)
            }
            if sqlite3_step(stmt) == SQLITE_ROW {
                n = Int(sqlite3_column_int(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        return n
    }
}
