import CoreGraphics
import Foundation
import Testing
@testable import SPZApp

@Suite("PlateReadingMerger")
struct PlateReadingMergerTests {
    @Test func nilEngineIsNoop() {
        let reading = makeReading(text: "2ZB5794")
        let merged = PlateReadingMerger.merge(visionReadings: [reading], secondaryEngine: nil)

        #expect(merged.count == 1)
        #expect(merged[0].text == "2ZB5794")
        #expect(merged[0].origin == .passOneRaw)
        #expect(abs(merged[0].confidence - reading.confidence) < 0.001)
    }

    @Test func agreementClassifiesExactAndL1AndDisagree() {
        #expect(PlateReadingMerger.agreement(vision: "2ZB 5794", secondary: "2ZB5794") == .agree)
        #expect(PlateReadingMerger.agreement(vision: "2ZB-5794", secondary: "2ZB5794") == .agree)
        #expect(PlateReadingMerger.agreement(vision: "2ZB5794", secondary: "2ZB5793") == .l1Agree)
        #expect(PlateReadingMerger.agreement(vision: "2ZB5794", secondary: "ABC1234") == .disagree)
    }

    @Test func agreeingSecondaryMarksCrossValidatedWithoutTextOrConfidenceOverride() async {
        let reading = makeReading(text: "2ZB5794", confidence: 0.61)
        let engine = StubEngine(reading: EngineReading(text: "2ZB5794", confidence: 0.96))

        let merged = await PlateReadingMerger.mergeWithSecondary(
            visionReadings: [reading],
            secondaryEngine: engine,
            audit: false
        )

        #expect(merged.count == 1)
        #expect(merged[0].text == "2ZB5794")
        #expect(merged[0].origin == .crossValidated)
        #expect(merged[0].isStrictValidCz)
        #expect(abs(merged[0].confidence - 0.61) < 0.001)
    }

    @Test func l1AgreeSecondaryMarksFuzzyWithoutTextOrConfidenceOverride() async {
        let reading = makeReading(text: "4Z00172", confidence: 0.88)
        let engine = StubEngine(reading: EngineReading(text: "4ZD0172", confidence: 0.97))

        let merged = await PlateReadingMerger.mergeWithSecondary(
            visionReadings: [reading],
            secondaryEngine: engine,
            audit: false
        )

        #expect(merged.count == 1)
        #expect(merged[0].text == "4Z00172")
        #expect(merged[0].origin == .crossValidatedFuzzy)
        #expect(abs(merged[0].confidence - 0.88) < 0.001)
    }

    @Test func disagreeingSecondaryKeepsVisionReading() async {
        let reading = makeReading(text: "2ZB5794", confidence: 0.82)
        let engine = StubEngine(reading: EngineReading(text: "ABC9999", confidence: 0.99))

        let merged = await PlateReadingMerger.mergeWithSecondary(
            visionReadings: [reading],
            secondaryEngine: engine,
            audit: false
        )

        #expect(merged.count == 1)
        #expect(merged[0].text == "2ZB5794")
        #expect(merged[0].origin == .passOneRaw)
        #expect(abs(merged[0].confidence - 0.82) < 0.001)
    }

    private func makeReading(text: String, confidence: Float = 0.8) -> PlateOCRReading {
        let image = makeSolidCGImage(width: 80, height: 40)
        let box = CGRect(x: 10, y: 8, width: 50, height: 20)
        return PlateOCRReading(text: text,
                               altTexts: [],
                               confidence: confidence,
                               bbox: box,
                               workBox: box,
                               workSize: CGSize(width: 80, height: 40),
                               region: nil,
                               workspaceImage: image,
                               rawWorkspaceImage: nil)
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

    private struct StubEngine: PlateRecognitionEngine {
        let name = "stub"
        let reading: EngineReading?

        func recognize(crop: CGImage) async -> EngineReading? {
            reading
        }
    }
}
