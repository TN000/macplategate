import Testing
import Foundation
import CoreGraphics
@testable import SPZApp

/// Tests pro Tracker LOST path commit fallbacks — bez nich může whitelisted
/// auto, které consensus-fail (rapid průjezd, mixed reads), neotevřít závoru.
@Suite("TrackerCommitFallback")
@MainActor
struct TrackerCommitFallbackTests {

    private let workSize = CGSize(width: 1000, height: 600)
    private let bbox = CGRect(x: 100, y: 200, width: 200, height: 60)

    /// Pomocná funkce. PlateOCRReading.region je `String?` — Tracker pak
    /// region na cluster level deriives přes PlateValidator.validate(text)
    /// na update-time. Region argument tady ignorován (validator rozhodne).
    private func reading(_ text: String, conf: Float = 1.0) -> PlateOCRReading {
        PlateOCRReading(
            text: text, altTexts: [], confidence: conf,
            bbox: bbox, workBox: bbox, workSize: workSize,
            region: nil,
            workspaceImage: nil, rawWorkspaceImage: nil
        )
    }

    private func movingReading(_ text: String,
                               x: CGFloat,
                               y: CGFloat = 200,
                               width: CGFloat = 60,
                               conf: Float = 1.0) -> PlateOCRReading {
        let box = CGRect(x: x, y: y, width: width, height: width / 4.5)
        return PlateOCRReading(
            text: text, altTexts: [], confidence: conf,
            bbox: box, workBox: box, workSize: workSize,
            region: nil,
            workspaceImage: nil, rawWorkspaceImage: nil
        )
    }

    private func observation(_ text: String, frameIdx: Int, workWidth: CGFloat,
                             conf: Float = 1.0,
                             origin: PlateOCRReadingOrigin = .passOneRaw) -> PlateObservation {
        let workBox = CGRect(x: CGFloat(frameIdx * 10), y: 200,
                             width: workWidth, height: workWidth / 4.5)
        return PlateObservation(
            text: text, confidence: conf, frameIdx: frameIdx,
            bbox: workBox, workBox: workBox, workSize: workSize, region: .cz,
            origin: origin,
            isStrictValidCz: true
        )
    }

    private func track(widths: [CGFloat],
                       texts: [String]? = nil,
                       origins: [PlateOCRReadingOrigin]? = nil,
                       deferCount: Int = 0) -> PlateTrack {
        let t = PlateTrack(id: 1, bbox: bbox, frameIdx: 1)
        t.deferCount = deferCount
        for (idx, width) in widths.enumerated() {
            let text = texts?[idx] ?? "9XY1234"
            let origin = origins?[idx] ?? .passOneRaw
            t.add(observation(text, frameIdx: idx + 1, workWidth: width, origin: origin))
        }
        return t
    }

    private func verdict(for t: PlateTrack,
                         effectiveExitMode: Bool = true,
                         forceCommitAfterHits: Int = 3,
                         minWinnerVoteShare: Float = 0.65,
                         minPlateWidthFraction: CGFloat = 0.09,
                         consensusOK: Bool = true) -> CommitVerdict {
        let maxWidth = t.observations.map(\.workBox.width).max() ?? 0
        let workW = t.observations.last?.workSize.width ?? 0
        let widthFracMax = workW > 0 ? maxWidth / workW : 0
        return IoUTracker.decideCommitVerdict(
            track: t,
            knownSnapshot: [],
            minHitsToCommit: 2,
            consensusOK: consensusOK,
            widthGateBlocks: false,
            widthFracMax: widthFracMax,
            lostMinFrac: 0.02,
            effectiveExitMode: effectiveExitMode,
            forceCommitAfterHits: forceCommitAfterHits,
            minWinnerVoteShare: minWinnerVoteShare,
            minPlateWidthFraction: minPlateWidthFraction
        )
    }

    private func expectWait(_ verdict: CommitVerdict,
                            _ expected: CommitVerdict.DeferReason) {
        if case .waitForBetter(let reason, _, _) = verdict {
            #expect(reason.rawValue == expected.rawValue)
        } else {
            #expect(Bool(false), "expected waitForBetter(\(expected.rawValue)), got \(verdict.path)")
        }
    }

