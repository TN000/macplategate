import Testing
import Foundation
import CoreGraphics
@testable import SPZApp

@Suite("ImageMetrics")
struct ImageMetricsTests {

    // MARK: - Helpers

    /// Synthetic grayscale CGImage s daným fill callback (luma 0–255).
    private static func makeGrayCG(width: Int, height: Int,
                                    fill: (Int, Int) -> UInt8) -> CGImage? {
        let bpr = width
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                bytes[y * bpr + x] = fill(x, y)
            }
        }
        let cs = CGColorSpaceCreateDeviceGray()
        return bytes.withUnsafeMutableBytes { raw -> CGImage? in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: width, height: height,
                                       bitsPerComponent: 8, bytesPerRow: bpr,
                                       space: cs, bitmapInfo: 0)
            else { return nil }
            return ctx.makeImage()
        }
    }

    // MARK: - Sharpness

    @Test func sharpUniformImageReturnsLowScore() throws {
        // Uniform gray = no edges = low Laplacian.
        let cg = try #require(Self.makeGrayCG(width: 200, height: 100) { _, _ in 128 })
        let s = ImageMetrics.sharpness(cg)
        #expect(s < 0.05, "uniform gray sharpness should be near 0, got \(s)")
    }

    @Test func sharpCheckerboardReturnsHighScore() throws {
        // Hard 8×8 checkerboard — maximum edge density → high Laplacian variance.
        let cg = try #require(Self.makeGrayCG(width: 200, height: 100) { x, y in
            ((x / 8) + (y / 8)) % 2 == 0 ? 255 : 0
        })
        let s = ImageMetrics.sharpness(cg)
        #expect(s > 0.5, "checkerboard sharpness should be high, got \(s)")
    }

    @Test func sharpBlurredEdgeLowerThanSharpEdge() throws {
        // Sharp edge: half image bright / half dark.
        let sharpCG = try #require(Self.makeGrayCG(width: 200, height: 100) { x, _ in
            x < 100 ? 0 : 255
        })
        // Blurred edge: gradient transition over 40 px wide.
        let blurredCG = try #require(Self.makeGrayCG(width: 200, height: 100) { x, _ in
            if x < 80 { return 0 }
            if x > 120 { return 255 }
            // linear ramp
            return UInt8((x - 80) * 255 / 40)
        })
        let sharp = ImageMetrics.sharpness(sharpCG)
        let blurred = ImageMetrics.sharpness(blurredCG)
        #expect(sharp > blurred, "sharp edge sharpness=\(sharp) blurred=\(blurred)")
    }

    // MARK: - Glare

    @Test func glareUniformDarkReturnsZero() throws {
        let cg = try #require(Self.makeGrayCG(width: 200, height: 100) { _, _ in 50 })
        let g = ImageMetrics.glareScore(cg)
        #expect(g == 0)
    }

    @Test func glareUniformWhiteReturnsOne() throws {
        let cg = try #require(Self.makeGrayCG(width: 200, height: 100) { _, _ in 250 })
        let g = ImageMetrics.glareScore(cg)
        #expect(g > 0.95)
    }

    @Test func glareSpotReturnsProportionalScore() throws {
        // 50% bright spot.
        let cg = try #require(Self.makeGrayCG(width: 200, height: 100) { x, _ in
            x < 100 ? 50 : 250
        })
        let g = ImageMetrics.glareScore(cg)
        #expect(g > 0.4 && g < 0.6, "expected ~0.5 glare, got \(g)")
    }

    // MARK: - Composite score

    @Test func compositeScoreClamps() {
        #expect(ImageMetrics.compositeScore(sharpness: -1, glare: 0, areaNorm: 1) == 0)
        #expect(ImageMetrics.compositeScore(sharpness: 1, glare: 1.5, areaNorm: 1) == 0)
        #expect(ImageMetrics.compositeScore(sharpness: 1, glare: 0, areaNorm: 1) == 1.0)
    }

    @Test func compositeScoreMonotonicInSharpness() {
        let lo = ImageMetrics.compositeScore(sharpness: 0.2, glare: 0, areaNorm: 1)
        let hi = ImageMetrics.compositeScore(sharpness: 0.8, glare: 0, areaNorm: 1)
        #expect(hi > lo)
    }

    @Test func compositeScoreMonotonicallyDecreasingInGlare() {
        let lo = ImageMetrics.compositeScore(sharpness: 1, glare: 0.0, areaNorm: 1)
        let hi = ImageMetrics.compositeScore(sharpness: 1, glare: 0.8, areaNorm: 1)
        #expect(lo > hi)
    }
}
