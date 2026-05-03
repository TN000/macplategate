import Foundation
import CoreGraphics
import CoreVideo
import CoreImage

/// Per-track buffer OCR čtení pro multi-frame voting.
/// **Neobsahuje CVPixelBuffer** — observations se akumulují v `track.observations`
/// a retain pb by znamenal N pool-slot retention per track (3-5 obs × 1 pb → pool
/// exhaust při multi-tracks). Místo toho se pixelBuffer předává do `add()` jako
/// externí parameter, tracker si hned snapshotuje CGImage (heap, pool-indep).
struct PlateObservation {
    let text: String
    let confidence: Float
    let frameIdx: Int
    let bbox: CGRect        // source frame (axis-aligned po inverse rotaci)
    let workBox: CGRect     // rotated crop pixel space (co Vision viděl)
    let workSize: CGSize    // dimenze rotated crop → commit thumbnail reconstruction
    let region: PlateRegion
    let origin: PlateOCRReadingOrigin
    let isStrictValidCz: Bool
    /// Sekundární engine reading pro tutéž bbox (pokud secondary fired).
    /// Tracker `clusterBestScored` počítá secondary jako další hlas v cluster
    /// votingu — implementace "majority wins" napříč Vision + Secondary.
    /// Nil pokud secondary nebyl volán nebo vrátil prázdný / příliš krátký text.
    let secondaryText: String?
    let secondaryConfidence: Float
    let toneMeta: ToneMeta?

    init(text: String,
         confidence: Float,
         frameIdx: Int,
         bbox: CGRect,
         workBox: CGRect,
         workSize: CGSize,
         region: PlateRegion,
         origin: PlateOCRReadingOrigin = .passOneRaw,
         isStrictValidCz: Bool = false,
         secondaryText: String? = nil,
         secondaryConfidence: Float = 1.0,
         toneMeta: ToneMeta? = nil) {
        self.text = text
        self.confidence = confidence
        self.frameIdx = frameIdx
        self.bbox = bbox
        self.workBox = workBox
        self.workSize = workSize
        self.region = region
        self.origin = origin
        self.isStrictValidCz = isStrictValidCz
        self.secondaryText = secondaryText
        self.secondaryConfidence = secondaryConfidence
        self.toneMeta = toneMeta
    }
}

struct OriginVoteConfig: Equatable {
    var enhancedVoteWeight: Float
    var baseVoteWeightWhenEnhancedOverlap: Float
    var crossValidatedVoteWeight: Float

    static let neutral = OriginVoteConfig(enhancedVoteWeight: 1.0,
                                          baseVoteWeightWhenEnhancedOverlap: 1.0,
                                          crossValidatedVoteWeight: 1.0)

    init(enhancedVoteWeight: Float,
         baseVoteWeightWhenEnhancedOverlap: Float,
         crossValidatedVoteWeight: Float = 2.0) {
        self.enhancedVoteWeight = enhancedVoteWeight
        self.baseVoteWeightWhenEnhancedOverlap = baseVoteWeightWhenEnhancedOverlap
        self.crossValidatedVoteWeight = crossValidatedVoteWeight
    }
}

final class PlateTrack {
    let id: Int
    var lastBbox: CGRect
    /// Aktuální workBox/Size (posledního matched observation) — pro live overlay
    /// bez prodlevy smoothing filtru.
    var lastWorkBox: CGRect = .zero
    var lastWorkSize: CGSize = .zero
    var lastSeenFrame: Int
    var hits: Int = 0
    var observations: [PlateObservation] = []
    var bestBbox: CGRect
    var bestWorkBox: CGRect = .zero
    var bestWorkSize: CGSize = .zero
    var bestScore: Float = 0
    /// Heap-backed CGImage ze snímku s best observation — commit() ho použije místo
    /// `lastPixelBuffer` (frame v okamžiku finalizace), aby crop odpovídal nejlepšímu
    /// hlasování. Dřív tady bylo `bestPixelBuffer: CVPixelBuffer?`, ale retain pool
    /// bufferu dělal 7. konzumenta poolu → pool exhausted při noise burstu → watchdog
    /// reconnect. CGImage je heap-allocated, nezabírá pool slot; render je ~3 ms GPU.
    var bestCGImage: CGImage?
    /// Staged snapshot pro ještě-neproven track (hits < minHitsToCommit). Promote
    /// do `bestCGImage` až track překročí noise gate (hits ≥ 2). Bez staging by
    /// rychlá auta s highest-conf 1st obs ztratila best snapshot, protože retention
    /// trigger `hits≥2` vyžaduje druhou obs — a `obs.confidence > bestScore` druhý
    /// krok obvykle nesplní (1st obs byla peak, ostatní pokles).
    var pendingBestCGImage: CGImage?

    /// Parallel fields pro RAW (pre-preprocess) workspace jako CIImage — LAZY.
    /// CGImage render se udělá až v PlatePipeline.commit() (jen pro skutečné
    /// commit události). Šetří GPU per-tick cost.
    var bestRawCIImage: CIImage?
    var pendingBestRawCIImage: CIImage?

    /// Plate stacking — ring buffer posledních N snapshotů (CGImage + workBox + conf)
    /// pro commit-time temporal composite. Multi-frame stacking zprůměruje sensor
    /// noise (~√N SNR boost) a motion blur → OCR na composite má vyšší stabilitu
    /// v shadow / IR / blurred conditions. Capped na 4 frames aby heap nebyl balónový
    /// (4 × ~0.5 MB CGImage per track). Viz `PlatePipeline.commit` stack-usage.
    struct StackFrame {
        let cgImage: CGImage
        let workBox: CGRect       // v workspace po detectionQuad crop
        let workSize: CGSize      // pro remap
        let confidence: Float
    }
    var stackFrames: [StackFrame] = []
    private static let stackCapacity: Int = 4
    var firstSeenFrame: Int
    var committed: Bool = false
    /// Timestamp force-commitu — po `recommitAfterSec` sekundách se `committed`
    /// flag resetuje, aby track mohl re-commit stejnou plate ze spojitého záběru.
    var committedAt: Date?
    /// Winner text v okamžiku commitu — po commitu vyžadujeme, aby nové matched
    /// observations měly text L≤1 od tohoto winner. Jinak IoU match absorboval
    /// sousední Vision misdetekce (reflexy, cedulky, tag auta) do etablovaného
    /// tracku → live overlay skákal mezi plate a okolním textem.
    var committedText: String = ""
    /// 1-shot flag: consensus-fail diagnostika se logne jen 1× per track
    /// (ne každý tick kde hits zůstává na force-commit prahu).
    var consensusFailLogged: Bool = false
    /// 1-shot flag: area-plateau diagnostika (totéž — nelogovat každý tick
    /// kde plate area pořád roste, jen první tick toho stavu).
    var areaPlateauLogged: Bool = false
    /// 1-shot flag: small-plate skip — zaplnilo log při dlouho-malých plates.
    var smallPlateLogged: Bool = false
    /// Kolikrát tracker vědomě pozdržel mature track, aby získal větší/stabilnější
    /// observation. Cap v `decideCommitVerdict` brání nekonečnému čekání.
    var deferCount: Int = 0
    /// Která Tracker commit cesta track finalizovala (consensus / wl-override /
    /// 2hit-valid / fast-single). Populated v `IoUTracker.update` přes `CommitVerdict`,
    /// čte Pipeline pro audit log. Nil pro tracky které nikdy nebyly committed.
    var commitPath: String?
    var originVoteConfig: OriginVoteConfig = .neutral

    init(id: Int, bbox: CGRect, frameIdx: Int) {
        self.id = id
        self.lastBbox = bbox
        self.bestBbox = bbox
        self.lastSeenFrame = frameIdx
        self.firstSeenFrame = frameIdx
    }

    /// `workspaceImage` je CGImage už rendrovaný pro Vision (post-ROI, post-rotate,
    /// post-perspective, post-detectionQuad). `workBox` v PlateObservation je coord
    /// v tomto workspace — crop z workspaceImage je deterministicky správně bez
    /// re-transformace. Předáváno jako arg (ne přes observations array), aby
    /// observations array nedržela N retained bitmaps.
    func add(_ obs: PlateObservation, workspaceImage: CGImage? = nil, rawWorkspaceImage: CIImage? = nil) {
        lastBbox = obs.bbox
        lastWorkBox = obs.workBox
        lastWorkSize = obs.workSize
        lastSeenFrame = obs.frameIdx
        hits += 1

        // Tie-break by plate size: conf rychle saturuje na 1.00, takže pure
        // `conf > bestScore` by udržel první high-conf frame (auto daleko) a
        // nepustil pozdější lepší záběr (auto bližší, plate větší). Když
        // |Δconf| < 0.05, prefer větší workBox area = plate blíž kamery.
        let obsArea = obs.workBox.width * obs.workBox.height
        let bestArea = bestWorkBox.width * bestWorkBox.height
        let confDelta = obs.confidence - bestScore
        let isBetter: Bool = {
            if obsArea >= bestArea * 1.15 { return true }    // větší plate = lepší snapshot
            if obsArea >= bestArea * 1.05,
               obs.confidence >= bestScore - 0.15 { return true }
            if confDelta > 0.05 { return true }              // výrazně lepší confidence
            if confDelta < -0.05 { return false }             // výrazně horší
            return false
        }()
        if isBetter {
            // bestScore MUSÍ být aktuální vítězná obs conf (ne max(old, new)).
            // Při area tie-break (větší plate, mírně nižší conf) by `max` udržel
            // staré vyšší skóre a další obs by se porovnávala proti špatnému
            // baseline → incorrectly reject mírně lepší match.
            bestScore = obs.confidence
            bestBbox = obs.bbox
            bestWorkBox = obs.workBox
            bestWorkSize = obs.workSize
            // Snapshot do pending — promoted do `bestCGImage` až track překročí gate.
            pendingBestCGImage = workspaceImage
            pendingBestRawCIImage = rawWorkspaceImage
        }
        // Noise gate: promote pending → best jen když track překročil minHitsToCommit.
        if hits >= 2, pendingBestCGImage != nil {
            bestCGImage = pendingBestCGImage
            bestRawCIImage = pendingBestRawCIImage
        }

        // Stacking buffer — udržuj poslední N workspace snapshotů per track pro
        // composite OCR v commit. Ukládáme pouze pokud hits >= 2 (gate shodný
        // s bestCGImage), noise-free tracks. Při overflow drop lowest-conf frame.
        if hits >= 2, let cg = workspaceImage,
           obs.workSize.width > 0, obs.workSize.height > 0 {
            let frame = StackFrame(cgImage: cg, workBox: obs.workBox,
                                   workSize: obs.workSize, confidence: obs.confidence)
            stackFrames.append(frame)
            if stackFrames.count > PlateTrack.stackCapacity {
                if let dropIdx = stackFrames.indices.min(by: {
                    stackFrames[$0].confidence < stackFrames[$1].confidence
                }) {
                    stackFrames.remove(at: dropIdx)
                }
            }
        }

        if !committed {
            observations.append(obs)
        }
    }

