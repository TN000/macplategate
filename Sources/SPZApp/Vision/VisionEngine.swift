import CoreGraphics
import Foundation
import Vision

/// Crop-only Apple Vision adapter used by the secondary-engine plugin surface.
///
/// The production pipeline still calls `PlateOCR.recognize(...)` for detection +
/// recognition. This adapter exists so replay/tests can compare another
/// recognizer-like engine against the same `PlateRecognitionEngine` contract.
struct VisionEngine: PlateRecognitionEngine {
    let name = "apple-vision-crop"
    var recognitionLevel: VNRequestTextRecognitionLevel = .accurate

    func recognize(crop: CGImage) async -> EngineReading? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = recognitionLevel
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.02
        if #available(macOS 13.0, *) {
            request.revision = VNRecognizeTextRequestRevision3
        }

        let handler = VNImageRequestHandler(cgImage: crop, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        let candidates = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first }
            .filter { !$0.string.isEmpty }
        guard let best = candidates.max(by: { $0.confidence < $1.confidence }) else {
            return nil
        }
        return EngineReading(text: best.string, confidence: best.confidence)
    }
}
