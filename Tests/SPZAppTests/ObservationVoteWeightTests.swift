import Testing
import Foundation
import CoreGraphics
@testable import SPZApp

/// Boundary tests pro `PlateTrack.observationVoteWeight` — quality-weighted
/// per-observation vote. Pure static math function bez MainActor / state.
@Suite("ObservationVoteWeight")
struct ObservationVoteWeightTests {

    private func makeObs(frameIdx: Int, conf: Float = 1.0,
                         workWidth: CGFloat = 100, workHeight: CGFloat = 30,
                         origin: PlateOCRReadingOrigin = .passOneRaw) -> PlateObservation {
        PlateObservation(
            text: "TEST",
            confidence: conf,
            frameIdx: frameIdx,
            bbox: CGRect(x: 0, y: 0, width: workWidth, height: workHeight),
            workBox: CGRect(x: 0, y: 0, width: workWidth, height: workHeight),
            workSize: CGSize(width: 1000, height: 600),
            region: .cz,
            origin: origin
        )
    }

    /// **Sanity**: maxArea = obs area + age 0 → weight = conf × 1.0 × 1.0
    /// = nominal (≤ 1.0).
    @Test func maxAreaAndZeroAgeYieldsConfidenceFloor() {
        let obs = makeObs(frameIdx: 5, conf: 1.0, workWidth: 100, workHeight: 30)
        let area: CGFloat = 100 * 30
        let w = PlateTrack.observationVoteWeight(
            obs: obs, area: area, maxFrameIdx: 5, maxArea: area)
        // areaRatio=1 → areaWeight=1.0; recency=1.0; conf=1.0 → weight=1.0
        #expect(abs(w - 1.0) < 0.001, "expected ~1.0, got \(w)")
    }

    /// **age=0** = current frame → recencyWeight = 0.92^0 = 1.0 (no decay).
    @Test func ageZeroNoRecencyDecay() {
        let obs = makeObs(frameIdx: 10, conf: 1.0)
        let w = PlateTrack.observationVoteWeight(
            obs: obs, area: 100, maxFrameIdx: 10, maxArea: 100)
        #expect(w >= 0.99, "age=0 should not decay; got \(w)")
    }

    /// **age=100** velký → recency floor 0.35 (pow(0.92, 100) ≈ 0.0003 < 0.35).
    @Test func ageLargeFloorsAtRecencyMin() {
        let obs = makeObs(frameIdx: 0, conf: 1.0)
        let w = PlateTrack.observationVoteWeight(
            obs: obs, area: 100, maxFrameIdx: 100, maxArea: 100)
        // areaRatio=1 → areaWeight=1.0; recency floor=0.35; conf=1.0
        // → weight = 1.0 × 1.0 × 0.35 = 0.35
        #expect(abs(w - 0.35) < 0.001, "expected floor 0.35, got \(w)")
    }

    /// **maxArea = 0** edge — všechny obs mají 0 area → areaRatio fallback 1.0
    /// (treat as equal). Bez tohoto by div-by-zero / NaN.
    @Test func maxAreaZeroFallsBackToFullAreaWeight() {
        let obs = makeObs(frameIdx: 5, conf: 1.0, workWidth: 0, workHeight: 0)
        let w = PlateTrack.observationVoteWeight(
            obs: obs, area: 0, maxFrameIdx: 5, maxArea: 0)
        // areaRatio=1 (fallback); areaWeight=1.0; recency=1.0; conf=1.0 → 1.0
        #expect(abs(w - 1.0) < 0.001, "maxArea=0 should fallback ratio=1; got \(w)")
    }

    /// **conf=0** → confidence floor 0.05 (žádný 0× weight i pro silně low conf).
    @Test func zeroConfidenceFloorsAt0_05() {
        let obs = makeObs(frameIdx: 5, conf: 0.0)
        let w = PlateTrack.observationVoteWeight(
            obs: obs, area: 100, maxFrameIdx: 5, maxArea: 100)
        // confFloor=0.05; areaWeight=1.0; recency=1.0 → 0.05
        #expect(abs(w - 0.05) < 0.001, "conf=0 should floor at 0.05; got \(w)")
    }

    /// **area=0** + maxArea>0 → areaRatio=0 → areaWeight floor 0.25.
    @Test func zeroAreaFloorsAt0_25() {
        let obs = makeObs(frameIdx: 5, conf: 1.0, workWidth: 0, workHeight: 0)
        let w = PlateTrack.observationVoteWeight(
            obs: obs, area: 0, maxFrameIdx: 5, maxArea: 1000)
        // areaRatio=0; areaWeight=0.25; recency=1.0; conf=1.0 → 0.25
        #expect(abs(w - 0.25) < 0.001, "tiny obs floor at 0.25; got \(w)")
    }

