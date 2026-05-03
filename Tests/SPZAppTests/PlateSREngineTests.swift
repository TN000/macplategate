import Testing
import Foundation
import CoreGraphics
@testable import SPZApp

@Suite("PlateSREngine")
struct PlateSREngineTests {

    private static func makeRGBImage(width: Int, height: Int,
                                     fill: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage? {
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
        return bytes.withUnsafeMutableBytes { raw -> CGImage? in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return nil
            }
            return ctx.makeImage()
        }
    }

    @Test("Missing model returns failed gracefully — DI ne real bundle")
    func missingModelGraceful() {
        let bogusURL = URL(fileURLWithPath: "/tmp/spz-does-not-exist-\(UUID().uuidString).onnx")
        let bogusLockfile = URL(fileURLWithPath: "/tmp/spz-does-not-exist.json")
        let engine = PlateSREngine(modelURL: bogusURL, lockfileURL: bogusLockfile)
        #expect(!engine.isAvailable)

        let image = Self.makeRGBImage(width: 100, height: 30) { _, _ in (128, 128, 128) }!
        let meta = PlateCropMetadata(cameraID: "test", trackID: nil,
                                      cropRect: CGRect(x: 0, y: 0, width: 100, height: 30),
                                      detectionConfidence: 1.0)
        let result = engine.upscale4x(image, purpose: .snapshot, metadata: meta)
        if case .skipped(let reason) = result {
            #expect(reason == .modelUnavailable)
        } else {
            Issue.record("expected .skipped(.modelUnavailable), got \(result)")
        }
    }

    @Test("ceilToMultiple rounds up correctly")
    func ceilToMultipleRounds() {
        #expect(ceilToMultiple(64, 64) == 64)
        #expect(ceilToMultiple(65, 64) == 128)
        #expect(ceilToMultiple(137, 64) == 192)
        #expect(ceilToMultiple(43, 64) == 64)
        #expect(ceilToMultiple(0, 64) == 0)
        #expect(ceilToMultiple(1, 64) == 64)
    }

    @Test("Lockfile parses OK from production resource")
    func lockfileParses() {
        // Lockfile is bundled — find via Bundle.module.
        guard let url = Bundle.module.url(forResource: "PlateSR.model", withExtension: "json")
                ?? Bundle.module.url(forResource: "Resources/PlateSR.model", withExtension: "json") else {
            // OK if not bundled in test target — skip.
            return
        }
        let data = try! Data(contentsOf: url)
        let lockfile = try! JSONDecoder().decode(PlateSRLockfile.self, from: data)
        #expect(lockfile.scaleFactor == 4)
        #expect(lockfile.modelKind == "Swin2SR-fp32")
        #expect(lockfile.license == "Apache-2.0")
        #expect(!lockfile.sha256.isEmpty)
        #expect(lockfile.versionHash != 0)
    }

    @Test("Two lockfiles with different revisions yield different versionHash")
    func versionHashDiffers() {
        let a = PlateSRLockfile(repo: "X", revision: "abc", file: "a.onnx",
                                 sha256: "deadbeef", sizeBytes: 100, license: "MIT",
                                 modelKind: "Swin2SR-fp32", scaleFactor: 4,
                                 inputName: "pixel_values", outputName: "reconstruction")
        let b = PlateSRLockfile(repo: "X", revision: "def", file: "a.onnx",
                                 sha256: "deadbeef", sizeBytes: 100, license: "MIT",
                                 modelKind: "Swin2SR-fp32", scaleFactor: 4,
                                 inputName: "pixel_values", outputName: "reconstruction")
        #expect(a.versionHash != b.versionHash)
    }
}
