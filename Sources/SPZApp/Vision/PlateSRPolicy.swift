import CoreGraphics
import Foundation

/// Decision arbiter: should we run super-resolution on this crop, or skip with reason?
/// Caller still has to honor returned skip — engine itself does NOT consult policy.
enum PlateSRPolicy {

    struct SceneStats {
        let dynamicRange: Float
        let blackClip: Float
        let whiteClip: Float
        let centralBandSharpness: Float
    }

    struct Decision {
        let shouldApply: Bool
        let reason: PlateSRSkipReason?

        static let apply = Decision(shouldApply: true, reason: nil)
        static func skip(_ reason: PlateSRSkipReason) -> Decision {
            Decision(shouldApply: false, reason: reason)
        }
    }

    /// All-in-one entry point. Caller passes the crop + metadata; we sample stats
    /// from the image internally so callers don't repeat that work.
    static func decide(crop: CGImage,
                       purpose: PlateSRPurpose,
                       metadata: PlateCropMetadata,
                       baselineConfidence: Double? = nil,
                       baselineTextValid: Bool = false,
                       baselineTrackConfirmed: Bool = false,
                       hasResourceBudget: Bool = true,
                       userMasterEnabled: Bool = true,
                       userPurposeEnabled: Bool = true) -> Decision {

        if !userMasterEnabled || !userPurposeEnabled {
            return .skip(.disabledByUser)
        }
        if !hasResourceBudget {
            return .skip(.budgetExceeded)
        }

        let w = crop.width
        let h = crop.height

        if w < 30 || h < 12 {
            return .skip(.cropTooSmall)
        }

        // Purpose-specific cropTooLarge:
        switch purpose {
        case .snapshot:
            if w >= 420 || h >= 140 {
                return .skip(.cropTooLarge)
            }
        case .visionRetry, .secondaryOCR:
            if w >= 260 || h >= 90 {
                return .skip(.cropTooLarge)
            }
        }

        if metadata.detectionConfidence < 0.4 {
            return .skip(.lowDetectionConfidence)
        }

        // OCR-purpose only: don't override stable high-confidence baselines.
        if purpose != .snapshot,
           let conf = baselineConfidence,
           conf >= 0.85, baselineTextValid, baselineTrackConfirmed {
            return .skip(.highConfidenceBaseline)
        }

        guard let stats = sceneStats(from: crop) else {
            // Stats failure means we couldn't introspect the crop — be conservative.
            return .skip(.unsupportedShape)
        }

        if stats.dynamicRange < 0.15 || stats.blackClip > 0.20 || stats.whiteClip > 0.20 {
            return .skip(.poorExposure)
        }

        // alreadySharp only when crop is *both* big enough that upscale wouldn't
        // help much, AND the central band is sharp.
        if w >= 220 && h >= 70 && stats.centralBandSharpness > 1200.0 {
            return .skip(.alreadySharp)
        }

        return .apply
    }

    /// Deterministic sampling for shadow OCR. Returns true when this crop should be
    /// included in the shadow set, given a target rate in [0, 1].
    static func shouldShadowSample(cameraID: String,
                                   trackID: String?,
                                   cropFingerprint: UInt64,
                                   rate: Double) -> Bool {
        if rate <= 0 { return false }
        if rate >= 1 { return true }
        var h: UInt64 = 0xcbf29ce484222325
        for byte in cameraID.utf8 {
            h ^= UInt64(byte); h = h &* 0x100000001b3
        }
        if let track = trackID {
            for byte in track.utf8 {
                h ^= UInt64(byte); h = h &* 0x100000001b3
            }
        }
        h ^= cropFingerprint
        h = h &* 0x100000001b3
        let bucket = Int(h % 100)
        return bucket < Int((rate * 100).rounded())
    }

    /// Compute scene stats from a CGImage. Returns nil on conversion failure.
    static func sceneStats(from cg: CGImage) -> SceneStats? {
        let w = cg.width, h = cg.height
        guard w >= 8, h >= 8 else { return nil }
        // Render to gray8 buffer for stats.
        var buf = [UInt8](repeating: 0, count: w * h)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base,
                                      width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                return false
            }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }

        // Histogram stats — p05, p95, blackClip, whiteClip.
        var hist = [Int](repeating: 0, count: 256)
        for v in buf { hist[Int(v)] += 1 }
        let total = max(1, buf.count)
        var cum = 0
        var p05: UInt8 = 0, p95: UInt8 = 255
        for i in 0..<256 {
            cum += hist[i]
            if p05 == 0 && cum >= total / 20 { p05 = UInt8(i) }
            if cum >= (total * 19) / 20 { p95 = UInt8(i); break }
        }
        let dynamicRange = Float(p95 - p05) / 255.0

        let blackThreshold: Float = 0.02 * 255.0
        let whiteThreshold: Float = 0.98 * 255.0
        var blackCount = 0, whiteCount = 0
        for v in buf {
            let f = Float(v)
            if f < blackThreshold { blackCount += 1 }
            if f > whiteThreshold { whiteCount += 1 }
        }
        let blackClip = Float(blackCount) / Float(total)
        let whiteClip = Float(whiteCount) / Float(total)

        // Central-band variance-of-Laplacian (sharpness proxy).
        let yStart = h * 25 / 100
        let yEnd = h * 75 / 100
        let xStart = w * 5 / 100
        let xEnd = w * 95 / 100
        let bandW = xEnd - xStart
        let bandH = yEnd - yStart
        guard bandW >= 4, bandH >= 4 else {
            return SceneStats(dynamicRange: dynamicRange,
                              blackClip: blackClip,
                              whiteClip: whiteClip,
                              centralBandSharpness: 0)
        }
        var sum: Double = 0
        var sumSq: Double = 0
        var n: Double = 0
        for y in (yStart + 1)..<(yEnd - 1) {
            for x in (xStart + 1)..<(xEnd - 1) {
                let center = Int(buf[y * w + x])
                let lap = Int(buf[(y-1) * w + x])
                        + Int(buf[(y+1) * w + x])
                        + Int(buf[y * w + (x-1)])
                        + Int(buf[y * w + (x+1)])
                        - 4 * center
                let lf = Double(lap)
                sum += lf
                sumSq += lf * lf
                n += 1
            }
        }
        let mean = sum / max(n, 1)
        let varLap = (sumSq / max(n, 1)) - (mean * mean)

        return SceneStats(dynamicRange: dynamicRange,
                          blackClip: blackClip,
                          whiteClip: whiteClip,
                          centralBandSharpness: Float(varLap))
    }
}
