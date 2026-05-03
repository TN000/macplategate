import AppKit
import Foundation
import ImageIO
import SQLite3
import UniformTypeIdentifiers

/// Store persist + snapshotURL — extension Store.
/// Extracted ze Store.swift jako součást big-refactor split (krok #10).
/// Drží triple-write commit (SQLite + JSONL + JPEG snapshot) hot path.

extension Store {
    func snapshotURL(for rec: RecentDetection) -> URL {
        let stamp = Self.sharedISO8601.string(from: rec.timestamp)
            .replacingOccurrences(of: ":", with: "-")
        let milli = Int((rec.timestamp.timeIntervalSince1970 * 1000).truncatingRemainder(dividingBy: 1000))
        let base = "\(stamp).\(String(format: "%03d", milli))_\(rec.cameraName)_\(rec.plate.replacingOccurrences(of: " ", with: ""))"
        return snapshotsDir.appendingPathComponent("\(base).heic")
    }

    func persist(rec: RecentDetection, isKnown: Bool,
                 cropCG: CGImage?, rawCropCG: CGImage? = nil) -> Int64 {
        writeLock.lock()
        defer { writeLock.unlock() }
        var snapshotPath: String? = nil
        autoreleasepool {
            guard let cg = cropCG else { return }
            let url = snapshotURL(for: rec)
            let base = url.deletingPathExtension().lastPathComponent
            guard let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.heic.identifier as CFString, 1, nil
            ) else { return }
            CGImageDestinationAddImage(dest, cg, [
                kCGImageDestinationLossyCompressionQuality: 0.85,
            ] as CFDictionary)
            if CGImageDestinationFinalize(dest) {
                snapshotPath = url.path
                snapshotIndexAppend(url)
            }

            // Raw sidecar — `<base>.raw.heic` (pre-preprocess camera output).
            if let rawCG = rawCropCG {
                let rawURL = snapshotsDir.appendingPathComponent("\(base).raw.heic")
                if let rawDest = CGImageDestinationCreateWithURL(
                    rawURL as CFURL, UTType.heic.identifier as CFString, 1, nil
                ) {
                    CGImageDestinationAddImage(rawDest, rawCG, [
                        kCGImageDestinationLossyCompressionQuality: 0.85,
                    ] as CFDictionary)
                    if CGImageDestinationFinalize(rawDest) {
                        snapshotIndexAppend(rawURL)
                    }
                }
            }
        }

        // 2) SQLite insert — lock už drží od top of persist().
        var rowId: Int64 = 0
        // Fáze 2.4 pivot: zápis vehicle_type + vehicle_color columns pokud present.
        let sql = "INSERT INTO detections (ts, camera, plate, region, confidence, snapshot_path, known, vehicle_type, vehicle_color) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            let ts = Self.sharedISO8601.string(from: rec.timestamp)
            sqlite3_bind_text(stmt, 1, ts, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, rec.cameraName, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, rec.plate, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, rec.region.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 5, Double(rec.confidence))
            if let p = snapshotPath {
                sqlite3_bind_text(stmt, 6, p, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 6)
            }
            sqlite3_bind_int(stmt, 7, isKnown ? 1 : 0)
            if let vt = rec.vehicleType {
                sqlite3_bind_text(stmt, 8, vt, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 8)
            }
            if let vc = rec.vehicleColor {
                sqlite3_bind_text(stmt, 9, vc, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 9)
            }
            let stepRc = sqlite3_step(stmt)
            if stepRc == SQLITE_DONE {
                rowId = sqlite3_last_insert_rowid(db)
                lastPersistTsValue = Date()
                Task { @MainActor in ErrorNotifier.clear(.sqliteError) }
            } else {
                // Dřív ticho — rowId zůstal 0, JPEG + JSONL se zapsaly, DB row
                // chybí → permanent data loss bez alert. Teď user dostane
                // notifikaci (dedupe 5 min, takže ne-spam).
                let errMsg = String(cString: sqlite3_errmsg(db))
                FileHandle.safeStderrWrite(
                    "[Store] INSERT failed rc=\(stepRc): \(errMsg) plate=\(rec.plate)\n"
                        .data(using: .utf8)!)
                Task { @MainActor in
                    ErrorNotifier.fire(.sqliteError,
                                       title: "Databáze: chyba zápisu",
                                       body: "SQLite vrátil chybu (\(errMsg)). Zkontroluj volné místo a perms na ~/Library/Application Support/SPZ/")
                }
            }
        }
        sqlite3_finalize(stmt)

        // 3) JSONL append (best-effort, immutable audit log) — long-lived handle
        let line: [String: Any] = [
            "id": rowId,
            "ts": Self.sharedISO8601.string(from: rec.timestamp),
            "camera": rec.cameraName,
            "plate": rec.plate,
            "region": rec.region.rawValue,
            "confidence": Double(rec.confidence),
            "snapshot_path": snapshotPath ?? NSNull(),
            "known": isKnown,
        ]
        if let json = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) {
            if let h = jsonlHandle {
                h.write(json); h.write(Data([0x0a]))
            } else {
                // Fallback — handle transient fail (disk full, permission race).
                // MUSÍ to být append, ne `.atomic` write — atomic by přepsal CELÝ
                // soubor jednou řádkou → ztráta audit history. Pokud append fail,
                // jen tahle událost se zahodí, history zůstane intaktní.
                let data = json + Data([0x0a])
                let fm = FileManager.default
                if !fm.fileExists(atPath: jsonlPath.path) {
                    fm.createFile(atPath: jsonlPath.path, contents: nil,
                                  attributes: [.posixPermissions: 0o600])
                }
                if let h = try? FileHandle(forWritingTo: jsonlPath) {
                    defer { try? h.close() }
                    _ = try? h.seekToEnd()
                    try? h.write(contentsOf: data)
                }
            }
        }
        // Retention — kontroluj každých 100 commitů
        pruneSnapshotsIfNeeded()
        return rowId
    }
}
