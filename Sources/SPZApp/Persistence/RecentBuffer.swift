import Foundation
import AppKit

/// In-memory ring buffer pro nedávné committed detekce. Zero disk, zero DB.
struct RecentDetection: Identifiable, Equatable {
    let id: Int
    var timestamp: Date
    var cameraName: String
    let plate: String
    let region: PlateRegion
    var confidence: Float
    let bbox: CGRect       // v source-frame souřadnicích
    var cropImage: NSImage? // ~30 KB JPEG → NSImage. Nullable pokud crop selhal.
    /// Cesta k uloženému originálnímu HEIC snapshotu na disku. Klik na thumbnail
    /// v RecentRow otevře tento soubor v Preview. Deterministicky odvozeno z
    /// `timestamp + cameraName + plate` (viz `Store.snapshotPath(for:)`).
    var snapshotPath: String? = nil
    /// Kolikrát byla tato SPZ opakovaně detekována během posledních `mergeWindowSec`.
    /// Místo přidávání nových řádků se tento count inkrementuje (auto stojí v záběru
    /// před závorou apod.).
    var count: Int = 1
    /// Fáze 2.4 VIGI vehicle attribute enrichment — nil pokud event nenapadl v window.
    var vehicleType: String? = nil
    var vehicleColor: String? = nil
    var vehicleDirection: String? = nil
}

/// `@MainActor`-only přístup — `add`/`makeId` se volají výhradně z commit() v pipeline
/// která je MainActor-isolated. NSLock byl redundant overhead (~100 ns × 2 per commit).
@MainActor
final class RecentBuffer: ObservableObject {
    @Published private(set) var items: [RecentDetection] = []
    private let capacity: Int
    private var nextId: Int = 1

    init(capacity: Int) {
        self.capacity = capacity
        self.items.reserveCapacity(capacity)
    }

    /// Okno, ve kterém se opakované detekce stejné SPZ (stejná plate + kamera)
    /// sloučí do existujícího řádku → inkrementuje `count` + update timestamp.
    /// 5 min pokrývá scénář „auto stojí před závorou a je čteno opakovaně".
    private let mergeWindowSec: TimeInterval = 300

    /// Short window (5 s) pro **substring merge** — scenário kdy Vision nepřečte
    /// plate kompletně (např. EL067BJ vs 067BJ, ELO67 vs EL067BJ). Když nový rec
    /// je v Lev-1 nebo sub/superstring existujícího recentu (±5 s), považujeme ho
    /// za stejný průjezd a jen inkrementujeme count. Chráníme před 4-commit spam
    /// z jednoho auta s nekonzistentním OCR na různých framech.
    private let substringMergeSec: TimeInterval = 5

    func add(_ rec: RecentDetection) {
        // Exact plate + camera + ≤ 5 min window → merge (existing behavior)
        if let idx = items.firstIndex(where: {
            $0.plate == rec.plate && $0.cameraName == rec.cameraName &&
            rec.timestamp.timeIntervalSince($0.timestamp) < mergeWindowSec
        }) {
            var merged = items[idx]
            merged.count += 1
            merged.timestamp = rec.timestamp
            merged.confidence = max(merged.confidence, rec.confidence)
            if merged.cropImage == nil, let newCrop = rec.cropImage {
                merged.cropImage = newCrop
            }
            // Prefer newer vehicle classification — pozdější detekce má typicky
            // lepší color sample (auto blíže, lepší úhel) než první far detekce.
            if rec.vehicleType != nil { merged.vehicleType = rec.vehicleType }
            if rec.vehicleColor != nil { merged.vehicleColor = rec.vehicleColor }
            items.remove(at: idx)
            items.insert(merged, at: 0)
            return
        }
        // Substring/Lev-1 merge within 5 s window — same camera, same probable
        // vehicle, just inconsistent OCR fragments. Prefer LONGER/VALIDATED plate.
        if let idx = items.firstIndex(where: { existing in
            guard existing.cameraName == rec.cameraName,
                  rec.timestamp.timeIntervalSince(existing.timestamp) < substringMergeSec
            else { return false }
            let a = existing.plate, b = rec.plate
            if a.contains(b) || b.contains(a) { return true }
            // Levenshtein ≤ 1 for same-length, or ≤ 2 (short insert/delete) for
            // 1-2 char length difference.
            if abs(a.count - b.count) <= 2 {
                return Self.levenshteinLE2(a, b)
            }
            return false
        }) {
            var merged = items[idx]
            merged.count += 1
            merged.timestamp = rec.timestamp
            merged.confidence = max(merged.confidence, rec.confidence)
            // Pokud nový rec má delší plate text, považujeme ho za přesnější
            // (Vision občas ukousne suffix/prefix) — upgrade existing record.
            if rec.plate.count > merged.plate.count {
                // replace plate + region (může se změnit CZ* → czElectric)
                items.remove(at: idx)
                var upgraded = rec
                upgraded.count = merged.count
                upgraded.timestamp = rec.timestamp
                upgraded.confidence = max(merged.confidence, rec.confidence)
                if upgraded.cropImage == nil { upgraded.cropImage = merged.cropImage }
                if upgraded.vehicleType == nil { upgraded.vehicleType = merged.vehicleType }
                if upgraded.vehicleColor == nil { upgraded.vehicleColor = merged.vehicleColor }
                items.insert(upgraded, at: 0)
                return
            }
            if merged.cropImage == nil, let newCrop = rec.cropImage {
                merged.cropImage = newCrop
            }
            if rec.vehicleType != nil { merged.vehicleType = rec.vehicleType }
            if rec.vehicleColor != nil { merged.vehicleColor = rec.vehicleColor }
            items.remove(at: idx)
            items.insert(merged, at: 0)
            return
        }
        items.insert(rec, at: 0)
        if items.count > capacity {
            items.removeLast(items.count - capacity)
        }
    }

    /// Levenshtein distance ≤ 2 check — rychlý pro short strings (plate max 8 char).
    /// Returns true pokud a a b jsou ≤ 2 edit distance apart.
    static func levenshteinLE2(_ a: String, _ b: String) -> Bool {
        let ca = Array(a), cb = Array(b)
        if abs(ca.count - cb.count) > 2 { return false }
        let n = ca.count, m = cb.count
        var prev = [Int](0...m)
        var curr = [Int](repeating: 0, count: m + 1)
        for i in 1...n {
            curr[0] = i
            var rowMin = curr[0]
            for j in 1...m {
                let cost = ca[i-1] == cb[j-1] ? 0 : 1
                curr[j] = Swift.min(prev[j] + 1, curr[j-1] + 1, prev[j-1] + cost)
                if curr[j] < rowMin { rowMin = curr[j] }
            }
            if rowMin > 2 { return false }  // early exit
            swap(&prev, &curr)
        }
        return prev[m] <= 2
    }

    func makeId() -> Int {
        let id = nextId; nextId += 1
        return id
    }

    /// Naplní buffer z DB query (newest-first order) — volá se z `AppState.init`
    /// aby po restartu appky nebyla sekce Průjezdy prázdná. Obcházíme merge logic
    /// (DB rows už jsou mergované z původního commit okna), jen truncate na capacity.
    func seed(_ recs: [RecentDetection]) {
        items = Array(recs.prefix(capacity))
        nextId = (recs.map { $0.id }.max() ?? 0) + 1
    }
}
