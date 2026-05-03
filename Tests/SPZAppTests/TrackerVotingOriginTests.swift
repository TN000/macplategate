import Testing
import Foundation
import CoreGraphics
@testable import SPZApp

@Suite("TrackerVotingOrigin")
struct TrackerVotingOriginTests {
    private let workSize = CGSize(width: 1000, height: 600)
    private let box = CGRect(x: 100, y: 120, width: 220, height: 55)

    private func obs(_ text: String,
                     frame: Int,
                     conf: Float,
                     origin: PlateOCRReadingOrigin,
                     strict: Bool,
                     box: CGRect? = nil) -> PlateObservation {
        let b = box ?? self.box
        return PlateObservation(
            text: text,
            confidence: conf,
            frameIdx: frame,
            bbox: b,
            workBox: b,
            workSize: workSize,
            region: .cz,
            origin: origin,
            isStrictValidCz: strict
        )
    }

    @Test func enhancedValidCzWinsOverHigherWeightedRaw() {
        let track = PlateTrack(id: 1, bbox: box, frameIdx: 1)
        track.originVoteConfig = OriginVoteConfig(enhancedVoteWeight: 1.75,
                                                  baseVoteWeightWhenEnhancedOverlap: 0.5)

        track.add(obs("0ZC0779", frame: 1, conf: 0.91, origin: .passOneRaw, strict: false))
        track.add(obs("0ZC0779", frame: 2, conf: 0.91, origin: .passOneRaw, strict: false))
        track.add(obs("0ZC0779", frame: 3, conf: 0.91, origin: .passOneRaw, strict: false))
        track.add(obs("3ZC0779", frame: 4, conf: 0.88, origin: .passTwoEnhanced, strict: true))

        #expect(track.bestText()?.text == "3ZC0779")
    }

    @Test func enhancedNotValidCzFallsBackToWeight() {
        let track = PlateTrack(id: 1, bbox: box, frameIdx: 1)
        track.originVoteConfig = .neutral

        track.add(obs("0ZC0779", frame: 1, conf: 0.91, origin: .passOneRaw, strict: false))
        track.add(obs("0ZC0779", frame: 2, conf: 0.91, origin: .passOneRaw, strict: false))
        track.add(obs("0ZC0779", frame: 3, conf: 0.91, origin: .passOneRaw, strict: false))
        track.add(obs("ST21234", frame: 4, conf: 0.99, origin: .passTwoEnhanced, strict: false))

        #expect(track.bestText()?.text == "0ZC0779")
    }

    @Test func crossValidatedObservationUsesStrongVoteWeight() {
        let track = PlateTrack(id: 1, bbox: box, frameIdx: 1)
        track.originVoteConfig = OriginVoteConfig(enhancedVoteWeight: 1.75,
                                                  baseVoteWeightWhenEnhancedOverlap: 0.5,
                                                  crossValidatedVoteWeight: 2.0)

        track.add(obs("0ZC0779", frame: 1, conf: 0.80, origin: .passOneRaw, strict: false))
        track.add(obs("3ZC0779", frame: 2, conf: 0.80, origin: .crossValidated, strict: true))

        #expect(track.bestText()?.text == "3ZC0779")
    }

    @Test func mixedOriginPenaltyAppliesOnlyWhenOverlap() {
        let raw = obs("0ZC0779", frame: 1, conf: 0.91, origin: .passOneRaw, strict: false)
        let config = OriginVoteConfig(enhancedVoteWeight: 1.75,
                                      baseVoteWeightWhenEnhancedOverlap: 0.5)

        let overlapped = PlateTrack.originVoteMultiplier(obs: raw, hasEnhancedOverlap: true, config: config)
        let separate = PlateTrack.originVoteMultiplier(obs: raw, hasEnhancedOverlap: false, config: config)

        #expect(abs(overlapped - 0.5) < 0.001)
        #expect(abs(separate - 1.0) < 0.001)
    }

    @Test func exitModeRelaxesIouThresholdForFastBBoxJumps() {
        let first = CGRect(x: 0, y: 0, width: 100, height: 40)
        let shifted = CGRect(x: 60, y: 0, width: 100, height: 40) // IoU = 0.25

        let normal = IoUTracker()
        normal.iouThreshold = 0.30
        normal.forceCommitAfterHits = 99
        _ = normal.update(detections: [reading("6L21056", box: first)], frameIdx: 1)
        let normalResult = normal.update(detections: [reading("6L21056", box: shifted)], frameIdx: 2)
        #expect(normalResult.active.count == 2)

        let exit = IoUTracker()
        exit.iouThreshold = 0.30
        exit.exitMode = true
        exit.forceCommitAfterHits = 99
        _ = exit.update(detections: [reading("6L21056", box: first)], frameIdx: 1)
        let exitResult = exit.update(detections: [reading("6L21056", box: shifted)], frameIdx: 2)
        #expect(exitResult.active.count == 1)
        #expect(exitResult.active.first?.hits == 2)
    }

    @Test func exitModeTextRescueMatchesSamePlateEvenWhenIouIsZero() {
        let first = CGRect(x: 0, y: 0, width: 100, height: 40)
        let jumped = CGRect(x: 160, y: 8, width: 100, height: 42) // IoU = 0, fast exit jump

        let normal = IoUTracker()
        normal.iouThreshold = 0.30
        normal.forceCommitAfterHits = 99
        _ = normal.update(detections: [reading("6L21056", box: first)], frameIdx: 1)
        let normalResult = normal.update(detections: [reading("6L21056", box: jumped)], frameIdx: 2)
        #expect(normalResult.active.count == 2)

        let exit = IoUTracker()
        exit.iouThreshold = 0.30
        exit.exitMode = true
        exit.forceCommitAfterHits = 99
        _ = exit.update(detections: [reading("6L21056", box: first)], frameIdx: 1)
        let exitResult = exit.update(detections: [reading("6L21056", box: jumped)], frameIdx: 2)
        #expect(exitResult.active.count == 1)
        #expect(exitResult.active.first?.hits == 2)
    }

    @Test func exitModeTextRescueDoesNotMergeDifferentPlateText() {
        let first = CGRect(x: 0, y: 0, width: 100, height: 40)
        let jumped = CGRect(x: 160, y: 8, width: 100, height: 42)

        let exit = IoUTracker()
        exit.iouThreshold = 0.30
        exit.exitMode = true
        exit.forceCommitAfterHits = 99
        _ = exit.update(detections: [reading("6L21056", box: first)], frameIdx: 1)
        let result = exit.update(detections: [reading("1ZA4407", box: jumped)], frameIdx: 2)

        #expect(result.active.count == 2)
        #expect(result.active.map(\.hits).sorted() == [1, 1])
    }

    private func reading(_ text: String, box: CGRect) -> PlateOCRReading {
        PlateOCRReading(
            text: text,
            altTexts: [],
            confidence: 0.95,
            bbox: box,
            workBox: box,
            workSize: workSize,
            region: nil,
            workspaceImage: nil,
            rawWorkspaceImage: nil
        )
    }
}