    /// **Whitelist override** — track má 2 hits, consensus-fail (potřeba 3 hlasy
    /// při minWinnerVotes=3), ALE plate je v KnownPlates → musí committit.
    ///
    /// Test používá synthetic plate `XX99999X` (formát nikdy v real registru)
    /// + cleanup po testu, aby singleton `KnownPlates.shared` nepersistoval
    /// garbage do `known.json` na disku.
    @Test func whitelistOverrideCommitsDespiteConsensusFail() {
        let tracker = IoUTracker()
        tracker.minHitsToCommit = 2
        tracker.forceCommitAfterHits = 6  // high — chceme jít do LOST path
        tracker.minWinnerVotes = 3        // 2 hits < 3 = consensus fail
        tracker.minWinnerVoteShare = 0.65
        tracker.maxLostFrames = 4

        // Synthetic test plate (8 chars, never appears v real CZ registru).
        let whitelistedPlate = "XX99999X"
        let alreadyExisted = KnownPlates.shared.match(whitelistedPlate) != nil
        if !alreadyExisted {
            KnownPlates.shared.add(plate: whitelistedPlate, label: "_test")
        }
        defer {
            // Cleanup — pokud test entry přidal, musíme ji odstranit aby
            // singleton state neleaknul do real `known.json` na disku.
            if !alreadyExisted {
                KnownPlates.shared.remove(plate: whitelistedPlate)
            }
        }

        // Frame 1+2: 2 hits stejné whitelisted plate. knownSnapshot musí
        // obsahovat plate aby `wlOverride` path zafiroval (synthetic plate
        // není CZ format → twoHitValid by nezachránil; jen wlOverride).
        let snapshot: Set<String> = [whitelistedPlate]
        _ = tracker.update(detections: [reading(whitelistedPlate)], frameIdx: 1, knownSnapshot: snapshot)
        _ = tracker.update(detections: [reading(whitelistedPlate)], frameIdx: 2, knownSnapshot: snapshot)

        // Frame 7+: track loses (frameIdx-lastSeen > maxLostFrames=4).
        let result = tracker.update(detections: [], frameIdx: 10, knownSnapshot: snapshot)
        let committed = result.finalized.compactMap { $0.bestText()?.text }
        #expect(committed.contains(whitelistedPlate),
                "whitelist override měla committit \(whitelistedPlate); committed=\(committed)")
    }

    /// **2-hit valid CZ format fallback** — neznámá plate s 2× shodným OCR
    /// textem + valid CZ format → commit i bez 3-vote consensus.
    @Test func twoHitValidCZFormatCommitsWithoutFullConsensus() {
        let tracker = IoUTracker()
        tracker.minHitsToCommit = 2
        tracker.forceCommitAfterHits = 6
        tracker.minWinnerVotes = 3
        tracker.minWinnerVoteShare = 0.65
        tracker.maxLostFrames = 4

        // Neznámá plate (NE v whitelistu) ale validní CZ format.
        let unknownPlate = "9XY1234"

        _ = tracker.update(detections: [reading(unknownPlate)], frameIdx: 1)
        _ = tracker.update(detections: [reading(unknownPlate)], frameIdx: 2)

        let result = tracker.update(detections: [], frameIdx: 10)
        let committed = result.finalized.compactMap { $0.bestText()?.text }
        #expect(committed.contains(unknownPlate),
                "2-hit valid-format commit selhal; committed=\(committed)")
    }

    @Test func twoHitTinyApproachingStillCommitsWithoutDefer() {
        let t = track(widths: [30, 52])
        let v = verdict(for: t)

        #expect(v.commits, "2-hit fast car must not defer; got \(v.path)")
        #expect(v.path != "wait-for-better")
    }

    @Test func threeHitTinyApproachingWaitsForBetterFrame() {
        let t = track(widths: [30, 40, 52])
        expectWait(verdict(for: t), .approachingTiny)
    }

    @Test func fuzzyContaminationWaitsForObservationPeriod() {
        let origins: [PlateOCRReadingOrigin] = [
            .crossValidatedFuzzy, .crossValidatedFuzzy, .crossValidatedFuzzy
        ]
        let t = track(widths: [100, 105, 110], origins: origins)
        expectWait(verdict(for: t), .fuzzyContamination)
    }

    @Test func exactCrossValidationAfterFuzzyClearsObservationWait() {
        let origins: [PlateOCRReadingOrigin] = [
            .crossValidatedFuzzy, .crossValidatedFuzzy, .crossValidated
        ]
        let t = track(widths: [100, 105, 110], origins: origins)
        let v = verdict(for: t)

        #expect(v.commits, "latest exact cross-validation should clear fuzzy wait; got \(v.path)")
        #expect(v.path != "wait-for-better")
    }

    @Test func exitSafetyStopsFuzzyDeferAtFourHits() {
        let origins: [PlateOCRReadingOrigin] = Array(repeating: .crossValidatedFuzzy, count: 4)
        let t = track(widths: [100, 105, 110, 112], origins: origins)
        let v = verdict(for: t, effectiveExitMode: true, forceCommitAfterHits: 3)

        #expect(v.commits, "exit safety should stop defer at 4 hits; got \(v.path)")
        #expect(v.path != "wait-for-better")
    }

    @Test func nonExitSafetyStopsFuzzyDeferAtDoubleForceHits() {
        let origins: [PlateOCRReadingOrigin] = Array(repeating: .crossValidatedFuzzy, count: 6)
        let t = track(widths: [100, 105, 110, 112, 114, 116], origins: origins)
        let v = verdict(for: t, effectiveExitMode: false, forceCommitAfterHits: 3)

        #expect(v.commits, "non-exit safety should stop defer at 6 hits; got \(v.path)")
        #expect(v.path != "wait-for-better")
    }

    @Test func deferCountCapStopsFuzzyDefer() {
        let origins: [PlateOCRReadingOrigin] = [
            .crossValidatedFuzzy, .crossValidatedFuzzy, .crossValidatedFuzzy
        ]
        let t = track(widths: [100, 105, 110], origins: origins, deferCount: 2)
        let v = verdict(for: t)

        #expect(v.commits, "defer cap should stop waiting; got \(v.path)")
        #expect(v.path != "wait-for-better")
    }

    @Test func textUnstableWaitsOnlyAfterThirdObservation() {
        let twoObs = track(widths: [100, 105], texts: ["9XY1234", "8AB4567"])
        #expect(verdict(for: twoObs).path != "wait-for-better")

        let threeObs = track(widths: [100, 105, 110],
                             texts: ["9XY1234", "8AB4567", "7CD8901"])
        expectWait(verdict(for: threeObs, consensusOK: false), .textUnstable)
    }

    /// **2-hit vanity NEsmí committit** — vanity region (signboard riziko),
    /// LOST path bez whitelist match → reject.
    @Test func twoHitVanityRejected() {
        let tracker = IoUTracker()
        tracker.minHitsToCommit = 2
        tracker.forceCommitAfterHits = 6
        tracker.minWinnerVotes = 3
        tracker.minWinnerVoteShare = 0.65
        tracker.maxLostFrames = 4

        let vanity = "CAMPS2020"  // 8-char vanity (typický signboard)
        _ = tracker.update(detections: [reading(vanity)], frameIdx: 1)
        _ = tracker.update(detections: [reading(vanity)], frameIdx: 2)

        let result = tracker.update(detections: [], frameIdx: 10)
        let committed = result.finalized.compactMap { $0.bestText()?.text }
        #expect(!committed.contains(vanity),
                "vanity 2-hit nesmí committit (signboard FP risk); committed=\(committed)")
    }

    /// **2-hit foreign rejected** — 2-hit fallback je strict pro CZ/CZ⚡/SK
    /// only. Foreign plates dnes spadají na single-hit fallback (více hits
    /// fall through na klasickou consensus path).
    @Test func twoHitForeignFallsToConsensus() {
        let tracker = IoUTracker()
        tracker.minHitsToCommit = 2
        tracker.forceCommitAfterHits = 6
        tracker.minWinnerVotes = 3
        tracker.minWinnerVoteShare = 0.65
        tracker.maxLostFrames = 4

        let foreign = "WOB ZK 295"
        _ = tracker.update(detections: [reading(foreign)], frameIdx: 1)
        _ = tracker.update(detections: [reading(foreign)], frameIdx: 2)

        let result = tracker.update(detections: [], frameIdx: 10)
        let committed = result.finalized.compactMap { $0.bestText()?.text }
        // 2-hit-valid path strict CZ/CZ⚡/SK → foreign skipne. Pak single-hit
        // fallback also skipne (hits=2, ne 1). LOST bez commit.
        #expect(!committed.contains(foreign))
    }

    /// Pozdější větší/čitelnější bbox musí přebít ranou L1 variantu. Tohle není
    /// plate-specific korekce: simuluje obecný případ, kdy OCR na malém vzdáleném
    /// snímku přečte první znak špatně a teprve později ho čte stabilně správně.
    @Test func qualityWeightedWinnerPrefersLaterLargerFrameOverEarlyVariant() {
        let track = PlateTrack(id: 1, bbox: bbox, frameIdx: 1)

        for frame in 1...4 {
            track.add(observation("0ZC0779", frameIdx: frame, workWidth: 45))
        }
        for frame in 5...7 {
            track.add(observation("3ZC0779", frameIdx: frame, workWidth: 130))
        }

        let best = track.bestText()
        #expect(best?.text == "3ZC0779",
                "pozdější větší frame musí vyhrát nad ranou malou L1 variantou; best=\(String(describing: best?.text))")
    }

    @Test func weakTrackletMergeCommitsThreeFragmentedL1Tracks() {
        let tracker = IoUTracker()
        tracker.cameraName = "vjezd"
        tracker.maxLostFrames = 0
        tracker.forceCommitAfterHits = 99
        tracker.minWinnerVotes = 3
        tracker.minWinnerVoteShare = 0.65
        tracker.minPlateWidthFraction = 0.14

        _ = tracker.update(detections: [movingReading("2S26811", x: 100)], frameIdx: 1)
        _ = tracker.update(detections: [], frameIdx: 2)
        _ = tracker.update(detections: [movingReading("2S2681", x: 150)], frameIdx: 3)
        _ = tracker.update(detections: [], frameIdx: 4)
        _ = tracker.update(detections: [movingReading("2S26811", x: 200)], frameIdx: 5)
        let result = tracker.update(detections: [], frameIdx: 6)

        let committed = result.finalized.compactMap { $0.bestText()?.text }
        #expect(committed.contains("2S26811"))
        #expect(result.finalized.contains { $0.commitPath?.hasPrefix("weak-") == true })
    }

    @Test func weakTrackletMergeBlocksNonMonotonicTrajectory() {
        let tracker = IoUTracker()
        tracker.cameraName = "vjezd"
        tracker.maxLostFrames = 0
        tracker.forceCommitAfterHits = 99
        tracker.minWinnerVotes = 3
        tracker.minWinnerVoteShare = 0.65
        tracker.minPlateWidthFraction = 0.14

        _ = tracker.update(detections: [movingReading("2S26811", x: 100)], frameIdx: 1)
        _ = tracker.update(detections: [], frameIdx: 2)
        _ = tracker.update(detections: [movingReading("2S2681", x: 200)], frameIdx: 3)
        _ = tracker.update(detections: [], frameIdx: 4)
        _ = tracker.update(detections: [movingReading("2S26811", x: 150)], frameIdx: 5)
        let result = tracker.update(detections: [], frameIdx: 6)

        #expect(result.finalized.isEmpty)
    }

    @Test func weakTrackletMergeNeverCrossesCameraBuffers() {
        let tracker = IoUTracker()
        tracker.maxLostFrames = 0
        tracker.forceCommitAfterHits = 99
        tracker.minWinnerVotes = 3
        tracker.minWinnerVoteShare = 0.65
        tracker.minPlateWidthFraction = 0.14

        tracker.cameraName = "vjezd"
        _ = tracker.update(detections: [movingReading("2S26811", x: 100)], frameIdx: 1)
        _ = tracker.update(detections: [], frameIdx: 2)

        tracker.cameraName = "vyjezd"
        _ = tracker.update(detections: [movingReading("2S2681", x: 150)], frameIdx: 3)
        _ = tracker.update(detections: [], frameIdx: 4)

        tracker.cameraName = "vjezd"
        _ = tracker.update(detections: [movingReading("2S26811", x: 200)], frameIdx: 5)
        let result = tracker.update(detections: [], frameIdx: 6)

        #expect(result.finalized.isEmpty)
    }

    @Test func weakTrackletMergeExpiresOldFragments() {
        let tracker = IoUTracker()
        tracker.cameraName = "vjezd"
        tracker.maxLostFrames = 0
        tracker.forceCommitAfterHits = 99
        tracker.minWinnerVotes = 3
        tracker.minWinnerVoteShare = 0.65
        tracker.minPlateWidthFraction = 0.14

        _ = tracker.update(detections: [movingReading("2S26811", x: 100)], frameIdx: 1)
        _ = tracker.update(detections: [], frameIdx: 2)
        _ = tracker.update(detections: [movingReading("2S2681", x: 150)], frameIdx: 35)
        _ = tracker.update(detections: [], frameIdx: 36)
        _ = tracker.update(detections: [movingReading("2S26811", x: 200)], frameIdx: 37)
        let result = tracker.update(detections: [], frameIdx: 38)

        #expect(result.finalized.isEmpty)
    }

    @Test func weakTrackletBufferPrunesExpiredFragmentsDuringIdle() {
        let tracker = IoUTracker()
        tracker.cameraName = "vjezd"
        tracker.maxLostFrames = 0
        tracker.forceCommitAfterHits = 99
        tracker.minWinnerVotes = 3
        tracker.minWinnerVoteShare = 0.65
        tracker.minPlateWidthFraction = 0.14

        _ = tracker.update(detections: [movingReading("2S26811", x: 100)], frameIdx: 1)
        _ = tracker.update(detections: [], frameIdx: 2)
        #expect(tracker.debugWeakMergeBufferedCount == 1)

        for frame in 3...40 {
            _ = tracker.update(detections: [], frameIdx: frame)
        }
        #expect(tracker.debugWeakMergeBufferedCount == 0)
    }
}
