import CoreGraphics
import Foundation

/// Minimal recognizer-only plugin contract.
///
/// The primary Apple Vision path still owns plate/text detection. Optional engines
/// receive a tight crop from an existing `PlateOCRReading` and only cross-check text.
protocol PlateRecognitionEngine: Sendable {
    var name: String { get }
    func recognize(crop: CGImage) async -> EngineReading?
}

struct EngineReading: Equatable, Sendable {
    let text: String
    let confidence: Float
    let perCharConf: [Float]?

    init(text: String, confidence: Float, perCharConf: [Float]? = nil) {
        self.text = text
        self.confidence = min(1.0, max(0.0, confidence))
        self.perCharConf = perCharConf
    }
}
