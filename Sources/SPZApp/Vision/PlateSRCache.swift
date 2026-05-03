import CoreGraphics
import Foundation

/// LRU cache pro SR výstupy — bound by total cost (RGBA bytes), invalidated
/// automaticky přes modelVersionHash když se model upgraduje.
final class PlateSRCache: @unchecked Sendable {
    static let shared = PlateSRCache()

    private let cache = NSCache<NSString, CachedEntry>()

    init(totalCostLimit: Int = 64 * 1024 * 1024) {
        cache.totalCostLimit = totalCostLimit
    }

    func get(key: String) -> CGImage? {
        cache.object(forKey: key as NSString)?.image
    }

    func put(image: CGImage, key: String, cost: Int) {
        cache.setObject(CachedEntry(image: image), forKey: key as NSString, cost: cost)
    }

    func clear() {
        cache.removeAllObjects()
    }

    /// Versioned key: imageHash (luma 32×16 fingerprint) + cameraID + cropRect +
    /// modelVersion + purpose. Pipeline/model bump auto-invalidates.
    func makeKey(image: CGImage,
                 cameraID: String,
                 cropRect: CGRect,
                 purpose: PlateSRPurpose,
                 modelVersion: UInt64,
                 pipelineVersion: UInt32 = 1) -> String {
        let imgHash = lumaFingerprint(image)
        let camHash = fnv1a(cameraID)
        let rectHash = rectFingerprint(cropRect)
        return "\(imgHash):\(camHash):\(rectHash):\(modelVersion):\(pipelineVersion):\(purpose.rawValue)"
    }

    // MARK: - Fingerprints

    private func lumaFingerprint(_ cg: CGImage) -> UInt64 {
        let w = 32, h = 16
        var buf = [UInt8](repeating: 0, count: w * h)
        _ = buf.withUnsafeMutableBytes { raw -> Bool in
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
        var h64: UInt64 = 0xcbf29ce484222325
        for v in buf {
            h64 ^= UInt64(v)
            h64 = h64 &* 0x100000001b3
        }
        return h64
    }

    private func rectFingerprint(_ rect: CGRect) -> UInt64 {
        let x = Int64(rect.origin.x.rounded())
        let y = Int64(rect.origin.y.rounded())
        let w = Int64(rect.width.rounded())
        let h = Int64(rect.height.rounded())
        var h64: UInt64 = 0xcbf29ce484222325
        for value in [x, y, w, h] {
            var bits = UInt64(bitPattern: value)
            for _ in 0..<8 {
                h64 ^= UInt64(bits & 0xff)
                h64 = h64 &* 0x100000001b3
                bits >>= 8
            }
        }
        return h64
    }

    private func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100000001b3
        }
        return h
    }
}

private final class CachedEntry: NSObject {
    let image: CGImage
    init(image: CGImage) { self.image = image }
}
