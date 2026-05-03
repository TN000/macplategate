import AppKit
import Foundation
import ImageIO
import SQLite3
import UniformTypeIdentifiers

// SQLite helpers (columnText/Int/Double, OpaquePointer extension, SQLITE_TRANSIENT)
// + LockedISO8601DateFormatter extracted to Persistence/SQLiteHelpers.swift.

/// Triple-write persistence: SQLite WAL + JSONL append-only + JPEG snapshot na disk.
/// Vše uloženo v ~/Library/Application Support/SPZ/.
///
/// `nonisolated` (ne `@MainActor`) — heavy IO (HEIC encoding ~10-20 ms, SQLite
/// synchronous=FULL insert, JSONL append) musí běžet v `Task.detached` aby
/// neblokovala MainActor během průjezdů. Internal `writeLock: NSLock` zajišťuje
/// per-write serializaci (SQLite je single-writer).
final class Store: @unchecked Sendable {
    static let shared = Store()

    let dataDir: URL
    let snapshotsDir: URL
    let manualPassesDir: URL
    let dbPath: String
    let jsonlPath: URL

    // Internal access (ne private) aby Store+Snapshots / Store+Sessions /
    // Store+Export extensions ze sousedních souborů měly přístup k SQLite primitives.
    var db: OpaquePointer?
    let writeLock = NSLock()
    /// Long-lived JSONL append handle — otevíráme jednou, recyklujeme. Bez toho
    /// každý commit platil ~5–15 ms za open/seekToEnd/close a blokoval MainActor.
    var jsonlHandle: FileHandle?
    /// Sdílený ISO8601 formatter za lockem. `ISO8601DateFormatter` není
    /// garantovaně thread-safe; Store je teď volaný z MainActoru i
    /// `Task.detached`, takže přímý `nonisolated(unsafe)` formatter byl race.
    static let sharedISO8601 = LockedISO8601DateFormatter()

    init() {
        let appSup: URL = {
            if let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                return url.appendingPathComponent("SPZ", isDirectory: true)
            }
            // Fallback: ~/SPZ pokud Application Support není dostupný
            let home = FileManager.default.homeDirectoryForCurrentUser
            return home.appendingPathComponent("SPZ", isDirectory: true)
        }()
        try? FileManager.default.createDirectory(at: appSup, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: appSup.path)
        let snaps = appSup.appendingPathComponent("snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: snaps, withIntermediateDirectories: true)
        let manual = appSup.appendingPathComponent("manual-prujezdy", isDirectory: true)
        try? FileManager.default.createDirectory(at: manual, withIntermediateDirectories: true)
        // Restriktivní dir perms — snapshot JPEGy obsahují plate crop + okolí
        // = PII, nesmí být world-readable.
        let dirRestrict: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try? FileManager.default.setAttributes(dirRestrict, ofItemAtPath: snaps.path)
        try? FileManager.default.setAttributes(dirRestrict, ofItemAtPath: manual.path)
        self.dataDir = appSup
        self.snapshotsDir = snaps
        self.manualPassesDir = manual
        self.dbPath = appSup.appendingPathComponent("detections.db").path
        self.jsonlPath = appSup.appendingPathComponent("detections.jsonl")
        openDB()
        openJsonl()
        // JSONL perms — openJsonl vytváří soubor přes FileManager default 0644.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: jsonlPath.path)
    }

    deinit {
        try? jsonlHandle?.close()
        if let db = db { sqlite3_close_v2(db) }
    }

