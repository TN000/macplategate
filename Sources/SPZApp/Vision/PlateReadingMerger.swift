import CoreGraphics
import CoreImage
import Foundation

enum PlateEngineAgreement: String {
    case agree
    case l1Agree = "l1-agree"
    case disagree
    case secondaryEmpty = "secondary-empty"
}

/// Per-session live counters pro Settings → Engine stats card.
/// `@unchecked Sendable` protože counter je atomic přes NSLock.
final class EngineStats: @unchecked Sendable {
    static let shared = EngineStats()

    private let lock = NSLock()
    private(set) var visionTotal: Int = 0          // všechny Vision readings (i kratké)
    private(set) var secondaryCalled: Int = 0      // ≥ 5 chars, šly do secondary
    private(set) var secondarySkipped: Int = 0     // < 5 chars, junk filter
    private(set) var bothAgreed: Int = 0           // exact match
    private(set) var l1Agreed: Int = 0             // L-1 fuzzy
    private(set) var disagreed: Int = 0            // diff text
    private(set) var secondaryEmpty: Int = 0       // secondary nic nevrátil
    private(set) var startedAt: Date = Date()

    func bumpVision() {
        lock.lock(); defer { lock.unlock() }
        visionTotal += 1
    }
    func bumpSkipped() {
        lock.lock(); defer { lock.unlock() }
        secondarySkipped += 1
    }
    func bumpAgreement(_ agreement: PlateEngineAgreement) {
        lock.lock(); defer { lock.unlock() }
        secondaryCalled += 1
        switch agreement {
        case .agree: bothAgreed += 1
        case .l1Agree: l1Agreed += 1
        case .disagree: disagreed += 1
        case .secondaryEmpty: secondaryEmpty += 1
        }
    }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        visionTotal = 0
        secondaryCalled = 0
        secondarySkipped = 0
        bothAgreed = 0
        l1Agreed = 0
        disagreed = 0
        secondaryEmpty = 0
        startedAt = Date()
    }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(visionTotal: visionTotal, secondaryCalled: secondaryCalled,
                        secondarySkipped: secondarySkipped, bothAgreed: bothAgreed,
                        l1Agreed: l1Agreed, disagreed: disagreed,
                        secondaryEmpty: secondaryEmpty, startedAt: startedAt)
    }
    struct Snapshot: Sendable {
        let visionTotal: Int
        let secondaryCalled: Int
        let secondarySkipped: Int
        let bothAgreed: Int
        let l1Agreed: Int
        let disagreed: Int
        let secondaryEmpty: Int
        let startedAt: Date
    }
}

/// Cross-validates Apple Vision readings against an optional recognizer plugin.
///
/// Phase A intentionally keeps the production call path no-op when no secondary
/// engine is registered. `mergeWithSecondary(...)` contains the future active path
/// and is covered by unit tests without requiring a bundled OCR model.
enum PlateReadingMerger {
    /// Minimální délka Vision textu (po canonicalize, bez mezer) aby šel do
    /// secondary engine. Empiricky 89 % calls je 1-3 char junk z scenérie
    /// (světlomety, čísla domů, písmena z nápisů). Plate min length:
    /// CZ 6 chars (3 digit + 3 alphanum nebo regional 7), foreign 5+. Cap
    /// na 5 nechá projít všechny opravdové plate, odřízne 90 % spam volání.
    static let minTextLengthForSecondary: Int = 5

    static func merge(visionReadings: [PlateOCRReading],
                      secondaryEngine: PlateRecognitionEngine?) -> [PlateOCRReading] {
        // Synchronous scaffold for the existing GCD OCR pipeline. A real secondary
        // engine is async and will be wired in Phase B/C after model validation.
        guard secondaryEngine != nil else { return visionReadings }
        return visionReadings
    }

