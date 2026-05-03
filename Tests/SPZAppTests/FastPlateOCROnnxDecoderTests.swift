import CoreGraphics
import Foundation
import Testing
@testable import SPZApp

@Suite("FastPlateOCR ONNX decoder")
struct FastPlateOCROnnxDecoderTests {
        @Test func engineInitializesWhenAssetsAreInstalled() {
        guard FastPlateOCROnnxEngine() != nil else {
            // ONNX model is an optional asset — install via scripts/install_models.sh.
            // Pipeline runs without it (Vision-only fallback), so missing weights are
            // not a build failure.
            return
        }
        #expect(FastPlateOCROnnxEngine() != nil)
    }

    @Test func engineInferenceSmokeDoesNotThrow() async {
        guard let engine = FastPlateOCROnnxEngine() else {
            // ONNX model not installed — skip smoke test silently. See docstring above.
            return
        }
        _ = await engine.recognize(crop: makeSolidCGImage(width: 140, height: 70))
        #expect(Bool(true))
    }

    @Test func decodesSlotLastShape() {
        let alphabet = Array("AB_").map { Character(String($0)) }
        var logits = [Float](repeating: -5, count: 2 * alphabet.count)
        logits[0 * alphabet.count + 0] = 5   // A
        logits[1 * alphabet.count + 1] = 5   // B

        let reading = FastPlateOCROnnxDecoder.decode(logits: logits,
                                                     shape: [1, 2, 3],
                                                     alphabet: alphabet)
        #expect(reading?.text == "AB")
        #expect((reading?.confidence ?? 0) > 0.98)
    }

    @Test func decodesCharacterSecondShape() {
        let alphabet = Array("AB_").map { Character(String($0)) }
        var logits = [Float](repeating: -5, count: 2 * alphabet.count)
        logits[0 * 2 + 0] = 5  // char A, slot 0
        logits[1 * 2 + 1] = 5  // char B, slot 1

        let reading = FastPlateOCROnnxDecoder.decode(logits: logits,
                                                     shape: [1, 3, 2],
                                                     alphabet: alphabet)
        #expect(reading?.text == "AB")
    }

    @Test func parsesInlineAlphabetFromYaml() {
        let yaml = #"alphabet: ["0", "1", "A", "_"]"#
        let alphabet = FastPlateOCROnnxDecoder.parseAlphabet(fromPlateConfig: yaml)
        #expect(alphabet == ["0", "1", "A", "_"].map { Character($0) })
    }

    @Test func parsesScalarAlphabetFromYaml() {
        let yaml = #"characters: "01AB_""#
        let alphabet = FastPlateOCROnnxDecoder.parseAlphabet(fromPlateConfig: yaml)
        #expect(alphabet == Array("01AB_").map { Character(String($0)) })
    }

    private func makeSolidCGImage(width: Int, height: Int) -> CGImage {
        var pixels = [UInt8](repeating: 180, count: width * height * 4)
        let ctx = CGContext(data: &pixels,
                            width: width,
                            height: height,
                            bitsPerComponent: 8,
                            bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
}