    private func openJsonl() {
        if !FileManager.default.fileExists(atPath: jsonlPath.path) {
            FileManager.default.createFile(atPath: jsonlPath.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        }
        if let h = try? FileHandle(forWritingTo: jsonlPath) {
            do { try h.seekToEnd() } catch {
                FileHandle.safeStderrWrite("[Store] jsonl seekToEnd err: \(error)\n".data(using: .utf8)!)
            }
            self.jsonlHandle = h
        }
    }

    private func openDB() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            // stderr.write místo print — print jde na stdout (který není redirectovaný);
            // stderr je v SPZApp.init přesměrován do ~/Library/Application Support/SPZ/spz.log,
            // takže tahle chyba projde do logu i kdyby selhalo hned po startu.
            FileHandle.safeStderrWrite(
                "[Store] sqlite open failed: \(String(cString: sqlite3_errmsg(db)))\n"
                    .data(using: .utf8)!)
            return
        }
        exec("PRAGMA journal_mode=WAL")
        // FULL synchronous = fsync WAL per commit → garantuje že detekce přežije
        // power loss (Mac mini bez UPS). Režie <5 ms per commit je zanedbatelná
        // při <1 plate/s throughput. NORMAL by riskoval ztrátu posledních ~5 min
        // dat do auto-checkpointu při výpadku proudu.
        exec("PRAGMA synchronous=FULL")
        // Busy timeout 5 s — bez tohoto vrací SQLITE_BUSY okamžitě když jiný
        // reader drží WAL header (Spotlight/Time Machine/Finder preview).
        // Inserty by pak mlčky mizely (rowId=0 path v persist()).
        exec("PRAGMA busy_timeout=5000")
        // Auto-checkpoint po 100 stranách (~400 KB) — vyšší hodnota (1000 ≈ 4 MB)
        // způsobovala 50-200 ms commit stalls jednou za ~30 s při traffic, což
        // korelovalo s OCR misses. 100 pages = ~10-20 ms checkpoint smoother
        // (každých 3-5 s).
        exec("PRAGMA wal_autocheckpoint=100")
        // Restriktivní permissions na DB soubory (plate data = PII). 0644 default
        // by nechal local user / backup agent číst detekce.
        let restrict: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.setAttributes(restrict, ofItemAtPath: dbPath + suffix)
        }
        exec("""
            CREATE TABLE IF NOT EXISTS detections (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts TEXT NOT NULL,
                camera TEXT NOT NULL,
                plate TEXT NOT NULL,
                region TEXT,
                confidence REAL NOT NULL,
                snapshot_path TEXT,
                known INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_det_ts ON detections(ts);
            CREATE INDEX IF NOT EXISTS idx_det_plate ON detections(plate);

            CREATE TABLE IF NOT EXISTS sessions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                plate TEXT NOT NULL,
                entry_ts TEXT,
                exit_ts TEXT,
                duration_sec INTEGER
            );
            CREATE INDEX IF NOT EXISTS idx_sess_plate ON sessions(plate);
            CREATE INDEX IF NOT EXISTS idx_sess_entry ON sessions(entry_ts);
            CREATE INDEX IF NOT EXISTS idx_sess_open ON sessions(plate, exit_ts);
        """)

        // Fáze 2.4: VIGI Vehicle Attribute columns — additive migration. SQLite
        // `ALTER TABLE ADD COLUMN` je safe na live DB, column je NULL pro rows
        // vytvořené před migrací (backward compat).
        // Columns jsou NULLable do doby než VIGIEventListener dodá wire protocol.
        addColumnIfMissing(table: "detections", column: "vehicle_type", type: "TEXT")
        addColumnIfMissing(table: "detections", column: "vehicle_color", type: "TEXT")
        addColumnIfMissing(table: "detections", column: "vehicle_direction", type: "TEXT")
    }

    func addColumnIfMissing(table: String, column: String, type: String) {
        // Check PRAGMA table_info → column list, pak ADD COLUMN jen když chybí.
        var stmt: OpaquePointer?
        let sql = "PRAGMA table_info(\(table))"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            var found = false
            while sqlite3_step(stmt) == SQLITE_ROW {
                if stmt?.textOrNil(1) == column {
                    found = true
                    break
                }
            }
            sqlite3_finalize(stmt)
            if !found {
                exec("ALTER TABLE \(table) ADD COLUMN \(column) \(type);")
                FileHandle.safeStderrWrite(
                    "[Store] migration: added column \(table).\(column) \(type)\n"
                        .data(using: .utf8)!)
            }
        }
    }

    /// Retention job — spouští se per-launch + po každém 100. commitu.
    /// Smaže snapshoty starší než `snapshotRetentionDays` dnů a drží seznam souborů
    /// pod `snapshotMaxFiles`. Bez tohoto `snapshots/` rostla 24/7 neomezeně
    /// (uživatel měl 881 souborů během několika dní testování).
    /// Runtime-nastavitelné z AppState (Settings → Úložiště).
    /// 0 = unlimited (retention skip).
    var snapshotRetentionDays: Double = 30
    var snapshotMaxFiles: Int = 5_000
    /// Max počet manuálních průjezdů v `manual-prujezdy/`. Nastavitelné z Settings
    /// přes AppState.manualPassesMaxCount. Nad limit → FIFO ořez nejstarších.
    var manualPassesMaxCount: Int = 200

    var commitsSinceRetention: Int = 0
    static let retentionInterval: Int = 100

    /// In-memory sorted index (oldest → newest) snapshotů. Vyhne se O(N) scanu
    /// `contentsOfDirectory` + `resourceValues` při každém prune. Init scan
    /// proběhne jen jednou, pak jen incremental add/remove.
    var snapshotIndex: [(url: URL, date: Date)] = []
    var snapshotIndexLoaded: Bool = false
    /// Full rescan každých N prune cyklů — pro případ že soubory zmizely zvenku
    /// (user smazal ručně, crash, …). Každých 10 prune cyklů (≈ každých 1000
    /// commitů s `retentionInterval=100`).
    var pruneCallCount: Int = 0
    static let fullRescanInterval: Int = 10

    // Snapshot/manual-pass retention methods extracted to Store+Snapshots.swift.

    /// Timestamp posledního úspěšného persist() — HealthMonitor ho čte pro
    /// tile „DB writable". nil dokud nedošlo k prvnímu commitu (fresh app).
    ///
    /// Store už není MainActor-isolated a `persist()` běží z `Task.detached`.
    /// `@Published` tady nemělo ObservableObject consumer a zároveň by emitovalo
    /// z background threadu. Držíme obyčejnou hodnotu pod stejným lockem jako DB.
    var lastPersistTsValue: Date?
    var lastPersistTs: Date? {
        writeLock.lock()
        defer { writeLock.unlock() }
        return lastPersistTsValue
    }

    /// Velikost WAL souboru v bytech — HealthMonitor ji vidí a varuje při
    /// >50 MB (auto-checkpoint je 1000 pages = ~4 MB, normální).
    func walSizeBytes() -> Int {
        let walPath = dbPath + "-wal"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: walPath),
              let size = attrs[.size] as? Int else { return 0 }
        return size
    }

    /// Periodický WAL checkpoint — volá ho AppState timer každých ~5 min.
    /// Vrací true pokud truncate úspěšný.
    @discardableResult
    func periodicCheckpoint() -> Bool {
        writeLock.lock(); defer { writeLock.unlock() }
        let rc = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil)
        return rc == SQLITE_OK
    }

    private func exec(_ sql: String) {
        var err: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK, let err = err {
            FileHandle.safeStderrWrite(
                "[Store] exec err: \(String(cString: err))\n".data(using: .utf8)!)
            sqlite3_free(err)
        }
    }

    // MARK: - Persist commit

    /// Background-safe persist API. CGImage je CoreGraphics value-type compatible
    /// across thread/Task boundaries (na rozdíl od NSImage co pulls AppKit
    /// state). Caller (PlatePipeline.commit) konvertuje NSImage → CGImage v
    /// MainActor scope a pak posílá CGImage do Task.detached.
    ///
    /// **Plně serializovaný:** writeLock se acquire na ÚPLNÉM ZAČÁTKU a drží
    /// přes celé persist (HEIC encoding + snapshotIndex mutace + SQLite INSERT
    /// + JSONL append + retention prune). Bez tohoto by paralelní Task.detached
    /// commits racovaly na `snapshotIndex`, `commitsSinceRetention` a
    /// `lastPersistTs`. Single big lock je acceptable — persists jsou < 1/sec
    /// typicky.
    @discardableResult
    /// Deterministicky spočítá URL HEIC snapshotu pro dané recent. Sdíleno mezi
    /// `persist()` (kde se soubor zapíše) a `PlatePipeline.commit()` (kde stejnou
    /// cestou předvyplníme `RecentDetection.snapshotPath`, aby UI tap mohl
    /// otevřít originál ihned, bez čekání na Task.detached persist).
    // persist + snapshotURL extracted to Store+Persist.swift.

    // MARK: - Stats

    func countAll() -> Int { count(sql: "SELECT COUNT(*) FROM detections", binds: []) }

    // MARK: - Stats queries (pro STATISTIKY panel)

    /// Počet detekcí v daném časovém rozsahu [from, to).
    func countRange(from: Date, to: Date) -> Int {
        let f = Self.sharedISO8601.string(from: from)
        let t = Self.sharedISO8601.string(from: to)
        return count(sql: "SELECT COUNT(*) FROM detections WHERE ts >= ? AND ts < ?", binds: [f, t])
    }

    /// Počet UZAVŘENÝCH parkovacích sessionů v rozsahu.
    func sessionsCountRange(from: Date, to: Date) -> Int {
        let f = Self.sharedISO8601.string(from: from)
        let t = Self.sharedISO8601.string(from: to)
        return count(sql: "SELECT COUNT(*) FROM sessions WHERE entry_ts >= ? AND entry_ts < ? AND exit_ts IS NOT NULL", binds: [f, t])
    }

    /// Průměrná doba stání (s) pro uzavřené sessions v rozsahu. 0 pokud žádné.
    func avgParkingDurationSec(from: Date, to: Date) -> Int {
        writeLock.lock(); defer { writeLock.unlock() }
        let f = Self.sharedISO8601.string(from: from)
        let t = Self.sharedISO8601.string(from: to)
        let sql = "SELECT COALESCE(AVG(duration_sec), 0) FROM sessions WHERE entry_ts >= ? AND entry_ts < ? AND exit_ts IS NOT NULL"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, f, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, t, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_double(stmt, 0))
        }
        return 0
    }

    /// Celková doba stání (s) uzavřených sessions v rozsahu.
    func totalParkingDurationSec(from: Date, to: Date) -> Int {
        writeLock.lock(); defer { writeLock.unlock() }
        let f = Self.sharedISO8601.string(from: from)
        let t = Self.sharedISO8601.string(from: to)
        let sql = "SELECT COALESCE(SUM(duration_sec), 0) FROM sessions WHERE entry_ts >= ? AND entry_ts < ? AND exit_ts IS NOT NULL"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, f, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, t, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return 0
    }

    /// Historie detekcí s kombinovatelnými filtry: datumový rozsah, SPZ LIKE,
    /// kamera. Používá HISTORIE tab v UI. Vrací max `limit` nejnovějších.
    func queryDetections(fromDate: Date? = nil, toDate: Date? = nil,
                         plateQuery: String? = nil, camera: String? = nil,
                         limit: Int = 100) -> [RecentDetection] {
        writeLock.lock(); defer { writeLock.unlock() }
        var out: [RecentDetection] = []
        var clauses: [String] = []
        var binds: [String] = []
        if let f = fromDate {
            clauses.append("ts >= ?")
            binds.append(Self.sharedISO8601.string(from: f))
        }
        if let t = toDate {
            clauses.append("ts < ?")
            binds.append(Self.sharedISO8601.string(from: t))
        }
        if let q = plateQuery, !q.isEmpty {
            // ESCAPE \ pro LIKE — bez toho by user-vstup "5T2%" matchoval
            // wildcardy. `\` escape + explicit ESCAPE clause.
            clauses.append("REPLACE(UPPER(plate), ' ', '') LIKE ? ESCAPE '\\'")
            let norm = q.uppercased().replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            binds.append("%\(norm)%")
        }
        if let c = camera, !c.isEmpty {
            clauses.append("camera = ?")
            binds.append(c)
        }
        let whereSQL = clauses.isEmpty ? "" : "WHERE \(clauses.joined(separator: " AND "))"
        let sql = """
            SELECT id, ts, camera, plate, region, confidence, snapshot_path,
                   vehicle_type, vehicle_color
            FROM detections \(whereSQL)
            ORDER BY id DESC LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (i, b) in binds.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), b, -1, SQLITE_TRANSIENT)
        }
        sqlite3_bind_int(stmt, Int32(binds.count + 1), Int32(limit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let ts = stmt?.textOrNil(1),
                  let camName = stmt?.textOrNil(2),
                  let plate = stmt?.textOrNil(3) else { continue }
            let id = Int(sqlite3_column_int64(stmt, 0))
            let regionRaw = stmt?.textOrNil(4) ?? PlateRegion.unknown.rawValue
            let conf = Float(sqlite3_column_double(stmt, 5))
            let snapPath = stmt?.textOrNil(6)
            let vehicleType = stmt?.textOrNil(7)
            let vehicleColor = stmt?.textOrNil(8)
            let date = Self.sharedISO8601.date(from: ts) ?? Date()
            let region = PlateRegion(rawValue: regionRaw) ?? .unknown
            let img: NSImage? = snapPath.flatMap { NSImage(contentsOfFile: $0) }
            var r = RecentDetection(
                id: id, timestamp: date,
                cameraName: camName, plate: plate, region: region,
                confidence: conf, bbox: .zero, cropImage: img
            )
            r.snapshotPath = snapPath
            r.vehicleType = vehicleType
            r.vehicleColor = vehicleColor
            out.append(r)
        }
        return out
    }

    /// Top N SPZ dle počtu detekcí v rozsahu (descending).
    /// Vrací pole (plate, count).
    func topPlatesByCount(from: Date, to: Date, limit: Int = 5) -> [(plate: String, count: Int)] {
        writeLock.lock(); defer { writeLock.unlock() }
        var out: [(String, Int)] = []
        let f = Self.sharedISO8601.string(from: from)
        let t = Self.sharedISO8601.string(from: to)
        let sql = """
            SELECT plate, COUNT(*) AS c FROM detections
            WHERE ts >= ? AND ts < ?
            GROUP BY plate
            ORDER BY c DESC
            LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, f, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, t, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, Int32(limit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let plate = stmt?.textOrNil(0) else { continue }
            let c = Int(sqlite3_column_int64(stmt, 1))
            out.append((plate, c))
        }
        return out
    }

    /// Celkový počet parking sessions (všechny otevřené + uzavřené).
    func sessionsCountAll() -> Int {
        count(sql: "SELECT COUNT(*) FROM sessions", binds: [])
    }

    /// Nejdelší stání v rozsahu (sekundy). 0 pokud žádné sessions.
    func longestSessionSec(from: Date, to: Date) -> Int {
        writeLock.lock(); defer { writeLock.unlock() }
        let f = Self.sharedISO8601.string(from: from)
        let t = Self.sharedISO8601.string(from: to)
        let sql = "SELECT COALESCE(MAX(duration_sec), 0) FROM sessions WHERE entry_ts >= ? AND entry_ts < ? AND exit_ts IS NOT NULL"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, f, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, t, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return 0
    }

    /// Timestamp posledního vjezdu (sessions.entry_ts DESC LIMIT 1). Nil pokud žádné.
    func lastSessionEntry() -> Date? {
        writeLock.lock(); defer { writeLock.unlock() }
        let sql = "SELECT entry_ts FROM sessions ORDER BY entry_ts DESC LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return stmt?.textOrNil(0).flatMap { Self.sharedISO8601.date(from: $0) }
        }
        return nil
    }

    /// Top N SPZ dle počtu reálných otevření brány v rozsahu (= počet sessions,
    /// což odpovídá počtu úspěšných vjezdů whitelisted SPZ). Vrací (plate, count).
    func topPlatesByGateOpenings(from: Date, to: Date, limit: Int = 5) -> [(plate: String, count: Int)] {
        writeLock.lock(); defer { writeLock.unlock() }
        var out: [(String, Int)] = []
        let f = Self.sharedISO8601.string(from: from)
        let t = Self.sharedISO8601.string(from: to)
        let sql = """
            SELECT plate, COUNT(*) AS c FROM sessions
            WHERE entry_ts >= ? AND entry_ts < ?
            GROUP BY plate
            ORDER BY c DESC
            LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, f, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, t, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, Int32(limit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let plate = stmt?.textOrNil(0) else { continue }
            let c = Int(sqlite3_column_int64(stmt, 1))
            out.append((plate, c))
        }
        return out
    }

    /// Nejaktivnější hodina dne (0–23) podle počtu detekcí za posledních 30 dní.
    /// Vrací tuple (hour, count). Pokud nic, vrátí (0, 0).
    func peakHour() -> (hour: Int, count: Int) {
        writeLock.lock(); defer { writeLock.unlock() }
        let sql = """
            SELECT CAST(strftime('%H', ts, 'localtime') AS INTEGER) AS h, COUNT(*) AS c
            FROM detections
            WHERE ts >= datetime('now', '-30 days')
            GROUP BY h ORDER BY c DESC LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (0, 0) }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return (Int(sqlite3_column_int(stmt, 0)), Int(sqlite3_column_int64(stmt, 1)))
        }
        return (0, 0)
    }

    // MARK: - CSV export

    /// Exportuje všechny detekce do CSV souboru. Sloupce:
    // CSV export (exportDetectionsCSV / exportSessionsCSV / csvEscape) extracted to Store+Export.swift.

    func countToday() -> Int {
        // LOCAL day range (user-visible "today"), převedeno na UTC ISO stringy
        // pro comparison s `ts` sloupcem (který je uložen v UTC přes .withInternetDateTime).
        // Dřív `prefix(10)` UTC stringu dával UTC-day, takže po půlnoci UTC (= 1–2 v noci lokálně)
        // se counter resetoval brzy. Teď respect Calendar.current.timeZone.
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: Date())
        guard let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) else {
            return 0
        }
        let from = Self.sharedISO8601.string(from: startOfDay)
        let to = Self.sharedISO8601.string(from: endOfDay)
        return count(sql: "SELECT COUNT(*) FROM detections WHERE ts >= ? AND ts < ?",
                     binds: [from, to])
    }

    /// Full-text-ish search — LIKE %query% přes sloupec `plate`. Vrací max `limit`
    /// nejnovějších záznamů. Použito v UI Najít tabu. `query` bez uvozovek —
    /// použit parametrizovaný bind (žádný SQL injection).
    // searchDetections + detectionCount + detectionCountsByCamera extracted to Store+Search.swift.

    // NL Query helpers (querySingleInt/Double/String + queryRows) extracted to Store+NLQuery.swift.
    /// Ignoruje NULL (commits before VehicleClassifier enabled).
    // VehicleStats / confidence histogram extracted to Store+VehicleStats.swift.
    /// WAL checkpoint — vol při shutdown nebo periodicky aby se .db-wal nezvětšoval do nekonečna.
    func checkpoint() {
        writeLock.lock(); defer { writeLock.unlock() }
        sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
    }
}

// OpaquePointer extension + SQLITE_TRANSIENT extracted to SQLiteHelpers.swift.