    /// Levenshtein ≤ 1 mezi 2 stringy (O(n) optimalizace, ne full DP).
    static func isL1(_ a: String, _ b: String) -> Bool {
        let aC = Array(a), bC = Array(b)
        let la = aC.count, lb = bC.count
        if abs(la - lb) > 1 { return false }
        if la == lb {
            var diff = 0
            for i in 0..<la where aC[i] != bC[i] { diff += 1; if diff > 1 { return false } }
            return true  // 0 or 1 substitution
        }
        let (short, long) = la < lb ? (aC, bC) : (bC, aC)
        var i = 0, j = 0, skipped = false
        while i < short.count && j < long.count {
            if short[i] == long[j] { i += 1; j += 1 }
            else { if skipped { return false }; skipped = true; j += 1 }
        }
        return true
    }

    /// Per-text scored candidate uvnitř clusteru. `bestText()` reuse
    /// confSum / count bez O(n) recompute.
    fileprivate struct ScoredText {
        let text: String
        var weight: Float        // sum of observation vote weights (quality)
        var count: Int           // number of observations matching text
        var conf: Float          // max raw OCR confidence napříč obs
        var confSum: Float       // sum raw OCR conf — pro mean výpočet v bestText
        var region: PlateRegion
        var latestFrame: Int     // pro recency tie-break
        var maxArea: CGFloat     // pro size tie-break
        var hasEnhancedValidCz: Bool
    }

    /// Fuzzy cluster text observací — OCR produkuje varianty jako "WOB ZK 295" /
    /// "WOBG ZK 295" / "WOBS ZK 295" přes frame-to-frame flag emblem misread.
    /// Všechny jsou L-1 od sebe → cluster 1 reprezentant + total count.
    /// Returns (winnerScore, totalCountInCluster). bestText() pak score reuse
    /// pro displayConf místo druhého passu nad observations.
    ///
    /// **Cross-engine majority vote:** sekundární engine text (`obs.secondaryText`)
    /// se přidává do cluster votingu jako další hlas. Pro Vision misread case
    /// (Vision 3× '4CD3456', secondary 5× '2CD3456') cluster `2CD3456` vyhraje
    /// frequency-vote — princip "ten kdo má častěji pravdu vyhrává".
    fileprivate func clusterBestScored() -> (winner: ScoredText, clusterCount: Int)? {
        guard !observations.isEmpty else { return nil }
        // Build vote bag: každá observation přispívá Vision text + (volitelně)
        // Secondary text pokud je odlišný a plausible. Záznamy nemají index do
        // observations (synthetic), ale zachovávají potřebné fields.
        struct Vote {
            let text: String
            let confidence: Float
            let frameIdx: Int
            let workBoxArea: CGFloat
            let region: PlateRegion
            let origin: PlateOCRReadingOrigin
            let isStrictValidCz: Bool
            let isSecondary: Bool
            let observationIdx: Int   // pointer do observations pro ostatní access
        }
        var votes: [Vote] = []
        votes.reserveCapacity(observations.count * 2)
        for (idx, obs) in observations.enumerated() {
            let area = obs.workBox.width * obs.workBox.height
            // Primary: Vision text
            votes.append(Vote(
                text: obs.text, confidence: obs.confidence,
                frameIdx: obs.frameIdx, workBoxArea: area,
                region: obs.region, origin: obs.origin,
                isStrictValidCz: obs.isStrictValidCz,
                isSecondary: false, observationIdx: idx))
            // Secondary: pokud secondary engine vrátil odlišný plausible text
            // (canonicalize ≥ 5 chars), přidat jako další vote.
            if let secText = obs.secondaryText {
                let cV = obs.text.uppercased().filter { !$0.isWhitespace }
                let cS = secText.uppercased().filter { !$0.isWhitespace }
                if cV != cS && cS.count >= 5 {
                    let secRegion = PlateValidator.validate(secText).1
                    votes.append(Vote(
                        text: secText, confidence: obs.secondaryConfidence,
                        frameIdx: obs.frameIdx, workBoxArea: area,
                        region: secRegion, origin: .crossValidated,
                        isStrictValidCz: false,
                        isSecondary: true, observationIdx: idx))
                }
            }
        }
        guard !votes.isEmpty else { return nil }

        // Cluster fuzzy votes (L-1 grouping na vote level místo obs level).
        var clusters: [[Int]] = []
        for (idx, v) in votes.enumerated() {
            var placed = false
            for i in clusters.indices {
                let reprIdx = clusters[i][0]
                if PlateTrack.isL1(votes[reprIdx].text, v.text) {
                    clusters[i].append(idx); placed = true; break
                }
            }
            if !placed { clusters.append([idx]) }
        }
        guard let biggest = clusters.max(by: { $0.count < $1.count }) else { return nil }

        // Single pass: spočítat maxFrameIdx + maxArea + accumulate ScoredText
        // mapu napříč biggest cluster. Iterujeme `votes[idx]` (Vision + Secondary
        // sloučené), ne `observations[idx]`.
        var maxFrameIdx = 0
        var maxArea: CGFloat = 0
        for idx in biggest {
            let v = votes[idx]
            if v.frameIdx > maxFrameIdx { maxFrameIdx = v.frameIdx }
            if v.workBoxArea > maxArea { maxArea = v.workBoxArea }
        }

        var scored: [String: ScoredText] = [:]
        // Enhanced overlap detection — pro Vision votes only; secondary votes
        // dostávají stálou enhanced multiplier přes `.crossValidated` origin.
        let enhancedObsIndices = Set(biggest.compactMap { vidx -> Int? in
            let v = votes[vidx]
            return (v.origin == .passTwoEnhanced && !v.isSecondary) ? v.observationIdx : nil
        })
        for idx in biggest {
            let v = votes[idx]
            let obsIdx = v.observationIdx
            let obs = observations[obsIdx]
            let hasEnhancedOverlap: Bool = {
                guard !v.isSecondary, v.origin == .passOneRaw else { return false }
                for eidx in enhancedObsIndices where eidx != obsIdx {
                    if Self.hasMeaningfulOverlap(obs.workBox, observations[eidx].workBox) {
                        return true
                    }
                }
                return false
            }()
            // Secondary votes: konstantní base weight (Vision conf nezohledňujeme,
            // secondary má vlastní confidence). Vision votes: standardní weight.
            let baseWeight: Float = v.isSecondary
                ? max(0.5, v.confidence) * Float(min(1.0, v.workBoxArea / max(maxArea, 1)))
                : Self.observationVoteWeight(obs: obs, area: v.workBoxArea,
                                             maxFrameIdx: maxFrameIdx, maxArea: maxArea)
            let weight = baseWeight * Self.originVoteMultiplier(
                obs: PlateObservation(
                    text: v.text, confidence: v.confidence, frameIdx: v.frameIdx,
                    bbox: obs.bbox, workBox: obs.workBox, workSize: obs.workSize,
                    region: v.region, origin: v.origin,
                    isStrictValidCz: v.isStrictValidCz),
                hasEnhancedOverlap: hasEnhancedOverlap,
                config: originVoteConfig
            )
            let enhancedValid = (v.origin == .passTwoEnhanced || v.origin == .crossValidated)
                && v.isStrictValidCz
            if var prev = scored[v.text] {
                prev.weight += weight
                prev.count += 1
                prev.conf = max(prev.conf, v.confidence)
                prev.confSum += v.confidence
                if v.frameIdx > prev.latestFrame { prev.latestFrame = v.frameIdx }
                if v.workBoxArea > prev.maxArea { prev.maxArea = v.workBoxArea }
                prev.hasEnhancedValidCz = prev.hasEnhancedValidCz || enhancedValid
                scored[v.text] = prev
            } else {
                scored[v.text] = ScoredText(
                    text: v.text, weight: weight, count: 1,
                    conf: v.confidence, confSum: v.confidence,
                    region: v.region, latestFrame: v.frameIdx, maxArea: v.workBoxArea,
                    hasEnhancedValidCz: enhancedValid)
            }
        }

        guard let best = scored.values.max(by: { lhs, rhs in
            if lhs.hasEnhancedValidCz != rhs.hasEnhancedValidCz {
                return !lhs.hasEnhancedValidCz && rhs.hasEnhancedValidCz
            }
            if abs(lhs.weight - rhs.weight) > 0.05 { return lhs.weight < rhs.weight }
            if lhs.latestFrame != rhs.latestFrame { return lhs.latestFrame < rhs.latestFrame }
            if abs(lhs.maxArea - rhs.maxArea) > 1 { return lhs.maxArea < rhs.maxArea }
            if lhs.count != rhs.count { return lhs.count < rhs.count }
            return lhs.conf < rhs.conf
        }) else { return nil }
        return (best, biggest.count)
    }

    /// Backward-compat shim — keep `clusterBestText` 3-tuple API pro existing
    /// callers (Tracker.update, Tracker LOST path).
    fileprivate func clusterBestText() -> (text: String, count: Int, region: PlateRegion)? {
        guard let scored = clusterBestScored() else { return nil }
        return (scored.winner.text, scored.clusterCount, scored.winner.region)
    }

    /// Per-observation quality-weighted vote. Vision `.accurate` často vrací
    /// conf=1.0 i pro rané malé / částečné přečtení. Pouhý count by pak umí
    /// commitnout starý omyl. Vážíme `confidence × area × recency`:
    ///   - `confidence` floor 0.05 (žádný 0× weight i pro low-conf rescue)
    ///   - `areaWeight = 0.25 + 0.75 · sqrt(areaRatio)` — sqrt zploští křivku
    ///     (malé bboxy nepenalizovány k 0)
    ///   - `recencyWeight = max(0.35, 0.92^age)` — pozdější frame > raný (auto
    ///     se blíží = lepší čitelnost)
    static func observationVoteWeight(obs: PlateObservation, area: CGFloat,
                                       maxFrameIdx: Int, maxArea: CGFloat) -> Float {
        let areaRatio: CGFloat = maxArea > 0 ? min(1, max(0, area / maxArea)) : 1
        let areaWeight = Float(0.25 + 0.75 * sqrt(areaRatio))
        let age = max(0, maxFrameIdx - obs.frameIdx)
        let recencyWeight = max(0.35, pow(0.92, Float(age)))
        return max(0.05, obs.confidence) * areaWeight * recencyWeight
    }

