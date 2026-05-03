import Foundation
import CoreGraphics
import CoreVideo
import CoreImage
import SQLite3

/// **Snapshot regression baseline** (NE accuracy measurement).
///
/// Iteruje uložené `*.heic` snapshoty (commits ze Store.persist), re-runa
/// `PlateOCR.recognize` a porovná predikci s commit-time plate textem z DB.
/// Effective truth je user-poskytnuté override (mark-wrong v UI), pokud
/// existuje, jinak DB plate. Match types:
///
///  - `.baseline` — predicted == dbPlate (no regression, no info)
///  - `.regression` — predicted ≠ dbPlate AND no override → suspect regression
///  - `.fixed` — override exists AND predicted == override (lepší než baseline)
///  - `.stillWrong` — override exists AND predicted ≠ override (pořád miss)
///  - `.noDetect` — OCR vrátil nic
///
/// **Honest framing:** DB plate text je „commit-time pipeline tip", ne ground
/// truth. Tier 1 tedy neměří „accuracy", měří „rozbil jsem OCR na cropu, který
/// dřív prošel". Ground truth measurement je úkol Tier 2 (recordings + manual
/// annotation v Phase C).
///
/// **Threading:** kompletně nonisolated. Žádný @MainActor, žádný AppState
/// přístup. Default serial concurrency (1) — Vision OCR využívá ANE, paralelní
/// invoke topí M4 jako benchmark což je nežádoucí pro overnight regression
/// testing. User může zvýšit `--concurrency N`.
enum SnapshotReplay {

    // MARK: - Public API

    static func runAll(snapshotsDir: URL,
                       dbPath: URL,
                       overridesPath: URL? = nil,
                       ocrParams: OCRParams = .default,
                       concurrency: Int = 1) -> [SnapshotReplayResult] {
        // 1) Load DB plate index (snapshot_path → plate). Raw sqlite3 — bypass
        //    Store.shared protože nechceme retention timer / JSONL handle init.
        let dbIndex = loadDbIndex(dbPath: dbPath)
        guard !dbIndex.isEmpty else {
            FileHandle.safeStderrWrite(
                "[SnapshotReplay] DB index empty (no detections rows or DB unreachable)\n"
                    .data(using: .utf8)!)
            return []
        }

        // 2) Load overrides (mark-wrong corrections).
        let overrides: [String: String] = overridesPath.map { url in
            ReplayOverrideStore.loadEffective(from: url)
        } ?? ReplayOverrideStore.loadEffective()

        // 3) List snapshot HEICs (ignore .raw.heic sidecars — preprocessed
        //    snapshot is the canonical truth carrier).
        let fm = FileManager.default
        guard let allFiles = try? fm.contentsOfDirectory(at: snapshotsDir,
                                                          includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles])
        else { return [] }
        let snapshots = allFiles
            .filter { $0.pathExtension.lowercased() == "heic" }
            .filter { !$0.lastPathComponent.hasSuffix(".raw.heic") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        // 4) Run replay (serial or parallel based on concurrency).
        let conc = max(1, min(concurrency, 8))
        if conc == 1 {
            var out: [SnapshotReplayResult] = []
            out.reserveCapacity(snapshots.count)
            for url in snapshots {
                autoreleasepool {
                    if let r = replayOne(url: url, dbIndex: dbIndex,
                                         overrides: overrides, ocrParams: ocrParams) {
                        out.append(r)
                    }
                }
            }
            return out
        } else {
            // Parallel — `concurrentPerform` blokuje až dojede; výsledky se
            // sbírají do Array s lock.
            let lock = NSLock()
            var out: [SnapshotReplayResult] = []
            out.reserveCapacity(snapshots.count)
            DispatchQueue.concurrentPerform(iterations: snapshots.count) { idx in
                autoreleasepool {
                    if let r = replayOne(url: snapshots[idx], dbIndex: dbIndex,
                                         overrides: overrides, ocrParams: ocrParams) {
                        lock.lock()
                        out.append(r)
                        lock.unlock()
                    }
                }
            }
            return out.sorted { $0.snapshotPath < $1.snapshotPath }
        }
    }