    /// **Monotonicita area**: větší area → vyšší weight (do limitu 1.0).
    @Test func largerAreaGivesLargerWeight() {
        let small = makeObs(frameIdx: 5, workWidth: 50, workHeight: 15)
        let big = makeObs(frameIdx: 5, workWidth: 200, workHeight: 60)
        let wSmall = PlateTrack.observationVoteWeight(
            obs: small, area: 50 * 15, maxFrameIdx: 5, maxArea: 200 * 60)
        let wBig = PlateTrack.observationVoteWeight(
            obs: big, area: 200 * 60, maxFrameIdx: 5, maxArea: 200 * 60)
        #expect(wBig > wSmall, "big area weight \(wBig) should exceed small \(wSmall)")
    }

    /// **Monotonicita recency**: novější frame → vyšší weight.
    @Test func newerFrameGivesLargerWeight() {
        let old = makeObs(frameIdx: 1, conf: 1.0)
        let new = makeObs(frameIdx: 10, conf: 1.0)
        let wOld = PlateTrack.observationVoteWeight(
            obs: old, area: 100, maxFrameIdx: 10, maxArea: 100)
        let wNew = PlateTrack.observationVoteWeight(
            obs: new, area: 100, maxFrameIdx: 10, maxArea: 100)
        #expect(wNew > wOld, "newer frame weight \(wNew) should exceed older \(wOld)")
    }

    @Test func originPassTwoEnhancedAppliesMultiplier() {
        let obs = makeObs(frameIdx: 1, origin: .passTwoEnhanced)
        let config = OriginVoteConfig(enhancedVoteWeight: 1.75,
                                      baseVoteWeightWhenEnhancedOverlap: 0.5)
        let mult = PlateTrack.originVoteMultiplier(obs: obs, hasEnhancedOverlap: true, config: config)
        #expect(abs(mult - 1.75) < 0.001)
    }

    @Test func originCrossValidatedAppliesMultiplier() {
        let obs = makeObs(frameIdx: 1, origin: .crossValidated)
        let config = OriginVoteConfig(enhancedVoteWeight: 1.75,
                                      baseVoteWeightWhenEnhancedOverlap: 0.5,
                                      crossValidatedVoteWeight: 2.0)
        let mult = PlateTrack.originVoteMultiplier(obs: obs, hasEnhancedOverlap: true, config: config)
        #expect(abs(mult - 2.0) < 0.001)
    }

    @Test func originPassOneOverlappedAppliesPenalty() {
        let obs = makeObs(frameIdx: 1, origin: .passOneRaw)
        let config = OriginVoteConfig(enhancedVoteWeight: 1.75,
                                      baseVoteWeightWhenEnhancedOverlap: 0.5)
        let mult = PlateTrack.originVoteMultiplier(obs: obs, hasEnhancedOverlap: true, config: config)
        #expect(abs(mult - 0.5) < 0.001)
    }

    @Test func originPassOneNoOverlapNoPenalty() {
        let obs = makeObs(frameIdx: 1, origin: .passOneRaw)
        let config = OriginVoteConfig(enhancedVoteWeight: 1.75,
                                      baseVoteWeightWhenEnhancedOverlap: 0.5)
        let mult = PlateTrack.originVoteMultiplier(obs: obs, hasEnhancedOverlap: false, config: config)
        #expect(abs(mult - 1.0) < 0.001)
    }

    @Test func neutralConfigPreservesOldBehavior() {
        let raw = makeObs(frameIdx: 1, origin: .passOneRaw)
        let enhanced = makeObs(frameIdx: 1, origin: .passTwoEnhanced)
        let cross = makeObs(frameIdx: 1, origin: .crossValidated)
        #expect(abs(PlateTrack.originVoteMultiplier(obs: raw, hasEnhancedOverlap: true, config: .neutral) - 1.0) < 0.001)
        #expect(abs(PlateTrack.originVoteMultiplier(obs: enhanced, hasEnhancedOverlap: true, config: .neutral) - 1.0) < 0.001)
        #expect(abs(PlateTrack.originVoteMultiplier(obs: cross, hasEnhancedOverlap: true, config: .neutral) - 1.0) < 0.001)
    }
}