    static func originVoteMultiplier(obs: PlateObservation,
                                     hasEnhancedOverlap: Bool,
                                     config: OriginVoteConfig) -> Float {
        switch obs.origin {
        case .crossValidated:
            return max(0.0, config.crossValidatedVoteWeight)
        case .crossValidatedFuzzy:
            return 1.0
        case .weakTrackletMerged:
            return 1.0
        case .passTwoEnhanced:
            return max(0.0, config.enhancedVoteWeight)
        case .passOneRaw:
            return hasEnhancedOverlap
                ? max(0.0, config.baseVoteWeightWhenEnhancedOverlap)
                : 1.0
        }
    }

    private static func hasMeaningfulOverlap(_ a: CGRect, _ b: CGRect) -> Bool {
        let inter = a.intersection(b)
        guard !inter.isNull, !inter.isEmpty, inter.width > 0, inter.height > 0 else {
            return false
        }
        let interArea = inter.width * inter.height
        let minArea = max(1, min(a.width * a.height, b.width * b.height))
        return interArea / minArea >= 0.30
    }

    /// Multi-frame voting display confidence. Vrací (text, displayConf, votes, region)
    /// kde:
    ///   • voteShare — fraction observací v winning clusteru (penalizuje split tracky)
    ///   • frameScore — **saturuje rychleji**: min(1, totalObs / 1.5) → 1 obs = 0.67,
    ///     2 obs = 1.00. Fast-single (1 hit) = legitní commit s reasonable trust;
    ///     předtím frameScore=0.33 mechanicky cap-oval i správně přečtené plate.
    ///   • ocrMean — průměr raw Vision conf
    ///   • crossValBonus — +10% pokud winning cluster má cross-validated origin
    ///     (sekundární engine confirmed)
    /// displayConf = voteShare · frameScore · ocrMean · crossValBonus.
    /// Frame-floor pro cross-validated obs zajistí že fast-single commits
    /// dostávají rozumný displayConf — OCR ztiskl plate s vysokou conf i když
    /// track měl 1 hit, sekundární engine to potvrdil.
    func bestText() -> (text: String, meanConf: Float, votes: Int, region: PlateRegion)? {
        guard !observations.isEmpty else { return nil }
        guard let scored = clusterBestScored() else { return nil }
        let totalObs = observations.count
        let voteShare = Float(scored.clusterCount) / Float(max(totalObs, 1))
        let frameScore = min(1.0, Float(totalObs) / 1.5)
        let ocrMean = scored.winner.confSum / Float(max(scored.winner.count, 1))
        // Cross-validation bonus: pokud winning cluster obsahuje cross-validated
        // origin (secondary engine agreed/l1-agreed), boost o 10%. Capped 1.0.
        let hasExactCrossVal = observations.contains {
            $0.origin == .crossValidated && $0.text == scored.winner.text
        }
        let hasFuzzyCrossVal = observations.contains {
            $0.origin == .crossValidatedFuzzy && $0.text == scored.winner.text
        }
        let crossValBonus: Float = (hasExactCrossVal || hasFuzzyCrossVal) ? 1.10 : 1.0
        // **Exact cross-validation overrides fast-single frameScore penalty.**
        // Secondary OCR engine `agree` (text canonical exact match) je independent
        // evidence ekvivalent multi-frame votingu — bez floor by displayConf
        // capovalo na ~0.73 i když certitude je 1.00. Fuzzy `l1-agree` floor je
        // nižší (0.85) kvůli ambiguous-glyph possibility (O↔0, 8↔B).
        let frameFloor: Float = hasExactCrossVal ? 1.0 : (hasFuzzyCrossVal ? 0.85 : 0.0)
        let effectiveFrameScore = max(frameScore, frameFloor)
        let displayConf = min(1.0, max(0.0, voteShare * effectiveFrameScore * ocrMean * crossValBonus))
        return (scored.winner.text, displayConf, scored.winner.count, scored.winner.region)
    }

    func toneMeta(matching text: String) -> ToneMeta? {
        let target = text.uppercased().filter { !$0.isWhitespace }
        let matching = observations
            .filter { obs in
                let primary = obs.text.uppercased().filter { !$0.isWhitespace }
                let secondary = obs.secondaryText?.uppercased().filter { !$0.isWhitespace }
                return primary == target || secondary == target || PlateTrack.isL1(primary, target)
            }
            .filter { $0.toneMeta != nil }
            .sorted {
                if $0.frameIdx != $1.frameIdx { return $0.frameIdx > $1.frameIdx }
                let aArea = $0.workBox.width * $0.workBox.height
                let bArea = $1.workBox.width * $1.workBox.height
                return aArea > bArea
            }
        return matching.first?.toneMeta
    }

    /// Fuzzy-cluster consensus — slouží jako gate pro commit.
    /// Cluster sjednotí L-1 varianty (WOB ZK 295 ≈ WOBG ZK 295 ≈ WOBS ZK 295),
    /// jinak by byl každý frame separate hlas a consensus se nikdy nenabral.
    func hasStrongConsensus(minVotes: Int, minShare: Float) -> Bool {
        guard !observations.isEmpty else { return false }
        guard let best = clusterBestText() else { return false }
        let share = Float(best.count) / Float(observations.count)
        return best.count >= minVotes && share >= minShare
    }

    /// Auto-direction inference — kterým směrem se auto pohybovalo během záznamu.
    /// Použito pro single-camera setupy kde stejná kamera kryje vjezd i výjezd:
    /// relax LOST path gates u departing aut (auto se vzdaluje = méně framů než
    /// přijíždějící). Pro dedikované kamery `tracker.exitMode` static-true na
    /// výjezdu, tahle inference jen confirms / loguje.
    ///
    /// Heuristika: porovnej průměrnou plate area z prvních 1-2 vs. posledních
    /// 1-2 observací. Trend dolů (≥ 30 % drop) = `.departing`. Trend nahoru
    /// (≥ 30 % growth) = `.approaching`. Plateau / krátký track = `.unknown`.
    enum Direction: String { case approaching, departing, unknown }
    func inferredDirection() -> Direction {
        guard observations.count >= 3 else { return .unknown }
        let firstN = observations.prefix(2)
        let lastN = observations.suffix(2)
        func meanArea(_ obs: ArraySlice<PlateObservation>) -> CGFloat {
            let areas = obs.map { $0.workBox.width * $0.workBox.height }
            guard !areas.isEmpty else { return 0 }
            return areas.reduce(0, +) / CGFloat(areas.count)
        }
        let initial = meanArea(firstN)
        let final = meanArea(lastN)
        guard initial > 0 else { return .unknown }
        let ratio = final / initial
        if ratio >= 1.30 { return .approaching }
        if ratio <= 0.70 { return .departing }
        return .unknown
    }
}

/// Tracker rozhodnutí o tracku v okamžiku LOST. Buď commitnout (4 cesty s různou
/// silou důvěry), nebo zahodit (2 lost reasons). Carries diagnostic data pro
/// jediný unifikovaný log emit místo 4 oddělených stderr.write.
enum CommitVerdict {
    case consensus(text: String, region: PlateRegion)
    case wlOverride(text: String, region: PlateRegion, hits: Int, consensusOK: Bool)
    case twoHitValid(text: String, region: PlateRegion, clusterCount: Int, totalObs: Int, widthFracMax: CGFloat)
    case fastSingle(text: String, region: PlateRegion, widthFracMax: CGFloat)
    case waitForBetter(reason: DeferReason, winner: String, clusterFraction: Float)
    case lost(reason: LostReason, winner: String, hits: Int, consensusOK: Bool, widthFracMax: CGFloat, lostMinFrac: CGFloat)

    enum DeferReason: String { case approachingTiny, textUnstable, fuzzyContamination, singleHitNeedsValidation, fuzzyNeighbor }
    enum LostReason: String { case widthTooSmall, noConsensus }

    var path: String {
        switch self {
        case .consensus: return "consensus"
        case .wlOverride: return "wl-override"
        case .twoHitValid: return "2hit-valid"
        case .fastSingle: return "fast-single"
        case .waitForBetter: return "wait-for-better"
        case .lost: return "lost"
        }
    }

    var commits: Bool {
        if case .lost = self { return false }
        if case .waitForBetter = self { return false }
        return true
    }
}

final class IoUTracker {
    var iouThreshold: CGFloat = 0.3
    private(set) var lastUpdateFrameIdx: Int = 0
    /// Grace před tím, než se track prohlásí za lost. `fast-gate` profil:
    /// 4 framy @ 15 fps = 267 ms. Rychlé auto (30+ km/h) projede ROI za ~300 ms —
    /// delší grace (10) by commit spustil až když už je auto pryč, a při paralelním
    /// druhém autě by IoU absorbovala nový plate do starého tracku → miss.
    var maxLostFrames: Int = 4
    /// Track musí být vidět alespoň N framů PŘED tím než se zváží commit.
    /// 2 = krátké průjezdy foreign plate se stihnou committnout.
    var minHitsToCommit: Int = 2
    /// Force-commit po N hits i když plate ještě drží (consensus gated).
    /// `fast-gate`: 3 hits @ 15 fps = 200 ms v záběru → commit stihne i auto co
    /// projede za 300 ms. Vyšší false-positive risk (cedulky, reflexy) — kompenzováno
    /// minWinnerVoteShare=0.65 a whitelist gate na webhook.
    var forceCommitAfterHits: Int = 3
    /// Po tomto počtu sekund se committed track "odemkne" a může fire commit
    /// znovu (pokud je plate stále v záběru). Nastavováno z AppState.recommitDelaySec.
    var recommitAfterSec: TimeInterval = 15.0
    /// Vítězný text v track.observations musí mít alespoň N shodných hlasů.
    /// `fast-gate`: 2 (minimální smysluplný consensus — 2 stejná čtení z 2-3 obs
    /// = majority). Slow-gate měl 3 (víc observation → striktnější).
    var minWinnerVotes: Int = 2
    /// A zároveň musí být alespoň M % observací stejný text (voteShare).
    /// 0.65 — noise typicky dá max 50 % voteShare (2/4 semi-consistent garbage),
    /// real plate ≥ 65 % (majority správně, malé frakce OCR fragmentů).
    var minWinnerVoteShare: Float = 0.65
    /// Min plate width as fraction of workspace (0 = disabled). 0.12 = plate must
    /// be ≥ 12 % workspace wide pro commit (blíž kamery = lepší snapshot detail).
    var minPlateWidthFraction: CGFloat = 0.09
    /// Safety multiplier — pokud t.hits >= forceCommit × tohle, commit i při malé
    /// plate (LOST path pořád commit-uje). 0 = disable safety (pouze LOST commits).
    var minPlateWidthSafetyMult: Double = 3.0
    var originVoteConfig: OriginVoteConfig = .neutral

