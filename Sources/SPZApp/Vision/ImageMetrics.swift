import Foundation
import CoreImage
import CoreGraphics
import Accelerate

/// Image quality metrics — shared utility pro PlateOCR (luma stats),
/// Step 7 best-crop scoring (sharpness + glare), a budoucí callers.
///
/// Žádný state — pure static functions. Volá se v hot path commit() takže
/// implementace prefereje vImage / GPU-accelerated cesty před manuálními
/// pixel loopy.
enum ImageMetrics {

    // MARK: - Luma stats (prev `PlateOCR.measureLuma`)

    /// Mean / min / max luma napříč obrazem v 0–255 škále. CIImage cesta —
    /// renders do bitmap přes shared CIContext.
    static func measureLuma(_ image: CIImage) -> (mean: Double, min: Double, max: Double) {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return (0, 0, 0) }

        // CIAreaAverage → mean luma per channel.
        let avgFilter = CIFilter(name: "CIAreaAverage")
        avgFilter?.setValue(image, forKey: kCIInputImageKey)
        avgFilter?.setValue(CIVector(cgRect: extent), forKey: "inputExtent")
        guard let avgOut = avgFilter?.outputImage else { return (0, 0, 0) }
        var avgPixel = [UInt8](repeating: 0, count: 4)
        ImageMetrics.sharedContext.render(avgOut, toBitmap: &avgPixel, rowBytes: 4,
                                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        // Luma Rec. 601 approximation (ne perfect ale dost na statistiku).
        let mean = 0.299 * Double(avgPixel[0]) + 0.587 * Double(avgPixel[1]) + 0.114 * Double(avgPixel[2])

        // Min/max via CIAreaMinimum + CIAreaMaximum (separate filters, GPU).
        let minFilter = CIFilter(name: "CIAreaMinimum")
        minFilter?.setValue(image, forKey: kCIInputImageKey)
        minFilter?.setValue(CIVector(cgRect: extent), forKey: "inputExtent")
        let maxFilter = CIFilter(name: "CIAreaMaximum")
        maxFilter?.setValue(image, forKey: kCIInputImageKey)
        maxFilter?.setValue(CIVector(cgRect: extent), forKey: "inputExtent")

        var minPixel = [UInt8](repeating: 255, count: 4)
        var maxPixel = [UInt8](repeating: 0, count: 4)
        if let minOut = minFilter?.outputImage {
            ImageMetrics.sharedContext.render(minOut, toBitmap: &minPixel, rowBytes: 4,
                                               bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                               format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        if let maxOut = maxFilter?.outputImage {
            ImageMetrics.sharedContext.render(maxOut, toBitmap: &maxPixel, rowBytes: 4,
                                               bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                               format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        let minLuma = 0.299 * Double(minPixel[0]) + 0.587 * Double(minPixel[1]) + 0.114 * Double(minPixel[2])
        let maxLuma = 0.299 * Double(maxPixel[0]) + 0.587 * Double(maxPixel[1]) + 0.114 * Double(maxPixel[2])
        return (mean, minLuma, maxLuma)
    }

    // MARK: - Sharpness (Step 7 best-crop scoring)

    /// Laplacian variance metrika ostrosti. Vyšší = ostřejší.
    /// Computed in 0–1 normalized scale clamped.
    static func sharpness(_ cg: CGImage) -> Float {
        guard cg.width >= 8, cg.height >= 8 else { return 0 }
        let w = cg.width, h = cg.height
        let bpr = w
        let pixelCount = w * h
        var grayBytes = [UInt8](repeating: 0, count: pixelCount)
        let cs = CGColorSpaceCreateDeviceGray()

        guard grayBytes.withUnsafeMutableBytes({ raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h,
                                       bitsPerComponent: 8, bytesPerRow: bpr,
                                       space: cs, bitmapInfo: 0) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }) else { return 0 }

        // Manuální Laplacian 3×3: [[0,1,0],[1,-4,1],[0,1,0]]. Stride-sample
        // 1/4 pixelů (statistical OK pro variance estimate, ~3× rychlejší).
        var sumSq: Double = 0
        var count: Double = 0
        var y = 1
        while y < h - 1 {
            var x = 1
            while x < w - 1 {
                let idx = y * bpr + x
                let center = Int(grayBytes[idx])
                let lap = Int(grayBytes[idx - bpr])
                        + Int(grayBytes[idx + bpr])
                        + Int(grayBytes[idx - 1])
                        + Int(grayBytes[idx + 1])
                        - 4 * center
                sumSq += Double(lap * lap)
                count += 1
                x += 2  // stride 2 horizontally
            }
            y += 2  // stride 2 vertically
        }
        guard count > 0 else { return 0 }
        let variance = sumSq / count
        // Typical sharp plate ~3000-15000, blur ~200-500. Map na 0–1.
        let normalized = Float(min(1.0, variance / 10_000.0))
        return max(0, normalized)
    }

    // MARK: - Glare score

    /// Fraction of pixelů s luma ≥ 240 (clipped highlights). 0–1 scale.
    /// Vysoké hodnoty znamenají nasvícený / overexposed plate — OCR struggles.
    static func glareScore(_ cg: CGImage) -> Float {
        guard cg.width >= 8, cg.height >= 8 else { return 0 }
        let w = cg.width, h = cg.height
        let bpr = w
        let pixelCount = w * h
        var grayBytes = [UInt8](repeating: 0, count: pixelCount)
        let cs = CGColorSpaceCreateDeviceGray()
        guard grayBytes.withUnsafeMutableBytes({ raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h,
                                       bitsPerComponent: 8, bytesPerRow: bpr,
                                       space: cs, bitmapInfo: 0) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }) else { return 0 }
        var clipped: Int = 0
        var idx = 0
        var sampled: Int = 0
        while idx < grayBytes.count {
            if grayBytes[idx] >= 240 { clipped += 1 }
            sampled += 1
            idx += 4
        }
        guard sampled > 0 else { return 0 }
        return Float(clipped) / Float(sampled)
    }

    // MARK: - Composite score (Step 7)

    /// Kombinovaná score [0, 1]: sharpness × (1 - glare) × bboxAreaNorm.
    /// Higher = lepší crop pro commit. Caller (PlatePipeline) loguje per-track
    /// pro 1-week validation předtím než score-driven crop choice activate.
    static func compositeScore(sharpness: Float, glare: Float, areaNorm: Float) -> Float {
        let s = max(0, min(1, sharpness))
        let g = max(0, min(1, glare))
        let a = max(0, min(1, areaNorm))
        return s * (1 - g) * a
    }

    // MARK: - Internals

    /// Shared CIContext — Metal-backed, reused napříč voláními.
    static let sharedContext: CIContext = {
        if let dev = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: dev, options: [
                .priorityRequestLow: false,
                .cacheIntermediates: false,
            ])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()
}

// MARK: - Imports for vImage / Metal

import Metal