    static func summarize(_ results: [SnapshotReplayResult],
                          gitHash: String,
                          ocrParams: OCRParams) -> ReplayMetrics {
        let total = results.count
        let baseline = results.filter { $0.matchType == .baseline }.count
        let regression = results.filter { $0.matchType == .regression }.count
        let fixed = results.filter { $0.matchType == .fixed }.count
        let stillWrong = results.filter { $0.matchType == .stillWrong }.count
        let noDetect = results.filter { $0.matchType == .noDetect }.count

        // p95 latency over all results (sorted nth ≈ p95).
        let latencies = results.map { $0.inferenceMs }.sorted()
        let p95: Double = {
            guard !latencies.isEmpty else { return 0 }
            let idx = min(latencies.count - 1, Int(Double(latencies.count) * 0.95))
            return latencies[idx]
        }()

        return ReplayMetrics(
            total: total, baseline: baseline, regression: regression,
            fixed: fixed, stillWrong: stillWrong, noDetect: noDetect,
            p95LatencyMs: p95, timestamp: Date(),
            gitHash: gitHash, ocrParams: ocrParams
        )
    }

    // MARK: - Pure classification (testovatelné isolated)

    /// Pure function — vstup predicted/dbPlate/override, výstup MatchType.
    /// Žádné side effects, ideální pro unit tests.
    static func classify(predicted: String?, dbPlate: String, override: String?) -> MatchType {
        guard let predicted else { return .noDetect }
        let p = predicted.uppercased()
        let db = dbPlate.uppercased()
        if let ovr = override?.uppercased() {
            return p == ovr ? .fixed : .stillWrong
        }
        return p == db ? .baseline : .regression
    }

    /// Levenshtein distance — pro `charErrors` v top-regressions report.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let aC = Array(a.uppercased()), bC = Array(b.uppercased())
        let m = aC.count, n = bC.count
        if m == 0 { return n }
        if n == 0 { return m }
        var prev = [Int](0...n)
        var curr = [Int](repeating: 0, count: n + 1)
        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = aC[i-1] == bC[j-1] ? 0 : 1
                curr[j] = Swift.min(prev[j] + 1, curr[j-1] + 1, prev[j-1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[n]
    }

    // MARK: - Internal

    private static func replayOne(url: URL,
                                  dbIndex: [String: String],
                                  overrides: [String: String],
                                  ocrParams: OCRParams) -> SnapshotReplayResult? {
        // Find DB plate via tolerant path matching.
        let dbPlate = lookupDbPlate(snapshotURL: url, dbIndex: dbIndex)
        let ovr = ReplayOverrideStore.effectiveOverride(
            for: url.path, in: overrides
        )

        // Skip pokud DB plate neznámá A user nemá override — replay nemá
        // žádnou referenci k porovnání, výsledek by byl beze smyslu.
        guard dbPlate != nil || ovr != nil else { return nil }

        // Load HEIC → CVPixelBuffer (BGRA).
        guard let pb = FrozenFrame.loadPixelBuffer(from: url) else {
            return SnapshotReplayResult(
                snapshotPath: url.path, dbPlate: dbPlate ?? "?",
                userOverridePlate: ovr, predictedPlate: nil,
                charErrors: 0, matchType: .noDetect,
                inferenceMs: 0, confidence: nil
            )
        }

        // Run OCR. Snapshot je už crop → no ROI, no rotation, no perspective.
        let t0 = Date()
        let readings = PlateOCR.recognize(
            in: pb, roiInPixels: nil, rotationRadians: 0,
            perspective: nil, detectionQuad: nil, exclusionMasks: [],
            perspectiveCalibration: nil, customWords: [],
            minObsHeightFraction: ocrParams.minObsHeightFraction,
            fastMode: ocrParams.fastMode,
            dualPass: ocrParams.dualPass,
            enhancedRetryEnabled: ocrParams.enhancedRetryEnabled,
            enhancedRetryThreshold: ocrParams.enhancedRetryThreshold,
            maxRetryBoxes: ocrParams.maxRetryBoxes
        )
        let dtMs = Date().timeIntervalSince(t0) * 1000.0

        // Pick OCR reading „best match" k effective truth (dbPlate / override).
        // **Důvod:** snapshoty obsahují celý ROI workspace (plate + okolní text
        // jako banner). Vision generic text-finder vrací VÍC textů; pipeline
        // při commit-time používá Tracker fuzzy + plate format filter pro
        // selection. Replay engine tu kontext nemá → best-match k DB plate
        // je nejbližší proxy. Pokud OCR plate vůbec nečetl, regression je real.
        let effectiveTruth = ovr ?? dbPlate ?? ""
        let predicted: String?
        let conf: Float?
        if readings.isEmpty {
            predicted = nil
            conf = nil
        } else if !effectiveTruth.isEmpty {
            // Pick min-Levenshtein match (best candidate). Tie-break by confidence.
            let scored = readings.map { reading -> (text: String, conf: Float, dist: Int) in
                let normText = reading.text.replacingOccurrences(of: " ", with: "")
                return (normText, reading.confidence, levenshtein(normText, effectiveTruth))
            }
            let best = scored.min { lhs, rhs in
                if lhs.dist != rhs.dist { return lhs.dist < rhs.dist }
                return lhs.conf > rhs.conf  // tie-break by higher confidence
            }
            predicted = best?.text
            conf = best?.conf
        } else {
            // Bez truth → fallback na max-confidence.
            let top = readings.max(by: { $0.confidence < $1.confidence })
            predicted = top?.text.replacingOccurrences(of: " ", with: "")
            conf = top?.confidence
        }

        let charErrors = predicted.map { levenshtein($0, effectiveTruth) } ?? effectiveTruth.count
        let matchType = classify(predicted: predicted,
                                 dbPlate: dbPlate ?? "",
                                 override: ovr)

        return SnapshotReplayResult(
            snapshotPath: url.path,
            dbPlate: dbPlate ?? "?",
            userOverridePlate: ovr,
            predictedPlate: predicted,
            charErrors: charErrors,
            matchType: matchType,
            inferenceMs: dtMs,
            confidence: conf
        )
    }

    /// Tolerant DB lookup: standardized absolute → lastPathComponent →
    /// lastPathComponent bez `.raw.heic` suffix.
    static func lookupDbPlate(snapshotURL: URL,
                              dbIndex: [String: String]) -> String? {
        let std = snapshotURL.standardizedFileURL.path
        if let hit = dbIndex[std] { return hit }
        let basename = (std as NSString).lastPathComponent
        for (key, value) in dbIndex where (key as NSString).lastPathComponent == basename {
            return value
        }
        let stripped = basename.replacingOccurrences(of: ".raw.heic", with: ".heic")
        if stripped != basename {
            for (key, value) in dbIndex where (key as NSString).lastPathComponent == stripped {
                return value
            }
        }
        return nil
    }

    /// Načte snapshot_path → plate dict z `detections` tabulky. Raw sqlite3
    /// (žádný Store.shared init).
    static func loadDbIndex(dbPath: URL) -> [String: String] {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath.path, &db) == SQLITE_OK, let db else { return [:] }
        defer { sqlite3_close(db) }

        let sql = "SELECT snapshot_path, plate FROM detections WHERE snapshot_path IS NOT NULL"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }

        var index: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let pathPtr = sqlite3_column_text(stmt, 0),
                  let platePtr = sqlite3_column_text(stmt, 1) else { continue }
            let path = String(cString: pathPtr)
            let plate = String(cString: platePtr)
            // Standardize key — same canonical form jako lookupDbPlate.
            let std = URL(fileURLWithPath: path).standardizedFileURL.path
            index[std] = plate
        }
        return index
    }
}

// MARK: - Types

struct SnapshotReplayResult: Codable {
    let snapshotPath: String
    let dbPlate: String                 // commit-time pipeline tip (NOT ground truth)
    let userOverridePlate: String?      // user-supplied true text (mark-wrong)
    let predictedPlate: String?         // current OCR top result
    let charErrors: Int                 // Levenshtein distance vs effective truth
    let matchType: MatchType
    let inferenceMs: Double
    let confidence: Float?
}

enum MatchType: String, Codable, Equatable {
    case baseline       // predicted == dbPlate (no regression, no info)
    case regression     // predicted ≠ dbPlate AND no override → suspect
    case fixed          // override exists AND predicted == override (better)
    case stillWrong     // override exists AND predicted ≠ override
    case noDetect       // OCR returned nothing
}

struct OCRParams: Codable, Equatable {
    var minObsHeightFraction: CGFloat = 0.025
    var dualPass: Bool = false
    var fastMode: Bool = false
    var enhancedRetryEnabled: Bool = true
    var enhancedRetryThreshold: Float = 0.95
    var maxRetryBoxes: Int = 2
    static let `default` = OCRParams()
}

struct ReplayMetrics: Codable {
    let total, baseline, regression, fixed, stillWrong, noDetect: Int
    let p95LatencyMs: Double
    let timestamp: Date
    let gitHash: String
    let ocrParams: OCRParams
}