    /// Exit mode (rychlá auta + větší úhel kamery → committovat ASAP).
    /// Pipeline to nastaví když `cameraName == "vyjezd"` — na exit kameře:
    ///   • skip area-plateau gate (žádné čekání na peak, plate je vidět chvíli)
    ///   • min-plate-width redukovaný na 50 % (malá plate lepší než žádná)
    ///   • minWinnerVotes redukovaný (1 místo nastaveného — 2 votes stačí pro commit)
    var exitMode: Bool = false

    /// Kamera z níž tento tracker konzumuje. Pipeline ho nastavuje při `bind()`.
    /// Použito pro Audit.event payload — bez něj by audit záznamy z více kamer
    /// nešly zpětně rozdělit.
    var cameraName: String = ""

    var effectiveIouThreshold: CGFloat {
        // Vyjezd kamera má větší úhel + rychlejší auta, takže bbox mezi OCR ticky
        // skáče víc než na vjezdu. Držíme user threshold pro běžné kamery, ale v
        // exitMode dovolíme match až k 0.20, aby single car nevyrábělo 7+ track IDs.
        exitMode ? min(iouThreshold, 0.20) : iouThreshold
    }

    func tracksMatching(text: String, withinFrames: Int = 20) -> Int {
        let target = text.uppercased().filter { !$0.isWhitespace }
        guard !target.isEmpty else { return 0 }
        return tracks.values.filter { track in
            lastUpdateFrameIdx - track.lastSeenFrame <= withinFrames
                && track.observations.contains { obs in
                    let primary = obs.text.uppercased().filter { !$0.isWhitespace }
                    let secondary = obs.secondaryText?.uppercased().filter { !$0.isWhitespace }
                    return primary == target
                        || secondary == target
                        || PlateTrack.isL1(primary, target)
                }
        }.count
    }

    /// Secondary association path pro výjezd: rychlé auto + šikmý úhel umí posunout
    /// bbox tak daleko, že čisté IoU spadne pod 0.20 a vznikne nový track pro
    /// stejnou SPZ. Rescue match pustíme jen v exitMode, jen pro textově kompatibilní
    /// čtení a jen když je nový bbox pořád prostorově blízko poslední pozici.
    /// Reálný IoU match má vždy vyšší prioritu; rescue score je pod prahem.
    private func exitRescueMatchScore(track t: PlateTrack,
                                      detection det: PlateOCRReading,
                                      iou: CGFloat,
                                      frameIdx: Int) -> CGFloat? {
        guard exitMode else { return nil }
        let frameGap = frameIdx - t.lastSeenFrame
        guard frameGap >= 0, frameGap <= max(maxLostFrames, 1) else { return nil }

        let candidateTexts = [det.text] + det.altTexts
        let trackTexts: [String] = {
            if t.committed, !t.committedText.isEmpty { return [t.committedText] }
            if let best = t.clusterBestText()?.text { return [best] }
            if let last = t.observations.last?.text { return [last] }
            return []
        }()
        guard !trackTexts.isEmpty,
              candidateTexts.contains(where: { candidate in
                  trackTexts.contains { PlateTrack.isL1($0, candidate) }
              }) else { return nil }

        let a = t.lastBbox
        let b = det.bbox
        guard a.width > 0, a.height > 0, b.width > 0, b.height > 0 else { return nil }

        let maxW = max(a.width, b.width, 1)
        let maxH = max(a.height, b.height, 1)
        let dx = abs(a.midX - b.midX) / maxW
        let dy = abs(a.midY - b.midY) / maxH
        guard dx <= 2.0, dy <= 1.25 else { return nil }

        let areaA = a.width * a.height
        let areaB = b.width * b.height
        let areaRatio = min(areaA, areaB) / max(max(areaA, areaB), 1)
        guard areaRatio >= 0.20 else { return nil }

        let distancePenalty = min(1.0, (dx / 2.0 + dy / 1.25) * 0.5)
        let closeness = max(0.0, 1.0 - distancePenalty)
        // Keep rescue below real IoU threshold so normal spatial matching wins.
        return min(effectiveIouThreshold * 0.95,
                   effectiveIouThreshold * (0.35 + 0.45 * closeness) + iou * 0.2)
    }

    private var tracks: [Int: PlateTrack] = [:]
    private var nextId: Int = 1
    private static let weakMergeWindowFrames: Int = 30
    private static let weakMergeMaxBufferedTracksPerCamera: Int = 24
    private var weakMergeBuffer: [String: [PendingWeakTrack]] = [:]

    private struct PendingWeakTrack {
        let camera: String
        let track: PlateTrack
        let lostFrameIdx: Int
    }

    /// Whitelist match s exact + Lev-1 fuzzy nad MainActor-safe snapshotem.
    /// Replikuje sémantiku `KnownPlates.shared.match()` (exact prefer, fallback
    /// Lev-1) aby tracker LOST path nemusel volat MainActor z processingQueue.
    static func matchesWhitelistSnapshot(_ text: String, snapshot: Set<String>) -> Bool {
        let t = text.uppercased()
        if snapshot.contains(t) { return true }
        for known in snapshot where PlateTrack.isL1(known, t) { return true }
        return false
    }

    /// Reset state — vol při reconnect kamery / změně rozlišení.
    func reset() {
        tracks.removeAll()
        weakMergeBuffer.removeAll()
        nextId = 1
    }

    var debugWeakMergeBufferedCount: Int {
        weakMergeBuffer.values.reduce(0) { $0 + $1.count }
    }

    private func pruneWeakMergeBuffers(currentFrameIdx: Int) {
        for key in Array(weakMergeBuffer.keys) {
            var buffer = weakMergeBuffer[key] ?? []
            buffer = buffer.filter { currentFrameIdx - $0.lostFrameIdx <= Self.weakMergeWindowFrames }
            if buffer.count > Self.weakMergeMaxBufferedTracksPerCamera {
                buffer = Array(buffer.suffix(Self.weakMergeMaxBufferedTracksPerCamera))
            }
            if buffer.isEmpty {
                weakMergeBuffer.removeValue(forKey: key)
            } else {
                weakMergeBuffer[key] = buffer
            }
        }
    }

    private static func weakObservation(from obs: PlateObservation) -> PlateObservation {
        PlateObservation(
            text: obs.text,
            confidence: obs.confidence,
            frameIdx: obs.frameIdx,
            bbox: obs.bbox,
            workBox: obs.workBox,
            workSize: obs.workSize,
            region: obs.region,
            origin: .weakTrackletMerged,
            isStrictValidCz: obs.isStrictValidCz
        )
    }

    private static func weakMergeText(for track: PlateTrack) -> String? {
        if let best = track.clusterBestText()?.text, !best.isEmpty { return best }
        return track.observations.last?.text
    }

    private static func representativeBox(for track: PlateTrack) -> CGRect {
        if !track.bestWorkBox.isEmpty, track.bestWorkBox.width > 0, track.bestWorkBox.height > 0 {
            return track.bestWorkBox
        }
        if !track.lastWorkBox.isEmpty, track.lastWorkBox.width > 0, track.lastWorkBox.height > 0 {
            return track.lastWorkBox
        }
        if let last = track.observations.last {
            return last.workBox
        }
        return track.lastBbox
    }

    private static func representativeWorkSize(for track: PlateTrack) -> CGSize {
        if track.bestWorkSize.width > 0, track.bestWorkSize.height > 0 { return track.bestWorkSize }
        if track.lastWorkSize.width > 0, track.lastWorkSize.height > 0 { return track.lastWorkSize }
        return track.observations.last?.workSize ?? .zero
    }

    private static func weakMergeTrajectoryOK(_ pending: [PendingWeakTrack],
                                              exitMode: Bool,
                                              cameraName: String) -> Bool {
        guard pending.count >= 2 else { return false }
        let sorted = pending.sorted { $0.track.firstSeenFrame < $1.track.firstSeenFrame }
        let boxes = sorted.map { representativeBox(for: $0.track) }
        let sizes = sorted.map { representativeWorkSize(for: $0.track) }

        for i in 1..<boxes.count {
            let prev = boxes[i - 1]
            let cur = boxes[i]
            let size = sizes[i].width > 0 && sizes[i].height > 0 ? sizes[i] : sizes[i - 1]
            let diag = max(1, hypot(size.width, size.height))
            let dist = hypot(cur.midX - prev.midX, cur.midY - prev.midY)
            guard dist <= diag * 0.40 else { return false }
        }

        if boxes.count >= 3 {
            for i in 2..<boxes.count {
                let a = boxes[i - 2]
                let b = boxes[i - 1]
                let c = boxes[i]
                let v1 = CGVector(dx: b.midX - a.midX, dy: b.midY - a.midY)
                let v2 = CGVector(dx: c.midX - b.midX, dy: c.midY - b.midY)
                guard v1.dx * v2.dx + v1.dy * v2.dy >= 0 else { return false }
            }
        }

        let firstArea = boxes.first.map { $0.width * $0.height } ?? 0
        let lastArea = boxes.last.map { $0.width * $0.height } ?? 0
        guard firstArea > 0, lastArea > 0 else { return false }
        let effectiveExit = exitMode || cameraName.lowercased().contains("vyjezd")
        if effectiveExit {
            return lastArea <= firstArea * 1.15
        } else {
            return lastArea >= firstArea * 0.85
        }
    }

    private static func weakMergeCandidateIndices(in buffer: [PendingWeakTrack],
                                                  exitMode: Bool,
                                                  cameraName: String) -> [Int]? {
        guard buffer.count >= 2 else { return nil }
        var bestIndices: [Int]?
        var bestHits = 0
        for seedIndex in buffer.indices {
            guard let seedText = weakMergeText(for: buffer[seedIndex].track) else { continue }
            let indices = buffer.indices.filter { idx in
                guard let text = weakMergeText(for: buffer[idx].track) else { return false }
                return PlateTrack.isL1(seedText, text)
            }
            let totalHits = indices.reduce(0) { $0 + buffer[$1].track.hits }
            guard totalHits >= 3 else { continue }
            let tracks = indices.map { buffer[$0] }
            guard weakMergeTrajectoryOK(tracks, exitMode: exitMode, cameraName: cameraName) else {
                continue
            }
            if totalHits > bestHits {
                bestHits = totalHits
                bestIndices = Array(indices)
            }
        }
        return bestIndices
    }

