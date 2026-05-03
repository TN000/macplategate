import CoreGraphics
import Foundation

/// Future detector-only plugin contract.
///
/// Recognition engines read text from a crop. Detector engines locate plate-like
/// regions in a workspace. This is intentionally not wired into the production
/// pipeline yet; it is the stable slot for a future CoreML plate detector once
/// audit data proves Vision has no raw text candidate at all.
protocol PlateDetectorEngine {
    var name: String { get }
    func detect(workspace: CGImage) async -> [DetectedRegion]
}

struct DetectedRegion: Equatable {
    /// Workspace pixel coordinates, top-left origin.
    let bbox: CGRect
    let confidence: Float

    init(bbox: CGRect, confidence: Float) {
        self.bbox = bbox
        self.confidence = min(1.0, max(0.0, confidence))
    }
}
