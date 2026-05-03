import Testing
import Foundation
import CoreGraphics
@testable import SPZApp

@Suite("PlateSRPolicy")
struct PlateSRPolicyTests {

    private static func makeImage(width: Int, height: Int,
                                  fill: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = fill(x, y)
                let i = (y * width + x) * 4
                bytes[i + 0] = r
                bytes[i + 1] = g
                bytes[i + 2] = b
                bytes[i + 3] = 255
            }
        }
        return bytes.withUnsafeMutableBytes { raw -> CGImage in
            let base = raw.baseAddress!
            let ctx = CGContext(data: base, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return ctx.makeImage()!
        }
    }

    private static func makeMeta(w: Int, h: Int, conf: Double = 0.9) -> PlateCropMetadata {
        PlateCropMetadata(cameraID: "test", trackID: nil,
                          cropRect: CGRect(x: 0, y: 0, width: w, height: h),
                          detectionConfidence: conf)
    }

    @Test("Master toggle off → disabledByUser")
    func masterToggleOff() {
        let img = Self.makeImage(width: 100, height: 30) { _, _ in (128, 128, 128) }
        let d = PlateSRPolicy.decide(crop: img, purpose: .snapshot,
                                     metadata: Self.makeMeta(w: 100, h: 30),
                                     userMasterEnabled: false)
        #expect(!d.shouldApply)
        #expect(d.reason == .disabledByUser)
    }

    @Test("Crop too small → cropTooSmall")
    func cropTooSmall() {
        let img = Self.makeImage(width: 20, height: 8) { _, _ in (128, 128, 128) }
        let d = PlateSRPolicy.decide(crop: img, purpose: .snapshot,
                                     metadata: Self.makeMeta(w: 20, h: 8))
        #expect(d.reason == .cropTooSmall)
    }

    @Test("OCR cropTooLarge stricter than snapshot")
    func purposeSpecificCropTooLarge() {
        // 280×100 — over OCR threshold (260×90), but under snapshot threshold (420×140).
        let img = Self.makeImage(width: 280, height: 100) { x, y in
            let v = UInt8((x * 255) / 280)  // gradient → high dynamic range
            return (v, v, v)
        }
        let metaOCR = Self.makeMeta(w: 280, h: 100)
        let dOCR = PlateSRPolicy.decide(crop: img, purpose: .visionRetry, metadata: metaOCR)
        #expect(dOCR.reason == .cropTooLarge)

        let dSnap = PlateSRPolicy.decide(crop: img, purpose: .snapshot, metadata: metaOCR)
        #expect(dSnap.reason != .cropTooLarge)
    }

    @Test("Low detection confidence → skip")
    func lowDetection() {
        let img = Self.makeImage(width: 100, height: 30) { _, _ in (128, 128, 128) }
        let meta = Self.makeMeta(w: 100, h: 30, conf: 0.2)
        let d = PlateSRPolicy.decide(crop: img, purpose: .visionRetry, metadata: meta)
        #expect(d.reason == .lowDetectionConfidence)
    }

    @Test("Black-clipped exposure → poorExposure")
    func blackClipped() {
        // 50% pixels at luma 0 (clipped black).
        let img = Self.makeImage(width: 100, height: 30) { x, _ in
            x < 50 ? (0, 0, 0) : (200, 200, 200)
        }
        let d = PlateSRPolicy.decide(crop: img, purpose: .snapshot,
                                     metadata: Self.makeMeta(w: 100, h: 30))
        #expect(d.reason == .poorExposure)
    }

    @Test("White-clipped exposure → poorExposure")
    func whiteClipped() {
        let img = Self.makeImage(width: 100, height: 30) { x, _ in
            x < 50 ? (60, 60, 60) : (255, 255, 255)
        }
        let d = PlateSRPolicy.decide(crop: img, purpose: .snapshot,
                                     metadata: Self.makeMeta(w: 100, h: 30))
        #expect(d.reason == .poorExposure)
    }

    @Test("Low dynamic range → poorExposure")
    func lowDynamicRange() {
        // All grays close together → dynamic range < 0.15.
        let img = Self.makeImage(width: 100, height: 30) { _, _ in (128, 128, 128) }
        let d = PlateSRPolicy.decide(crop: img, purpose: .snapshot,
                                     metadata: Self.makeMeta(w: 100, h: 30))
        #expect(d.reason == .poorExposure)
    }

    @Test("OCR purpose: high-conf stable baseline → skip")
    func highConfidenceBaseline() {
        let img = Self.makeImage(width: 100, height: 30) { x, _ in
            x < 50 ? (40, 40, 40) : (220, 220, 220)
        }
        let d = PlateSRPolicy.decide(
            crop: img, purpose: .visionRetry,
            metadata: Self.makeMeta(w: 100, h: 30),
            baselineConfidence: 0.95,
            baselineTextValid: true,
            baselineTrackConfirmed: true
        )
        #expect(d.reason == .highConfidenceBaseline)
    }

    @Test("Snapshot purpose ignores high-conf baseline shortcut")
    func snapshotIgnoresHighConfShortcut() {
        let img = Self.makeImage(width: 100, height: 30) { x, _ in
            x < 50 ? (40, 40, 40) : (220, 220, 220)
        }
        let d = PlateSRPolicy.decide(
            crop: img, purpose: .snapshot,
            metadata: Self.makeMeta(w: 100, h: 30),
            baselineConfidence: 0.95,
            baselineTextValid: true,
            baselineTrackConfirmed: true
        )
        #expect(d.reason != .highConfidenceBaseline)
    }

    // MARK: - Deterministic shadow sampling

    @Test("Shadow sampling stable for same key across calls")
    func deterministicSamplingStable() {
        let r1 = PlateSRPolicy.shouldShadowSample(cameraID: "vjezd", trackID: "abc",
                                                   cropFingerprint: 0xDEADBEEF, rate: 0.25)
        let r2 = PlateSRPolicy.shouldShadowSample(cameraID: "vjezd", trackID: "abc",
                                                   cropFingerprint: 0xDEADBEEF, rate: 0.25)
        #expect(r1 == r2)
    }

    @Test("Shadow sampling distribution over 1000 keys ≈ rate")
    func deterministicSamplingDistribution() {
        var sampled = 0
        for i in 0..<1000 {
            if PlateSRPolicy.shouldShadowSample(cameraID: "cam",
                                                trackID: "track\(i)",
                                                cropFingerprint: UInt64(i),
                                                rate: 0.25) {
                sampled += 1
            }
        }
        // Statistical band 220...280 (rate 0.25 → expected 250 ±30)
        #expect((220...280).contains(sampled))
    }

    @Test("Shadow rate 0 → never sample, rate 1 → always sample")
    func samplingExtremes() {
        var rate0 = 0, rate1 = 0
        for i in 0..<100 {
            if PlateSRPolicy.shouldShadowSample(cameraID: "c", trackID: nil,
                                                cropFingerprint: UInt64(i),
                                                rate: 0.0) { rate0 += 1 }
            if PlateSRPolicy.shouldShadowSample(cameraID: "c", trackID: nil,
                                                cropFingerprint: UInt64(i),
                                                rate: 1.0) { rate1 += 1 }
        }
        #expect(rate0 == 0)
        #expect(rate1 == 100)
    }

    // MARK: - Sanity passthrough

    @Test("Healthy crop, valid metadata → apply")
    func healthyApply() {
        // High-contrast crop avoiding clip + dynamic range > 0.15
        let img = Self.makeImage(width: 100, height: 30) { x, _ in
            x < 50 ? (40, 40, 40) : (220, 220, 220)
        }
        let d = PlateSRPolicy.decide(crop: img, purpose: .snapshot,
                                     metadata: Self.makeMeta(w: 100, h: 30))
        #expect(d.shouldApply)
    }
}