    private func makeSyntheticWeakTrack(from pending: [PendingWeakTrack]) -> PlateTrack? {
        let observations = pending
            .flatMap { $0.track.observations }
            .sorted { $0.frameIdx < $1.frameIdx }
            .map { Self.weakObservation(from: $0) }
        guard let first = observations.first, let last = observations.last else { return nil }

        let synthetic = PlateTrack(id: nextId, bbox: first.bbox, frameIdx: first.frameIdx)
        nextId += 1
        synthetic.originVoteConfig = originVoteConfig
        synthetic.observations = observations
        synthetic.hits = observations.count
        synthetic.firstSeenFrame = first.frameIdx
        synthetic.lastSeenFrame = last.frameIdx
        synthetic.lastBbox = last.bbox
        synthetic.lastWorkBox = last.workBox
        synthetic.lastWorkSize = last.workSize

        let bestSource = pending.map(\.track).max { lhs, rhs in
            let la = Self.representativeBox(for: lhs).width * Self.representativeBox(for: lhs).height
            let ra = Self.representativeBox(for: rhs).width * Self.representativeBox(for: rhs).height
            return la < ra
        }
        if let bestSource {
            synthetic.bestBbox = bestSource.bestBbox
            synthetic.bestWorkBox = bestSource.bestWorkBox
            synthetic.bestWorkSize = bestSource.bestWorkSize
            synthetic.bestScore = bestSource.bestScore
            synthetic.bestCGImage = bestSource.bestCGImage ?? bestSource.pendingBestCGImage
            synthetic.pendingBestCGImage = bestSource.pendingBestCGImage ?? bestSource.bestCGImage
            synthetic.bestRawCIImage = bestSource.bestRawCIImage ?? bestSource.pendingBestRawCIImage
            synthetic.pendingBestRawCIImage = bestSource.pendingBestRawCIImage ?? bestSource.bestRawCIImage
        }
        synthetic.stackFrames = pending
            .flatMap { $0.track.stackFrames }
            .sorted { $0.confidence > $1.confidence }
            .prefix(4)
            .map { $0 }
        return synthetic
    }

    private func bufferLostTrackAndEvaluateWeakMerge(_ track: PlateTrack,
                                                     lostFrameIdx: Int,
                                                     knownSnapshot: Set<String>,
                                                     effectiveMinVotes: Int,
                                                     minWinnerVotes: Int,
                                                     minHitsToCommit: Int,
                                                     minWinnerVoteShare: Float,
                                                     minPlateWidthFraction: CGFloat,
                                                     forceCommitAfterHits: Int,
                                                     effectiveExitMode: Bool,
                                                     lostMinFrac: CGFloat) -> PlateTrack? {
        guard !track.observations.isEmpty else { return nil }
        let cameraKey = cameraName.isEmpty ? "__default__" : cameraName
        var buffer = weakMergeBuffer[cameraKey] ?? []
        buffer = buffer.filter { lostFrameIdx - $0.lostFrameIdx <= Self.weakMergeWindowFrames }
        buffer.append(PendingWeakTrack(camera: cameraKey, track: track, lostFrameIdx: lostFrameIdx))
        if buffer.count > Self.weakMergeMaxBufferedTracksPerCamera {
            buffer = Array(buffer.suffix(Self.weakMergeMaxBufferedTracksPerCamera))
        }

        guard let mergeIndices = Self.weakMergeCandidateIndices(in: buffer,
                                                                exitMode: exitMode,
                                                                cameraName: cameraName),
              mergeIndices.count >= 2 else {
            weakMergeBuffer[cameraKey] = buffer
            return nil
        }

        let pending = mergeIndices.map { buffer[$0] }
        guard let synthetic = makeSyntheticWeakTrack(from: pending) else {
            weakMergeBuffer[cameraKey] = buffer
            return nil
        }

        let maxWidthSeen = synthetic.observations.map { $0.workBox.width }.max() ?? 0
        let lastWorkW = synthetic.observations.last?.workSize.width ?? 0
        let widthFracMax = lastWorkW > 0 ? maxWidthSeen / lastWorkW : 0
        let widthGateBlocks = (minPlateWidthFraction > 0)
            && (lastWorkW > 0)
            && (widthFracMax < lostMinFrac)
        let consensusOK = synthetic.hasStrongConsensus(minVotes: effectiveMinVotes,
                                                        minShare: minWinnerVoteShare)
        let verdict = Self.decideCommitVerdict(
            track: synthetic,
            knownSnapshot: knownSnapshot,
            minHitsToCommit: minHitsToCommit,
            consensusOK: consensusOK,
            widthGateBlocks: widthGateBlocks,
            widthFracMax: widthFracMax,
            lostMinFrac: lostMinFrac,
            effectiveExitMode: effectiveExitMode,
            forceCommitAfterHits: forceCommitAfterHits,
            minWinnerVoteShare: minWinnerVoteShare,
            minPlateWidthFraction: minPlateWidthFraction
        )

        let sourceIds = pending.map { $0.track.id }
        Audit.event("weak_tracklet_merge", [
            "camera": cameraName,
            "merged_track_ids": sourceIds,
            "synthetic_track": synthetic.id,
            "total_hits": synthetic.hits,
            "winner": synthetic.clusterBestText()?.text ?? "?",
            "path": verdict.path,
            "commits": verdict.commits,
            "widthFracMax": Double(widthFracMax)
        ])
        Self.emitVerdictLog(tid: synthetic.id, track: synthetic, verdict: verdict,
                            cameraName: cameraName, exitMode: exitMode,
                            minWinnerVotes: minWinnerVotes,
                            minWinnerVoteShare: minWinnerVoteShare)

        if verdict.commits {
            synthetic.commitPath = "weak-\(verdict.path)"
            Audit.event("weak_merge_commit", [
                "camera": cameraName,
                "merged_track_ids": sourceIds,
                "synthetic_track": synthetic.id,
                "total_hits": synthetic.hits,
                "winner": synthetic.clusterBestText()?.text ?? "?",
                "synth_path": synthetic.commitPath ?? "weak"
            ])
            let removeSet = Set(mergeIndices)
            buffer = buffer.enumerated().compactMap { removeSet.contains($0.offset) ? nil : $0.element }
            weakMergeBuffer[cameraKey] = buffer
            return synthetic
        }

        weakMergeBuffer[cameraKey] = buffer
        return nil
    }