    static func mergeWithSecondary(visionReadings: [PlateOCRReading],
                                   secondaryEngine: PlateRecognitionEngine?,
                                   cameraID: String = "default",
                                   audit: Bool = true) async -> [PlateOCRReading] {
        guard let secondaryEngine else { return visionReadings }
        var merged: [PlateOCRReading] = []
        merged.reserveCapacity(visionReadings.count)

        for reading in visionReadings {
            EngineStats.shared.bumpVision()
            // Filter: pokud Vision text je příliš krátký (1-4 chars), neposílat
            // do secondary. To eliminuje 90 % zbytečných volání (junk fragments
            // z scenérie). Pass-through bez audit_consensus event aby se log
            // neplnil "secondary-empty" záznamy o ničem.
            let canonical = PlateText.canonicalize(reading.text)
            if canonical.count < Self.minTextLengthForSecondary {
                EngineStats.shared.bumpSkipped()
                merged.append(reading)
                continue
            }
            guard let crop = cropForSecondaryEngine(reading) else {
                if audit {
                    auditConsensus(engine: secondaryEngine.name,
                                   reading: reading,
                                   secondary: nil,
                                   agreement: .secondaryEmpty,
                                   boostedConfidence: reading.confidence)
                }
                merged.append(reading)
                continue
            }

            let t0 = Date()
            let secondary = await secondaryEngine.recognize(crop: crop)
            let ms = Date().timeIntervalSince(t0) * 1000
            if audit {
                Audit.event("engine_inference", [
                    "engine": secondaryEngine.name,
                    "text": secondary?.text ?? "",
                    "confidence": secondary?.confidence ?? 0,
                    "ms": ms,
                    "bbox": bboxPayload(reading.workBox)
                ])
            }

            guard let secondary else {
                EngineStats.shared.bumpAgreement(.secondaryEmpty)
                if audit {
                    auditConsensus(engine: secondaryEngine.name,
                                   reading: reading,
                                   secondary: nil,
                                   agreement: .secondaryEmpty,
                                   boostedConfidence: reading.confidence)
                }
                merged.append(reading)
                continue
            }

            // **OCR shadow mode:** deterministic sample-gated SR upscale + secondary
            // OCR re-run. Result NEVER replaces baseline — log only.
            await runOCRShadowIfEligible(crop: crop,
                                         baseline: secondary,
                                         visionReading: reading,
                                         cameraID: cameraID,
                                         secondaryEngine: secondaryEngine,
                                         audit: audit)

            let agreement = agreement(vision: reading.text, secondary: secondary.text)
            EngineStats.shared.bumpAgreement(agreement)
            switch agreement {
            case .agree:
                let boosted = crossValidatedReading(reading, secondary: secondary,
                                                    origin: .crossValidated)
                if audit {
                    auditConsensus(engine: secondaryEngine.name,
                                   reading: reading,
                                   secondary: secondary,
                                   agreement: agreement,
                                   boostedConfidence: boosted.confidence)
                }
                merged.append(boosted)
            case .l1Agree:
                let flagged = crossValidatedReading(reading, secondary: secondary,
                                                    origin: .crossValidatedFuzzy)
                if audit {
                    auditConsensus(engine: secondaryEngine.name,
                                   reading: reading,
                                   secondary: secondary,
                                   agreement: agreement,
                                   boostedConfidence: flagged.confidence)
                }
                merged.append(flagged)
            case .disagree:
                if audit {
                    auditConsensus(engine: secondaryEngine.name,
                                   reading: reading,
                                   secondary: secondary,
                                   agreement: agreement,
                                   boostedConfidence: reading.confidence)
                }
                // **Majority vote fix:** secondary text se neztratí — zapíše se
                // do `secondaryText` na readingu. Tracker pak v clusterBestText
                // počítá secondary jako další hlas (per obs 2 votes), takže
                // disagreeing reads dostávají fair frequency vote.
                let canonical = PlateText.canonicalize(secondary.text)
                if canonical.count >= 5 {
                    merged.append(disagreeReadingWithSecondaryVote(reading, secondary: secondary))
                } else {
                    merged.append(reading)
                }
            case .secondaryEmpty:
                if audit {
                    auditConsensus(engine: secondaryEngine.name,
                                   reading: reading,
                                   secondary: secondary,
                                   agreement: agreement,
                                   boostedConfidence: reading.confidence)
                }
                merged.append(reading)
            }
        }
        return merged
    }

    static func agreement(vision: String, secondary: String) -> PlateEngineAgreement {
        let v = PlateText.canonicalize(vision)
        let s = PlateText.canonicalize(secondary)
        guard !v.isEmpty, !s.isEmpty else { return .secondaryEmpty }
        if v == s { return .agree }
        if PlateTrack.isL1(v, s) { return .l1Agree }
        return .disagree
    }

    private static func crossValidatedReading(_ reading: PlateOCRReading,
                                              secondary: EngineReading,
                                              origin: PlateOCRReadingOrigin) -> PlateOCRReading {
        let strict = reading.isStrictValidCz || PlateText.from(raw: reading.text)?.isStrictValid == true
        return PlateOCRReading(text: reading.text,
                               altTexts: reading.altTexts,
                               confidence: reading.confidence,
                               bbox: reading.bbox,
                               workBox: reading.workBox,
                               workSize: reading.workSize,
                               region: reading.region,
                               workspaceImage: reading.workspaceImage,
                               rawWorkspaceImage: reading.rawWorkspaceImage,
                               origin: origin,
                               isStrictValidCz: strict,
                               secondaryText: secondary.text,
                               secondaryConfidence: secondary.confidence,
                               toneMeta: reading.toneMeta)
    }

