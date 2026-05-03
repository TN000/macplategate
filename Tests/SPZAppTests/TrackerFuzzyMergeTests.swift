import Testing
import Foundation
import CoreGraphics
@testable import SPZApp

/// Tests pro tracker fuzzy-merge — 4-vrstvá obrana proti fragmentaci tracků
/// způsobené ambiguous-glyph swapy (S↔B / 0↔O / 8↔B atd.) v OCR výstupu.
@Suite("TrackerFuzzyMerge")
@MainActor
struct TrackerFuzzyMergeTests {

    private let workSize = CGSize(width: 1000, height: 600)

    private func reading(_ text: String, x: CGFloat, conf: Float = 0.8) -> PlateOCRReading {
        let box = CGRect(x: x, y: 200, width: 220, height: 60)
        return PlateOCRReading(
            text: text, altTexts: [], confidence: conf,
            bbox: box, workBox: box, workSize: workSize,
            region: nil,
            workspaceImage: nil, rawWorkspaceImage: nil
        )
    }

    /// Vrstva 2 isolated window: IoU 0.10-0.25 (under regular threshold, above
    /// fuzzy floor). Bez Vrstvy 2 by vznikly 2 tracks (IoU < threshold → new).
    /// Pozice: bbox A [100,320], bbox B [263,483] → overlap=57, union=383 →
    /// IoU ≈ 0.149, v window pro fuzzy snap.
    @Test("Vrstva 2: ambiguous swap v fuzzy-IoU window → cross-track snap")
    func crossTrackFuzzySnapInWindow() {
        let tracker = IoUTracker()
        _ = tracker.update(detections: [reading("2S32376", x: 100)],
                           frameIdx: 1, knownSnapshot: [])
        // Frame 2: x=263 → IoU ≈ 0.15 — pod regular threshold, ale ambiguous
        // swap S↔B → Vrstva 2 snap.
        let final = tracker.update(detections: [reading("2B32376", x: 263)],
                                   frameIdx: 2, knownSnapshot: [])
        let active = final.active
        #expect(active.count == 1, "Expected fuzzy-merged single track, got \(active.count)")
        if let onlyTrack = active.first {
            let texts = onlyTrack.observations.map { $0.text }
            #expect(texts.contains("2S32376"))
            #expect(texts.contains("2B32376"))
        }
    }

    /// Non-ambiguous mismatch ve stejném IoU window → Vrstva 2 nesn ap-uje
    /// (allMismatchesAmbiguous = false). 2 separate tracks. Předchází false
    /// merge mezi reálnými 2 různými auty se shodným bbox-em.
    @Test("Vrstva 2: non-ambiguous v fuzzy-IoU window → 2 separate tracks")
    func nonAmbiguousInWindowKeepsSeparate() {
        let tracker = IoUTracker()
        _ = tracker.update(detections: [reading("2S32376", x: 100)],
                           frameIdx: 1, knownSnapshot: [])
        let final = tracker.update(detections: [reading("2X32376", x: 263)],
                                   frameIdx: 2, knownSnapshot: [])
        let active = final.active
        #expect(active.count == 2, "Expected 2 separate tracks (X↔S not ambiguous), got \(active.count)")
    }

    /// IoU < 0.10 (auto na druhé straně frame) → ne-snap. Ambiguous text sám
    /// nestačí, musí být lokálně blízko.
    @Test("IoU < 0.10: 2S32376 vs 2B32376 v různých regionech → 2 separate tracks")
    func iouTooLowDoesNotSnap() {
        let tracker = IoUTracker()
        _ = tracker.update(detections: [reading("2S32376", x: 50)],
                           frameIdx: 1, knownSnapshot: [])
        let final = tracker.update(detections: [reading("2B32376", x: 800)],
                                   frameIdx: 2, knownSnapshot: [])
        let active = final.active
        #expect(active.count == 2, "Expected 2 separate tracks (IoU < 0.10), got \(active.count)")
    }