    /// Update s novými detekcemi. Vrátí finalized tracks (k commit).
    /// `pixelBuffer` = frame, z něhož detections vznikly — uloží se s observation,
    /// aby commit() mohl použít frame nejlepší observation místo pozdějšího
    /// (rychlá auta: mezi best obs a commit je 6-13 frames = auto už mimo výřez).
    /// `knownSnapshot` = MainActor-safe snapshot whitelist plate stringů. Tracker
    /// ho používá pro whitelist-override fallback v LOST path bez nutnosti volat
    /// `KnownPlates.shared` z background queue (MainActor.assumeIsolated z
    /// processingQueue produkoval silent races → whitelisted auta neukládat).
    func update(detections: [PlateOCRReading], frameIdx: Int,
                knownSnapshot: Set<String> = []) -> (active: [PlateTrack], finalized: [PlateTrack]) {
        lastUpdateFrameIdx = max(lastUpdateFrameIdx, frameIdx)
        pruneWeakMergeBuffers(currentFrameIdx: frameIdx)
        var unmatchedDets = Array(detections.indices)
        var unmatchedTracks = Array(tracks.keys)

        // Greedy IoU match s text-consistency gate pro committed tracky:
        // committed track má `committedText` = winner SPZ; nové detekce musí mít
        // L≤1 text. Bez tohoto Vision misdetekce poblíž plate (cedulky, reflexy,
        // tag auta) absorbovaly do existujícího tracku → EMA kazilo bbox.
        var matches: [(trackId: Int, detIdx: Int)] = []
        if !unmatchedDets.isEmpty && !unmatchedTracks.isEmpty {
            var pairs: [(score: CGFloat, iou: CGFloat, rescue: Bool, trackId: Int, detIdx: Int)] = []
            for tid in unmatchedTracks {
                guard let t = tracks[tid] else { continue }
                for di in unmatchedDets {
                    let iou = IoUTracker.iou(t.lastBbox, detections[di].bbox)
                    if t.committed && !t.committedText.isEmpty {
                        let detTexts = [detections[di].text] + detections[di].altTexts
                        if !detTexts.contains(where: { PlateTrack.isL1(t.committedText, $0) }) {
                            continue
                        }
                    }
                    if iou >= effectiveIouThreshold {
                        pairs.append((score: iou, iou: iou, rescue: false, trackId: tid, detIdx: di))
                    } else if let rescueScore = exitRescueMatchScore(track: t,
                                                                     detection: detections[di],
                                                                     iou: iou,
                                                                     frameIdx: frameIdx) {
                        pairs.append((score: rescueScore, iou: iou, rescue: true, trackId: tid, detIdx: di))
                    }
                }
            }
            pairs.sort {
                if abs($0.score - $1.score) > 0.0001 { return $0.score > $1.score }
                return $0.iou > $1.iou
            }
            var usedT = Set<Int>(); var usedD = Set<Int>()
            for p in pairs {
                if usedT.contains(p.trackId) || usedD.contains(p.detIdx) { continue }
                matches.append((p.trackId, p.detIdx))
                usedT.insert(p.trackId); usedD.insert(p.detIdx)
                if p.rescue {
                    Audit.event("tracker_rescue_match", [
                        "camera": cameraName,
                        "track": p.trackId,
                        "text": detections[p.detIdx].text,
                        "iou": Double(p.iou),
                        "score": Double(p.score),
                        "frameGap": frameIdx - (tracks[p.trackId]?.lastSeenFrame ?? frameIdx)
                    ])
                }
            }
            unmatchedDets = unmatchedDets.filter { !usedD.contains($0) }
            unmatchedTracks = unmatchedTracks.filter { !usedT.contains($0) }
        }

        // Update matched
        for m in matches {
            let det = detections[m.detIdx]
            let (_, region) = PlateValidator.validate(det.text)
            tracks[m.trackId]?.add(PlateObservation(
                text: det.text, confidence: det.confidence, frameIdx: frameIdx,
                bbox: det.bbox, workBox: det.workBox, workSize: det.workSize,
                region: region,
                origin: det.origin,
                isStrictValidCz: det.isStrictValidCz,
                secondaryText: det.secondaryText,
                secondaryConfidence: det.secondaryConfidence,
                toneMeta: det.toneMeta
            ), workspaceImage: det.workspaceImage, rawWorkspaceImage: det.rawWorkspaceImage)
            tracks[m.trackId]?.originVoteConfig = originVoteConfig
        }

        // **Cross-track fuzzy snap (Vrstva 2):** PŘED new-track creation
        // se pokus snap-nout unmatched detekci na existující non-committed track,
        // pokud cluster.text vs det.text se liší jen v ambiguous-glyph swapech
        // (S↔B, 8↔B, 0↔O, 5↔S, 1↔I, 2↔Z, 6↔G, atd.). Bez tohoto snapu vznikají
        // paralelní tracky pro stejné auto když OCR střídavě čte ambiguous glyph.
        //
        // Constraints:
        //   • track NESMÍ být committed (committed má svůj L1 text gate)
        //   • editDistance ≤ 2 + allMismatchesAmbiguous + ambiguousMismatchCount ≥ 1
        //   • IoU >= 0.10 (low threshold — auto se hýbe mezi framy, ale stále
        //     ve stejném regionu obrazu)
        //   • prefer track s vyšším clusterCount (better existing evidence)
        var fuzzyMatches: [(trackId: Int, detIdx: Int)] = []
        for di in unmatchedDets {
            let det = detections[di]
            var bestPair: (trackId: Int, score: Float)?
            for tid in unmatchedTracks {
                guard let t = tracks[tid], !t.committed else { continue }
                guard let cluster = t.clusterBestText() else { continue }
                let cmp = AmbiguousGlyphMatrix.compareWithAmbiguous(cluster.text, det.text)
                guard cmp.editDistance >= 1, cmp.editDistance <= 2,
                      cmp.allMismatchesAmbiguous,
                      cmp.ambiguousMismatchCount >= 1 else { continue }
                let iou = IoUTracker.iou(t.lastBbox, det.bbox)
                guard iou >= 0.10 else { continue }
                let score = Float(cluster.count) * 100.0 + Float(iou)
                if bestPair == nil || score > bestPair!.score {
                    bestPair = (tid, score)
                }
            }
            if let best = bestPair {
                fuzzyMatches.append((best.trackId, di))
                Audit.event("tracker_fuzzy_track_snap", [
                    "camera": cameraName,
                    "track": best.trackId,
                    "track_text": tracks[best.trackId]?.clusterBestText()?.text ?? "",
                    "det_text": det.text,
                ])
            }
        }
        if !fuzzyMatches.isEmpty {
            let snappedDets = Set(fuzzyMatches.map { $0.detIdx })
            let snappedTracks = Set(fuzzyMatches.map { $0.trackId })
            for (tid, di) in fuzzyMatches {
                let det = detections[di]
                let (_, region) = PlateValidator.validate(det.text)
                tracks[tid]?.add(PlateObservation(
                    text: det.text, confidence: det.confidence, frameIdx: frameIdx,
                    bbox: det.bbox, workBox: det.workBox, workSize: det.workSize,
                    region: region,
                    origin: det.origin,
                    isStrictValidCz: det.isStrictValidCz,
                    secondaryText: det.secondaryText,
                    secondaryConfidence: det.secondaryConfidence,
                    toneMeta: det.toneMeta
                ), workspaceImage: det.workspaceImage, rawWorkspaceImage: det.rawWorkspaceImage)
                tracks[tid]?.originVoteConfig = originVoteConfig
            }
            unmatchedDets = unmatchedDets.filter { !snappedDets.contains($0) }
            unmatchedTracks = unmatchedTracks.filter { !snappedTracks.contains($0) }
        }

        // New tracks
        for di in unmatchedDets {
            let det = detections[di]
            let (_, region) = PlateValidator.validate(det.text)
            let tid = nextId; nextId += 1
            let t = PlateTrack(id: tid, bbox: det.bbox, frameIdx: frameIdx)
            t.originVoteConfig = originVoteConfig
            t.add(PlateObservation(
                text: det.text, confidence: det.confidence, frameIdx: frameIdx,
                bbox: det.bbox, workBox: det.workBox, workSize: det.workSize,
                region: region,
                origin: det.origin,
                isStrictValidCz: det.isStrictValidCz,
                secondaryText: det.secondaryText,
                secondaryConfidence: det.secondaryConfidence,
                toneMeta: det.toneMeta
            ), workspaceImage: det.workspaceImage, rawWorkspaceImage: det.rawWorkspaceImage)
            tracks[tid] = t
        }

        // Finalize: lost OR force-commit
        // **Consensus gate** — pro oba scénáře (lost i force) musí track mít
        // dostatečný počet shodných hlasů pro vítězný text. Bez toho se noise
        // se střídajícími se OCR výstupy committla po forceCommitAfterHits framech.
        var finalized: [PlateTrack] = []
        var toRemove: [Int] = []
        let now = Date()
        for (tid, t) in tracks {
            t.originVoteConfig = originVoteConfig
            // **Single-commit-per-track-lifetime:** committed track zůstává locked
            // po celou svou existenci. Re-commit jen když auto fyzicky opustí
            // frame (track LOST) a vrátí se → nový track ID → new commit prochází
            // přes recentCommitTimes dedup gate v PlatePipeline (s user-tunable
            // `recommitDelaySec`). Bez tohoto by parked auto se commitalo
            // opakovaně po každém `recommitAfterSec` interval.
            //
            // Heap snapshot (bestCGImage etc) zůstává retained dokud track není
            // LOST — toRemove list ho čistí pak.
            let lost = frameIdx - t.lastSeenFrame > maxLostFrames
            // Exit mode: relax consensus na min(2, user_setting). Vyjezd kamera má
            // jen pár frames než auto opustí frame — čekat na 3 votes (user default)
            // znamená 1-2 ticky lag = plate na okraji nebo už mimo. 2 votes při
            // shodném textu už je strong signal (voteShare = 100%).
            let effectiveMinVotes = exitMode ? min(2, minWinnerVotes) : minWinnerVotes
            let consensusOK = t.hasStrongConsensus(minVotes: effectiveMinVotes, minShare: minWinnerVoteShare)
            if lost {
                // Committed track na LOST path se NESMÍ znovu finalizovat —
                // force-commit branch už ho jednou poslal do PlatePipeline.commit().
                // Druhý finalize generoval ~1 s pozdější duplicate row v DB.
                // recentCommitTimes nestačí (CameraManager.sync ho při Settings
                // save resetuje), takže gate musí být tracker-level.
                if t.committed {
                    toRemove.append(tid)
                    continue
                }
                // LOST path width gate — track seen jen jako malá plate produkuje
                // low-res OCR misreads. Použij MAXIMUM observed width (track měl
                // možná moment kdy bylo dost velké). 50 % relaxed vs active path
                // — daleká auta dostávají šanci, ale extreme-small reject.
                let maxWidthSeen: CGFloat = t.observations.map { $0.workBox.width }.max() ?? 0
                let lastWorkW: CGFloat = t.observations.last?.workSize.width ?? 0
                // **Per-track auto direction:** kromě camera-level `exitMode`
                // (static config) infer direction z bbox area trendu. Pokud auto
                // jasně odjíždí (area klesá), aplikuj exit-mode relax (½ width
                // gate) i na vjezd kameře. Use-case: single-camera obousměrný
                // provoz, nebo auto otáčí v záběru.
                let inferredDir = t.inferredDirection()
                let effectiveExitMode = exitMode || inferredDir == .departing
                let lostMinFrac = (effectiveExitMode ? minPlateWidthFraction * 0.5 : minPlateWidthFraction) * 0.5
                let widthFracMax = lastWorkW > 0 ? maxWidthSeen / lastWorkW : 0
                let widthGateBlocks = (minPlateWidthFraction > 0)
                    && (lastWorkW > 0)
                    && (widthFracMax < lostMinFrac)
                if inferredDir != .unknown {
                    Audit.event("track_direction", [
                        "camera": cameraName, "track": tid,
                        "direction": inferredDir.rawValue,
                        "obs": t.observations.count,
                        "exitModeStatic": exitMode,
                        "exitModeEffective": effectiveExitMode
                    ])
                }

                // **Vrstva 3 input:** sběr clusterBestText TX z OSTATNÍCH active
                // non-committed tracků pro fuzzy-neighbor check ve fast-single.
                let competitorTexts: [String] = tracks.compactMap { (otid, other) -> String? in
                    guard otid != tid, !other.committed else { return nil }
                    return other.clusterBestText()?.text
                }
                let verdict = Self.decideCommitVerdict(
                    track: t, knownSnapshot: knownSnapshot,
                    minHitsToCommit: minHitsToCommit, consensusOK: consensusOK,
                    widthGateBlocks: widthGateBlocks,
                    widthFracMax: widthFracMax, lostMinFrac: lostMinFrac,
                    effectiveExitMode: effectiveExitMode,
                    forceCommitAfterHits: forceCommitAfterHits,
                    minWinnerVoteShare: minWinnerVoteShare,
                    minPlateWidthFraction: minPlateWidthFraction,
                    competitorTexts: competitorTexts
                )
                Self.emitVerdictLog(tid: tid, track: t, verdict: verdict,
                                    cameraName: cameraName, exitMode: exitMode,
                                    minWinnerVotes: minWinnerVotes,
                                    minWinnerVoteShare: minWinnerVoteShare)
                if case .waitForBetter(let reason, _, let clusterFraction) = verdict {
                    t.deferCount += 1
                    Self.emitDeferAudit(tid: tid, track: t, cameraName: cameraName,
                                        reason: reason,
                                        widthFracMax: widthFracMax,
                                        clusterFraction: clusterFraction)
                    continue
                }
                if verdict.commits {
                    if t.bestCGImage == nil, t.pendingBestCGImage != nil {
                        t.bestCGImage = t.pendingBestCGImage
                        t.bestRawCIImage = t.pendingBestRawCIImage
                    }
                    t.commitPath = verdict.path
                    finalized.append(t)
                } else if case .lost = verdict,
                          let merged = bufferLostTrackAndEvaluateWeakMerge(
                            t,
                            lostFrameIdx: frameIdx,
                            knownSnapshot: knownSnapshot,
                            effectiveMinVotes: effectiveMinVotes,
                            minWinnerVotes: minWinnerVotes,
                            minHitsToCommit: minHitsToCommit,
                            minWinnerVoteShare: minWinnerVoteShare,
                            minPlateWidthFraction: minPlateWidthFraction,
                            forceCommitAfterHits: forceCommitAfterHits,
                            effectiveExitMode: effectiveExitMode,
                            lostMinFrac: lostMinFrac
                          ) {
                    finalized.append(merged)
                }
                toRemove.append(tid)
                continue
            }
            // Diagnostic: track má dost hits na force-commit ale consensus padá.
            // 1-shot flag (consensusFailLogged) — logne se jen první tick kdy
            // podmínka platí, ne každý subsequent tick kde hits zůstává ≥ prah.
            if !t.committed, forceCommitAfterHits > 0,
               t.hits >= forceCommitAfterHits, !consensusOK, !t.consensusFailLogged {
                let winner = t.clusterBestText()?.text ?? "?"
                FileHandle.safeStderrWrite(
                    "[Tracker] track=\(tid) skip-commit consensus-fail hits=\(t.hits) winner=\(winner) votes=\(minWinnerVotes) share=\(minWinnerVoteShare)\n"
                        .data(using: .utf8)!)
                t.consensusFailLogged = true
            }
            if !t.committed && forceCommitAfterHits > 0 && t.hits >= forceCommitAfterHits && consensusOK {
                let maxWidthSeen: CGFloat = t.observations.map { $0.workBox.width }.max() ?? 0
                let workWForDefer: CGFloat = t.observations.last?.workSize.width ?? 0
                let widthFracMaxForDefer = workWForDefer > 0 ? maxWidthSeen / workWForDefer : 0
                let inferredDir = t.inferredDirection()
                let effectiveExitMode = exitMode || inferredDir == .departing
                if let wait = Self.waitForBetterReason(track: t,
                                                       effectiveExitMode: effectiveExitMode,
                                                       forceCommitAfterHits: forceCommitAfterHits,
                                                       minWinnerVoteShare: minWinnerVoteShare,
                                                       minPlateWidthFraction: minPlateWidthFraction,
                                                       widthFracMax: widthFracMaxForDefer) {
                    let verdict = CommitVerdict.waitForBetter(reason: wait.reason,
                                                              winner: wait.winner,
                                                              clusterFraction: wait.clusterFraction)
                    Self.emitVerdictLog(tid: tid, track: t, verdict: verdict,
                                        cameraName: cameraName, exitMode: exitMode,
                                        minWinnerVotes: minWinnerVotes,
                                        minWinnerVoteShare: minWinnerVoteShare)
                    t.deferCount += 1
                    Self.emitDeferAudit(tid: tid, track: t, cameraName: cameraName,
                                        reason: wait.reason,
                                        widthFracMax: widthFracMaxForDefer,
                                        clusterFraction: wait.clusterFraction)
                    continue
                }
                // **Area plateau gate:** dříve se committal
                // na 3rd hit i když auto pořád přijíždělo → snapshot daleko od kamery.
                // Počkáme až plate area STABILIZUJE (car dosáhl closest point nebo se
                // už vzdaluje) — poslední 2 observations musí mít area DO 10 % rozdílu.
                // Pokud pořád roste, delay commit o 1 tick.
                //
                // Safety: pokud už máme 2× forceCommitAfterHits hits (např. 6), commit
                // unconditionally aby se neztratily slow-approach cars.
                //
                // **Exit mode skip:** na výjezdu jedou auta rychleji,
                // úhel kamery je větší → plate je vidět jen pár frames. Čekání na
                // plateau stojí 1-3 ticky = snapshot ukáže auto už napůl mimo frame
                // (user report 4SU4001). Skip gate → commit při prvním consensus+hits OK.
                var areaPlateau = true
                if !exitMode, t.hits < forceCommitAfterHits * 2, t.observations.count >= 2 {
                    let last = t.observations[t.observations.count - 1].workBox
                    let prev = t.observations[t.observations.count - 2].workBox
                    let lastArea = last.width * last.height
                    let prevArea = prev.width * prev.height
                    if prevArea > 0 && lastArea > prevArea * 1.10 {
                        areaPlateau = false  // still approaching → wait
                    }
                }
                if !areaPlateau {
                    if !t.areaPlateauLogged {
                        let winner = t.clusterBestText()?.text ?? "?"
                        FileHandle.safeStderrWrite(
                            "[Tracker] track=\(tid) skip-commit area-plateau hits=\(t.hits) winner=\(winner)\n"
                                .data(using: .utf8)!)
                        t.areaPlateauLogged = true
                    }
                    continue
                }
                // **Min-plate-size gate:** plate bbox musí být aspoň N %
                // šířky workspace, jinak car je daleko / partially outside ROI.
                // Snapshot by byl low-detail. Wait — pokud track nikdy nedosáhne
                // této velikosti, commit přes LOST path (kde max snapshot wins).
                let last = t.observations.last
                // **Min-plate-size gate — user-tunable (Settings → Detekce).**
                // minPlateWidthFraction: 0 = disabled, 0.12 = default.
                // minPlateWidthSafetyMult: 0 = disable safety (pouze LOST commits),
                // jinak force commit pokud t.hits >= forceCommit × mult.
                let workW = last?.workSize.width ?? 0
                // Exit mode: relaxovaný min-plate-width (50%) — rychlá auta na výjezdu
                // nemají čas dorůst na threshold. 0.09 default → 0.045 effective.
                let effectiveMinPlateFrac = exitMode ? minPlateWidthFraction * 0.5 : minPlateWidthFraction
                if effectiveMinPlateFrac > 0, workW > 0, let lastBox = last?.workBox {
                    let minPlateW = workW * effectiveMinPlateFrac
                    let safetyHits = (minPlateWidthSafetyMult > 0)
                        ? Int(Double(forceCommitAfterHits) * minPlateWidthSafetyMult)
                        : Int.max
                    let widthFrac = lastBox.width / workW
                    if lastBox.width < minPlateW, t.hits < safetyHits {
                        if !t.smallPlateLogged {
                            let winner = t.clusterBestText()?.text ?? "?"
                            FileHandle.safeStderrWrite(
                                "[Tracker] track=\(tid) skip-commit small-plate hits=\(t.hits)/\(safetyHits) width=\(String(format: "%.3f", widthFrac))/\(minPlateWidthFraction) winner=\(winner)\n"
                                    .data(using: .utf8)!)
                            t.smallPlateLogged = true
                        }
                        continue  // plate je moc malá, wait for car to get closer
                    }
                    if lastBox.width < minPlateW, t.hits >= safetyHits {
                        // Safety commit: dosáhli jsme safetyHits (= forceCommit × mult)
                        // a plate je pořád malá → commit s low-detail flag. Lepší mít
                        // malou plate v DB než nic (auto už nemusí přijít blíž).
                        let winner = t.clusterBestText()?.text ?? "?"
                        FileHandle.safeStderrWrite(
                            "[Tracker] track=\(tid) safety-commit small-plate hits=\(t.hits) width=\(String(format: "%.3f", widthFrac)) winner=\(winner)\n"
                                .data(using: .utf8)!)
                    }
                }
                t.committed = true
                t.committedAt = now
                // Ulož winner text pro pozdější text-konzistentní matching (viz
                // popis `committedText`). Bez tohoto by Vision misdetekce kolem
                // plate korumpovaly EMA bbox etablovaného tracku.
                if let winner = t.clusterBestText() {
                    t.committedText = winner.text
                }
                t.commitPath = "consensus"
                finalized.append(t)
            }
        }
        for tid in toRemove { tracks.removeValue(forKey: tid) }
        // **Sort finalized tracks by confidence DESC** — fix race condition pro
        // multi-track per car (Vision text variability vytvoří 2+ tracky pro
        // stejné auto). Bez sortu by low-conf misread track commit-oval first
        // (insertion order = track ID), a pak by vyšší-conf správný track padl
        // L-2 dedup gate. Sort zajistí že nejvyšší-conf commit-uje first
        // → ostatní L-2 dedup správně dropne.
        finalized.sort { lhs, rhs in
            let lConf = lhs.clusterBestScored()?.winner.confSum ?? 0
            let rConf = rhs.clusterBestScored()?.winner.confSum ?? 0
            if abs(lConf - rConf) > 0.01 { return lConf > rConf }
            // Tiebreak: víc obs (větší cluster) = více evidence = silnější
            return lhs.observations.count > rhs.observations.count
        }
        return (Array(tracks.values), finalized)
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let x1 = max(a.minX, b.minX); let y1 = max(a.minY, b.minY)
        let x2 = min(a.maxX, b.maxX); let y2 = min(a.maxY, b.maxY)
        let iw = max(0, x2 - x1); let ih = max(0, y2 - y1)
        let inter = iw * ih
        if inter == 0 { return 0 }
        let union = a.width * a.height + b.width * b.height - inter
        return union > 0 ? inter / union : 0
    }