    /// Pro `disagree` case — keep Vision text + region/origin, ALE uložit
    /// secondary text jako alt vote do `secondaryText`. Tracker pak v majority
    /// vote počítá secondary jako další hlas (dvě plausible čtení per obs).
    private static func disagreeReadingWithSecondaryVote(_ reading: PlateOCRReading,
                                                          secondary: EngineReading) -> PlateOCRReading {
        return PlateOCRReading(text: reading.text,
                               altTexts: reading.altTexts,
                               confidence: reading.confidence,
                               bbox: reading.bbox,
                               workBox: reading.workBox,
                               workSize: reading.workSize,
                               region: reading.region,
                               workspaceImage: reading.workspaceImage,
                               rawWorkspaceImage: reading.rawWorkspaceImage,
                               origin: reading.origin,
                               isStrictValidCz: reading.isStrictValidCz,
                               secondaryText: secondary.text,
                               secondaryConfidence: secondary.confidence,
                               toneMeta: reading.toneMeta)
    }

    private static func cropForSecondaryEngine(_ reading: PlateOCRReading) -> CGImage? {
        guard let workspace = reading.workspaceImage,
              reading.workBox.width > 1,
              reading.workBox.height > 1,
              reading.workSize.width > 0,
              reading.workSize.height > 0 else {
            return nil
        }
        let sx = CGFloat(workspace.width) / reading.workSize.width
        let sy = CGFloat(workspace.height) / reading.workSize.height
        let scaledRect = CGRect(x: reading.workBox.minX * sx,
                                y: reading.workBox.minY * sy,
                                width: reading.workBox.width * sx,
                                height: reading.workBox.height * sy)
        // **Padding kolem Vision bbox:** Vision vrací pixel-tight bbox kolem
        // textu, ale CCT model FastPlateOCR cct-xs-v2-global byl trained na
        // crops s 8–15% paddingem kolem plate okrajů. Bez paddingu je first
        // znak často oříznutý → misread (model attention dependence on boundary).
        // 12% vert + 18% horiz (plate aspect ~4.7:1, horiz padding víc kvůli
        // wide glyphs).
        let padH = scaledRect.height * 0.12
        let padW = scaledRect.width * 0.18
        let padded = scaledRect.insetBy(dx: -padW, dy: -padH).integral
        let rect = padded.intersection(CGRect(x: 0, y: 0,
                                              width: workspace.width,
                                              height: workspace.height))
        guard !rect.isNull, rect.width >= 2, rect.height >= 2 else { return nil }
        guard let croppedCG = workspace.cropping(to: rect) else { return nil }
        // **Auto white balance:** secondary engine input má stejný color cast
        // issue jako Vision input. Eliminuj modrofialový cast PŘED ONNX inference
        // — secondary engine pak dostane neutral plate crop.
        let ci = CIImage(cgImage: croppedCG)
        let extent = CGRect(x: 0, y: 0, width: croppedCG.width, height: croppedCG.height)
        let balanced = PlateOCR.applyGrayWorldWhiteBalance(ci, extent: extent)
        // Pokud AWB no-op (image už neutral), reuse original CGImage.
        if balanced === ci { return croppedCG }
        return SharedCIContext.shared.createCGImage(balanced, from: extent) ?? croppedCG
    }

    private static func auditConsensus(engine: String,
                                       reading: PlateOCRReading,
                                       secondary: EngineReading?,
                                       agreement: PlateEngineAgreement,
                                       boostedConfidence: Float) {
        Audit.event("engine_consensus", [
            "engine": engine,
            "vision": reading.text,
            "secondary": secondary?.text ?? "",
            "agreement": agreement.rawValue,
            "boosted_confidence": boostedConfidence
        ])
    }

    private static func bboxPayload(_ rect: CGRect) -> [String: Double] {
        [
            "x": Double(rect.minX),
            "y": Double(rect.minY),
            "w": Double(rect.width),
            "h": Double(rect.height)
        ]
    }

    // MARK: - OCR shadow mode (Fáze B1)