    /// Vrstva 3: fastSingle defer kdyz existuje fuzzy-neighbor track.
    @Test("Vrstva 3: fastSingle s competitor 2S32376 → defer .fuzzyNeighbor")
    func fastSingleDeferOnFuzzyNeighbor() {
        let bbox = CGRect(x: 100, y: 200, width: 220, height: 60)
        let t = PlateTrack(id: 1, bbox: bbox, frameIdx: 1)
        t.add(PlateObservation(
            text: "2B32376", confidence: 0.7, frameIdx: 1,
            bbox: bbox, workBox: bbox, workSize: workSize, region: .cz,
            origin: .passOneRaw,
            isStrictValidCz: true
        ))
        // Track má 1 hit, valid CZ region — bez Vrstvy 3 = fastSingle commit.
        // S Vrstvou 3 + competitor "2S32376" → waitForBetter(.fuzzyNeighbor)
        let verdict = IoUTracker.decideCommitVerdict(
            track: t,
            knownSnapshot: [],
            minHitsToCommit: 2,
            consensusOK: false,
            widthGateBlocks: false,
            widthFracMax: 0.22,
            lostMinFrac: 0.02,
            effectiveExitMode: false,
            forceCommitAfterHits: 3,
            minWinnerVoteShare: 0.65,
            minPlateWidthFraction: 0.09,
            competitorTexts: ["2S32376"]
        )
        if case .waitForBetter(let reason, _, _) = verdict {
            #expect(reason == .fuzzyNeighbor)
        } else {
            #expect(Bool(false), "expected waitForBetter(.fuzzyNeighbor), got \(verdict.path)")
        }
    }

    /// Bez competitor → fastSingle commits jako dříve (bez regrese).
    @Test("Vrstva 3: fastSingle bez competitor → commits jako fastSingle")
    func fastSingleCommitsWithoutCompetitor() {
        let bbox = CGRect(x: 100, y: 200, width: 220, height: 60)
        let t = PlateTrack(id: 1, bbox: bbox, frameIdx: 1)
        t.add(PlateObservation(
            text: "2B32376", confidence: 0.7, frameIdx: 1,
            bbox: bbox, workBox: bbox, workSize: workSize, region: .cz,
            origin: .passOneRaw,
            isStrictValidCz: true
        ))
        let verdict = IoUTracker.decideCommitVerdict(
            track: t,
            knownSnapshot: [],
            minHitsToCommit: 2,
            consensusOK: false,
            widthGateBlocks: false,
            widthFracMax: 0.22,
            lostMinFrac: 0.02,
            effectiveExitMode: false,
            forceCommitAfterHits: 3,
            minWinnerVoteShare: 0.65,
            minPlateWidthFraction: 0.09,
            competitorTexts: []
        )
        if case .fastSingle = verdict {
            // OK
        } else {
            #expect(Bool(false), "expected fastSingle, got \(verdict.path)")
        }
    }

    /// Non-ambiguous competitor → ne-defer, fastSingle prošel.
    @Test("Vrstva 3: competitor 2X32376 (non-ambiguous) → fastSingle prošel")
    func nonAmbiguousCompetitorDoesNotDeferFastSingle() {
        let bbox = CGRect(x: 100, y: 200, width: 220, height: 60)
        let t = PlateTrack(id: 1, bbox: bbox, frameIdx: 1)
        t.add(PlateObservation(
            text: "2B32376", confidence: 0.7, frameIdx: 1,
            bbox: bbox, workBox: bbox, workSize: workSize, region: .cz,
            origin: .passOneRaw,
            isStrictValidCz: true
        ))
        let verdict = IoUTracker.decideCommitVerdict(
            track: t,
            knownSnapshot: [],
            minHitsToCommit: 2,
            consensusOK: false,
            widthGateBlocks: false,
            widthFracMax: 0.22,
            lostMinFrac: 0.02,
            effectiveExitMode: false,
            forceCommitAfterHits: 3,
            minWinnerVoteShare: 0.65,
            minPlateWidthFraction: 0.09,
            competitorTexts: ["2X32376"]  // X↔B není ambiguous
        )
        if case .fastSingle = verdict {
            // OK
        } else {
            #expect(Bool(false), "expected fastSingle, got \(verdict.path)")
        }
    }
}