    static func clusterFraction(track t: PlateTrack) -> Float {
        let total = t.observations.count
        guard total > 0 else { return 0 }
        let bestCount = t.clusterBestText()?.count ?? 0
        return Float(bestCount) / Float(total)
    }

    static func waitForBetterReason(track t: PlateTrack,
                                    effectiveExitMode: Bool,
                                    forceCommitAfterHits: Int,
                                    minWinnerVoteShare: Float,
                                    minPlateWidthFraction: CGFloat,
                                    widthFracMax: CGFloat) -> (reason: CommitVerdict.DeferReason,
                                                               winner: String,
                                                               clusterFraction: Float)? {
        let matureTrack = t.hits >= 3
        let baseForceHits = max(forceCommitAfterHits, 1)
        let safetyHits = effectiveExitMode ? max(4, baseForceHits) : baseForceHits * 2
        let safetyTrip = t.hits >= safetyHits
        let canDefer = matureTrack && !safetyTrip && t.deferCount < 2
        guard canDefer else { return nil }

        let winner = t.clusterBestText()?.text ?? "?"
        let fraction = clusterFraction(track: t)
        let approachingTinyPlate = effectiveExitMode
            && widthFracMax < minPlateWidthFraction * 0.7
            && t.inferredDirection() == .approaching
        let textUnstable = t.observations.count >= 3
            && fraction < minWinnerVoteShare
        let latestFuzzyFrame = t.observations
            .filter { $0.origin == .crossValidatedFuzzy }
            .map(\.frameIdx)
            .max()
        let latestExactFrame = t.observations
            .filter { $0.origin == .crossValidated }
            .map(\.frameIdx)
            .max()
        let fuzzyContaminated = latestFuzzyFrame.map { fuzzyFrame in
            fuzzyFrame >= (latestExactFrame ?? Int.min)
        } ?? false

        if approachingTinyPlate {
            return (.approachingTiny, winner, fraction)
        }
        if textUnstable {
            return (.textUnstable, winner, fraction)
        }
        if fuzzyContaminated {
            return (.fuzzyContamination, winner, fraction)
        }
        return nil
    }

