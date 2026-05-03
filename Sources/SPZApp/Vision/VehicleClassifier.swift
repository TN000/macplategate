import Foundation
import Vision
import CoreGraphics

/// On-device "is this a bus?" detector.
///
/// **Pipeline:**
/// - `classify(image: CGImage)` volá `VNClassifyImageRequest` (ANE, ~8 ms).
/// - Pokud top-30 Imagenet labelů obsahuje bus/trolleybus/school bus/minibus
///   s confidence ≥ 0.3 → `type = "bus"`, jinak `type = nil`.
/// - Color je vždy `nil` (sampling na distant plates byl nespolehlivý —
///   chytal pozadí místo karoserie).
/// - Skip úplně pokud aspect ≥ 1.8 (plate-only workspace bez vehicle context).
///
/// **Opt-in:** `AppState.useVehicleClassification`. Když ON, commit() má ~8 ms navíc.
final class VehicleClassifier: @unchecked Sendable {
    static let shared = VehicleClassifier()

    struct Classification: Sendable {
        /// "bus" | nil. Ostatní typy (car/suv/truck/van/motorcycle) se už nerozlišují.
        let type: String?
        /// Vždy nil — color klasifikace je vypnutá.
        let color: String?
        let typeConfidence: Float
    }

    func classify(image: CGImage) -> Classification {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let aspect = w / max(h, 1)
        // Plate-only rectified workspace nemá whole-vehicle context — skip.
        guard aspect < 1.8 else {
            return Classification(type: nil, color: nil, typeConfidence: 0)
        }
        let type = classifyBus(image: image)
        return Classification(type: type.label, color: nil, typeConfidence: type.confidence)
    }

    // MARK: - Bus-only classification (Vision VNClassifyImageRequest)

    /// Vrátí "bus" pokud Imagenet s confidence ≥ 0.3 detekuje bus/trolleybus/school bus,
    /// jinak nil. Žádné jiné vehicle typy se nemapují — keep it simple.
    private func classifyBus(image: CGImage) -> (label: String?, confidence: Float) {
        let req = VNClassifyImageRequest()
        req.revision = VNClassifyImageRequestRevision1
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([req]) } catch {
            return (nil, 0)
        }
        guard let results = req.results else { return (nil, 0) }

        // Hledáme bus-family labels v top-30. "car" apod. ignorujeme.
        let busKeywords: Set<String> = ["bus", "trolleybus", "school bus", "minibus"]
        var bestConf: Float = 0
        for result in results.prefix(30) {
            let label = result.identifier.lowercased()
            for keyword in busKeywords {
                if label.contains(keyword) {
                    bestConf = max(bestConf, result.confidence)
                }
            }
        }
        if bestConf >= 0.3 {
            return ("bus", bestConf)
        }
        return (nil, 0)
    }

}
