import Testing
import CoreGraphics
@testable import SPZApp

/// Smoke test že classify() nespadne. Color je vždy nil (klasifikace barev
/// vypnutá), type bus-only — VNClassifyImageRequest na solid color crop vrací
/// random labels, takže nelze deterministicky testovat bus detekci bez reálné
/// fotky autobusu v test bundle.
@Suite("VehicleClassifier")
struct VehicleClassifierTests {

    @Test func classify_solidColor_doesNotCrash_andColorIsNil() {
        let cg = makeSolidCGImage(r: 128, g: 64, b: 200, size: 128)
        let result = VehicleClassifier.shared.classify(image: cg)
        #expect(result.color == nil)
    }

    @Test func classify_plateShapeAspect_skipsEntirely() {
        // Aspect ≥ 1.8 → skip úplně, type i color nil.
        let cg = makeSolidCGImage(r: 200, g: 200, b: 200, w: 200, h: 50)
        let result = VehicleClassifier.shared.classify(image: cg)
        #expect(result.type == nil)
        #expect(result.color == nil)
    }
}

// MARK: - Helpers

private func makeSolidCGImage(r: UInt8, g: UInt8, b: UInt8, size: Int) -> CGImage {
    makeSolidCGImage(r: r, g: g, b: b, w: size, h: size)
}

private func makeSolidCGImage(r: UInt8, g: UInt8, b: UInt8, w: Int, h: Int) -> CGImage {
    let bytesPerRow = w * 4
    var pixels = [UInt8](repeating: 0, count: h * bytesPerRow)
    for i in stride(from: 0, to: pixels.count, by: 4) {
        pixels[i] = r
        pixels[i + 1] = g
        pixels[i + 2] = b
        pixels[i + 3] = 255
    }
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: &pixels,
        width: w,
        height: h,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return ctx.makeImage()!
}