    /// Priority chain pro LOST track: consensus → wl-override → 2hit-valid →
    /// fast-single → lost(reason). Žádné side effects, jen rozhodnutí. Volající
    /// si pak vytáhne `verdict.commits` a podle path label populate `track.commitPath`.
    ///
    /// Důvěryhodnost shora dolů: consensus (3+ shodných hlasů) > wl-override
    /// (whitelist trust) > 2-hit-valid (2 shodné hlasy + strict CZ region) >
    /// fast-single (1 hit + strict format + width gate). Každá další cesta je
    /// méně přísná — proto chain order matters: wl-override před 2hit-valid
    /// znamená, že WL match commitne i s 2 různými reads (auto-záchrana špinavé
    /// značky), zatímco unknown auto se 2 různými reads padne až na 2hit-valid
    /// (cluster ≥ 2 vyžadováno).
    static func decideCommitVerdict(
        track t: PlateTrack,
        knownSnapshot: Set<String>,
        minHitsToCommit: Int,
        consensusOK: Bool,
        widthGateBlocks: Bool,
        widthFracMax: CGFloat,
        lostMinFrac: CGFloat,
        effectiveExitMode: Bool,
        forceCommitAfterHits: Int,
        minWinnerVoteShare: Float,
        minPlateWidthFraction: CGFloat,
        competitorTexts: [String] = []
    ) -> CommitVerdict {
        if let wait = waitForBetterReason(track: t,
                                          effectiveExitMode: effectiveExitMode,
                                          forceCommitAfterHits: forceCommitAfterHits,
                                          minWinnerVoteShare: minWinnerVoteShare,
                                          minPlateWidthFraction: minPlateWidthFraction,
                                          widthFracMax: widthFracMax) {
            return .waitForBetter(reason: wait.reason,
                                  winner: wait.winner,
                                  clusterFraction: wait.clusterFraction)
        }
        if t.hits >= minHitsToCommit, consensusOK,
           let best = t.clusterBestText() {
            return .consensus(text: best.text, region: best.region)
        }
        if let best = t.clusterBestText(),
           Self.matchesWhitelistSnapshot(best.text, snapshot: knownSnapshot) {
            return .wlOverride(text: best.text, region: best.region,
                               hits: t.hits, consensusOK: consensusOK)
        }
        if t.hits >= 2,
           let best = t.clusterBestText(),
           best.count >= 2,
           [PlateRegion.cz, .czElectric, .sk].contains(best.region),
           !widthGateBlocks {
            return .twoHitValid(text: best.text, region: best.region,
                                clusterCount: best.count,
                                totalObs: t.observations.count,
                                widthFracMax: widthFracMax)
        }
        if t.hits == 1,
           let obs = t.observations.first,
           [PlateRegion.cz, .czElectric, .sk, .foreign].contains(obs.region),
           !widthGateBlocks {
            // V exit mode `fast-single` cesta defer 1 frame pokud reading
            // není ani whitelist match, ani cross-validated. Single-frame
            // misread (Vision OCR fluke) by jinak commitl dřív než consensus
            // / 2-hit-valid track stihne. Po 1 frame defer (deferCount cap = 1)
            // fall back na fast-single — zero silent drop pro reálně rychlá auta.
            if effectiveExitMode, t.deferCount < 1 {
                let isCrossValidated = obs.origin == .crossValidated
                    || obs.origin == .crossValidatedFuzzy
                let isWhitelisted = Self.matchesWhitelistSnapshot(obs.text, snapshot: knownSnapshot)
                if !isCrossValidated && !isWhitelisted {
                    return .waitForBetter(reason: .singleHitNeedsValidation,
                                          winner: obs.text, clusterFraction: 1.0)
                }
            }
            // **Vrstva 3: fuzzy-neighbor defer.** Pokud existuje konkurenční
            // track s ambiguous-glyph variantou TÉHOŽ plate (např. `9RS0123`
            // v jiném tracku, current obs `9BS0123`), defer commit dokud
            // Vrstva 2 (cross-track snap) nerozhodne, nebo dokud konkurent
            // neexitne. Zabraňuje race-condition kdy fast-single commitne
            // misread před tím, než správný track dosáhne consensus.
            if t.deferCount < 1 {
                for competitor in competitorTexts {
                    let cmp = AmbiguousGlyphMatrix.compareWithAmbiguous(obs.text, competitor)
                    if cmp.editDistance >= 1, cmp.editDistance <= 2,
                       cmp.allMismatchesAmbiguous {
                        return .waitForBetter(reason: .fuzzyNeighbor,
                                              winner: obs.text, clusterFraction: 1.0)
                    }
                }
            }
            return .fastSingle(text: obs.text, region: obs.region,
                               widthFracMax: widthFracMax)
        }
        let winner = t.clusterBestText()?.text ?? "?"
        let reason: CommitVerdict.LostReason = widthGateBlocks ? .widthTooSmall : .noConsensus
        return .lost(reason: reason, winner: winner, hits: t.hits,
                     consensusOK: consensusOK,
                     widthFracMax: widthFracMax, lostMinFrac: lostMinFrac)
    }

    /// Jediný emit point pro Tracker rozhodnutí — stderr (back-compat grep)
    /// + `Audit.event` (strukturovaný JSONL pro replay/heatmaps). 4 commit
    /// cesty + 2 lost reasons mají identický log shape; změny payload v
    /// `CommitVerdict` se propagují bez per-callsite editace.
    static func emitVerdictLog(
        tid: Int, track t: PlateTrack, verdict: CommitVerdict,
        cameraName: String, exitMode: Bool,
        minWinnerVotes: Int, minWinnerVoteShare: Float
    ) {
        var line = "[Tracker] track=\(tid) "
        var fields: [String: Any] = [
            "track": tid, "camera": cameraName, "path": verdict.path,
            "hits": t.hits, "obs": t.observations.count, "exitMode": exitMode
        ]
        // Enrich verdict audit o computed displayConf + votes/voteShare,
        // aby post-mortem replay nemusel reproducer-em volat bestText() na
        // empty observations.
        if let best = t.bestText() {
            fields["displayConf"] = Double(best.meanConf)
            fields["votes"] = best.votes
            fields["voteShare"] = Double(best.votes) / Double(max(t.observations.count, 1))
        }
        var plateForTone: String?
        switch verdict {
        case .consensus(let text, let region):
            line += "consensus commit text=\(text) region=\(region.rawValue) hits=\(t.hits)"
            fields["plate"] = text; fields["region"] = region.rawValue
            plateForTone = text
        case .wlOverride(let text, let region, let hits, let consensusOK):
            line += "whitelist-override commit text=\(text) region=\(region.rawValue) hits=\(hits) (consensus=\(consensusOK))"
            fields["plate"] = text; fields["region"] = region.rawValue
            fields["consensus"] = consensusOK
            plateForTone = text
        case .twoHitValid(let text, let region, let cc, let total, let wfm):
            line += "2-hit-valid commit text=\(text) region=\(region.rawValue) clusterCount=\(cc) totalObs=\(total) maxWidth=\(String(format: "%.3f", wfm))"
            fields["plate"] = text; fields["region"] = region.rawValue
            fields["clusterCount"] = cc; fields["maxWidth"] = Double(wfm)
            plateForTone = text
        case .fastSingle(let text, let region, let wfm):
            line += "fast-car single-hit commit text=\(text) region=\(region.rawValue) maxWidth=\(String(format: "%.3f", wfm))"
            fields["plate"] = text; fields["region"] = region.rawValue
            fields["maxWidth"] = Double(wfm)
            plateForTone = text
        case .waitForBetter(let reason, let winner, let clusterFraction):
            line += "wait-for-better reason=\(reason.rawValue) hits=\(t.hits) winner=\(winner) cluster=\(String(format: "%.2f", clusterFraction)) deferCount=\(t.deferCount)"
            fields["plate"] = winner
            fields["reason"] = reason.rawValue
            fields["clusterFraction"] = Double(clusterFraction)
            fields["deferCount"] = t.deferCount
            plateForTone = winner
        case .lost(let reason, let winner, let hits, let consensusOK, let wfm, let lmf):
            switch reason {
            case .widthTooSmall:
                line += "LOST width-too-small hits=\(hits) winner=\(winner) maxWidth=\(String(format: "%.3f", wfm))/\(lmf)"
            case .noConsensus:
                line += "LOST hits=\(hits)/\(minWinnerVotes) consensus=\(consensusOK) winner=\(winner) obs=\(t.observations.count)"
            }
            fields["plate"] = winner; fields["reason"] = reason.rawValue
            fields["consensus"] = consensusOK
            fields["maxWidth"] = Double(wfm); fields["lostMinFrac"] = Double(lmf)
            fields["minVotes"] = minWinnerVotes
            fields["minShare"] = Double(minWinnerVoteShare)
            plateForTone = winner
        }
        if let plateForTone, let tone = t.toneMeta(matching: plateForTone) {
            fields["tone"] = tone.payload
            if case .lost = verdict {
                Audit.event("tracker_lost_with_tone", [
                    "track": tid,
                    "camera": cameraName,
                    "plate": plateForTone,
                    "path": verdict.path,
                    "tone": tone.payload
                ])
            }
        }
        line += "\n"
        FileHandle.safeStderrWrite(line.data(using: .utf8) ?? Data())
        Audit.event("tracker_verdict", fields)
    }

    static func emitDeferAudit(tid: Int,
                               track t: PlateTrack,
                               cameraName: String,
                               reason: CommitVerdict.DeferReason,
                               widthFracMax: CGFloat,
                               clusterFraction: Float) {
        Audit.event("tracker_defer", [
            "track": tid,
            "camera": cameraName,
            "reason": reason.rawValue,
            "hits": t.hits,
            "deferCount": t.deferCount,
            "widthFracMax": Double(widthFracMax),
            "clusterFraction": Double(clusterFraction),
            "winner": t.clusterBestText()?.text ?? "?"
        ])
    }
}