    /// Run SR + secondary OCR on shadow-eligible crops, log result, NEVER accept.
    /// Sampling is deterministic — same (cameraID, trackID, crop hash) → same bucket
    /// across calls, easier trend analysis vs random.
    private static func runOCRShadowIfEligible(crop: CGImage,
                                                baseline: EngineReading,
                                                visionReading: PlateOCRReading,
                                                cameraID: String,
                                                secondaryEngine: PlateRecognitionEngine,
                                                audit: Bool) async {
        let masterEnabled = AppState.usePlateSuperResolutionFlag.withLock { $0 }
        let shadowEnabled = AppState.usePlateSRForOCRShadowFlag.withLock { $0 }
        let sampleRate = AppState.plateSRShadowRateFlag.withLock { $0 }
        guard masterEnabled, shadowEnabled, sampleRate > 0, audit else { return }

        // Deterministic bucket from (cameraID, text, bbox area) — stable per crop.
        let cropFingerprint = UInt64(bitPattern: Int64(visionReading.text.hashValue))
            ^ UInt64(visionReading.workBox.width.bitPattern)
        let trackID = visionReading.text  // canonical-ish; arbiter F2 will use real track ID
        guard PlateSRPolicy.shouldShadowSample(cameraID: cameraID,
                                                trackID: trackID,
                                                cropFingerprint: cropFingerprint,
                                                rate: sampleRate) else {
            return
        }

        // Policy gate
        let metadata = PlateCropMetadata(
            cameraID: cameraID,
            trackID: trackID,
            cropRect: visionReading.workBox,
            detectionConfidence: Double(baseline.confidence)
        )
        let decision = PlateSRPolicy.decide(
            crop: crop, purpose: .secondaryOCR,
            metadata: metadata,
            baselineConfidence: Double(baseline.confidence),
            baselineTextValid: matchesCZRegex(normalize(baseline.text)),
            baselineTrackConfirmed: false,  // F1: don't have track confirmation yet
            userMasterEnabled: true,
            userPurposeEnabled: true
        )
        guard decision.shouldApply else {
            // Skip but don't spam logs — only log on rate-limited path.
            return
        }

        let srResult = PlateSREngine.shared.upscale4x(crop, purpose: .secondaryOCR, metadata: metadata)
        guard case .applied(let srCG, let srMetrics) = srResult else { return }

        // Run secondary engine again on SR'd crop.
        let srOCR = await secondaryEngine.recognize(crop: srCG)

        let baselineNorm = normalize(baseline.text)
        let srNorm = srOCR.map { normalize($0.text) } ?? ""
        let editDist = levenshtein(baselineNorm, srNorm)
        let baselineRegex = matchesCZRegex(baselineNorm)
        let srRegex = matchesCZRegex(srNorm)
        let ambiguous = isAmbiguousGlyphSwap(baselineNorm, srNorm)

        // Simulated arbiter decision (Fáze F2 wouldAccept logic, simplified here):
        let wouldAccept = (srOCR != nil
                           && srRegex
                           && Float(srOCR!.confidence) > baseline.confidence + 0.05
                           && (editDist == 0 || (!ambiguous && Float(srOCR!.confidence) > baseline.confidence + 0.10)))

        Audit.event("super_resolution_ocr_shadow", [
            "purpose": "secondaryOCR",
            "crop_w": crop.width,
            "crop_h": crop.height,
            "baseline_text_raw": baseline.text,
            "baseline_text_norm": baselineNorm,
            "baseline_conf": Double(baseline.confidence),
            "sr_text_raw": srOCR?.text ?? "",
            "sr_text_norm": srNorm,
            "sr_conf": Double(srOCR?.confidence ?? 0),
            "edit_distance_norm": editDist,
            "baseline_regex_valid": baselineRegex,
            "sr_regex_valid": srRegex,
            "ambiguous_flip": ambiguous,
            "track_conflict": false,  // not yet wired to tracker history
            "would_accept": wouldAccept,
            "sr_inference_ms": srMetrics.inferenceMs,
            "cache_hit": srMetrics.cacheHit,
            "sample_rate": sampleRate,
        ])
    }

    private static func normalize(_ s: String) -> String {
        s.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func matchesCZRegex(_ norm: String) -> Bool {
        // Loose CZ plate validator: 7 alphanum chars (1 digit + 2 letters + 4 digits typical).
        guard norm.count == 7 else { return false }
        return norm.allSatisfy { $0.isLetter || $0.isNumber }
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let aArr = Array(a), bArr = Array(b)
        let m = aArr.count, n = bArr.count
        if m == 0 { return n }
        if n == 0 { return m }
        var prev = Array(0...n)
        var curr = [Int](repeating: 0, count: n + 1)
        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = aArr[i-1] == bArr[j-1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j-1] + 1, prev[j-1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[n]
    }

    private static let ambiguousPairs: [(Character, Character)] = [
        ("8", "B"), ("0", "O"), ("5", "S"), ("1", "I"), ("2", "Z"), ("6", "G"),
    ]

    private static func isAmbiguousGlyphSwap(_ a: String, _ b: String) -> Bool {
        guard a.count == b.count, a != b else { return false }
        for (ca, cb) in zip(a, b) where ca != cb {
            let normalized = (ca <= cb) ? (ca, cb) : (cb, ca)
            let isAmbiguous = ambiguousPairs.contains { pair in
                let p = (pair.0 <= pair.1) ? pair : (pair.1, pair.0)
                return p == normalized
            }
            if !isAmbiguous { return false }
        }
        return true
    }
}
