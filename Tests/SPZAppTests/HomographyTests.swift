import Testing
import Foundation
import CoreGraphics
import simd
@testable import SPZApp

@Suite("PlateTransformHomography")
struct HomographyTests {

    /// Identity case: ROI = full frame, no rotation, no perspective, full quad,
    /// output size = frame size. dst(x,y) → src(x,y).
    @Test func identity_mapsPixelsOneToOne() {
        let m = PlateTransformHomography.compose(
            roi: CGRect(x: 0, y: 0, width: 100, height: 100),
            rotationRadians: 0,
            perspectiveIsIdentity: true,
            detectionQuadNormalized: [
                CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
                CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)
            ],
            workspaceSize: CGSize(width: 100, height: 100),
            outputSize: CGSize(width: 100, height: 100)
        )
        #expect(m != nil)
        if let m = m {
            let p = PlateTransformHomography.apply(m, to: CGPoint(x: 50, y: 50))
            #expect(abs(p.x - 50) < 0.01)
            #expect(abs(p.y - 50) < 0.01)
        }
    }

    /// ROI offset — roi at (100, 200), dest (0,0) → src (100, 200)
    @Test func roiOffset_appliesTranslation() {
        let m = PlateTransformHomography.compose(
            roi: CGRect(x: 100, y: 200, width: 50, height: 50),
            rotationRadians: 0,
            perspectiveIsIdentity: true,
            detectionQuadNormalized: nil,
            workspaceSize: CGSize(width: 50, height: 50),
            outputSize: CGSize(width: 50, height: 50)
        )
        #expect(m != nil)
        if let m = m {
            let p = PlateTransformHomography.apply(m, to: CGPoint(x: 0, y: 0))
            #expect(abs(p.x - 100) < 0.01)
            #expect(abs(p.y - 200) < 0.01)
        }
    }

    /// Downscale — output 50×50 from source 100×100, dest (25, 25) → src (50, 50)
    @Test func scaleCanonicalDownscale() {
        let m = PlateTransformHomography.compose(
            roi: CGRect(x: 0, y: 0, width: 100, height: 100),
            rotationRadians: 0,
            perspectiveIsIdentity: true,
            detectionQuadNormalized: nil,
            workspaceSize: CGSize(width: 100, height: 100),
            outputSize: CGSize(width: 50, height: 50)
        )
        #expect(m != nil)
        if let m = m {
            let center = PlateTransformHomography.apply(m, to: CGPoint(x: 25, y: 25))
            #expect(abs(center.x - 50) < 0.01)
            #expect(abs(center.y - 50) < 0.01)
            let corner = PlateTransformHomography.apply(m, to: CGPoint(x: 0, y: 0))
            #expect(abs(corner.x - 0) < 0.01)
            #expect(abs(corner.y - 0) < 0.01)
        }
    }

    /// DetectionQuad sub-crop — quad top-left quarter (0..0.5, 0..0.5),
    /// output dest (0,0) should map to src (0, 0) when ROI is full frame.
    @Test func detectionQuad_subCropMaps() {
        let m = PlateTransformHomography.compose(
            roi: CGRect(x: 0, y: 0, width: 100, height: 100),
            rotationRadians: 0,
            perspectiveIsIdentity: true,
            detectionQuadNormalized: [
                CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0),
                CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0, y: 0.5)
            ],
            workspaceSize: CGSize(width: 100, height: 100),
            outputSize: CGSize(width: 50, height: 50)  // 50×50 output = quad 50×50 scaled 1:1
        )
        #expect(m != nil)
        if let m = m {
            let tl = PlateTransformHomography.apply(m, to: CGPoint(x: 0, y: 0))
            #expect(abs(tl.x - 0) < 0.01)
            #expect(abs(tl.y - 0) < 0.01)
            let br = PlateTransformHomography.apply(m, to: CGPoint(x: 50, y: 50))
            #expect(abs(br.x - 50) < 0.01)
            #expect(abs(br.y - 50) < 0.01)
        }
    }

    /// Perspective non-identity → nil (fallback to CI path)
    @Test func nonIdentityPerspective_returnsNil() {
        let m = PlateTransformHomography.compose(
            roi: CGRect(x: 0, y: 0, width: 100, height: 100),
            rotationRadians: 0,
            perspectiveIsIdentity: false,
            detectionQuadNormalized: nil,
            workspaceSize: CGSize(width: 100, height: 100),
            outputSize: CGSize(width: 100, height: 100)
        )
        #expect(m == nil)
    }

    /// 90° rotation: ROI 100×100 → rotated becomes 100×100 (square), dest (50, 0)
    /// should map to ~src (0, 50) approximately (rotation around center).
    @Test func rotation90_rotatesCoordinates() {
        let m = PlateTransformHomography.compose(
            roi: CGRect(x: 0, y: 0, width: 100, height: 100),
            rotationRadians: .pi / 2,  // 90°
            perspectiveIsIdentity: true,
            detectionQuadNormalized: nil,
            workspaceSize: CGSize(width: 100, height: 100),
            outputSize: CGSize(width: 100, height: 100)
        )
        #expect(m != nil)
        if let m = m {
            // For square ROI, rotW == rotH == 100. Point at dest (100, 0) post-scale
            // maps to post-rot (100, 0). Centered: (50, -50). After inverse rotate -90°:
            // (x', y') = (x cos 90° + y sin 90°, -x sin 90° + y cos 90°) = (y, -x)
            // → (-50, -50). Shift to crop center: (0, 0). ROI origin (0,0): src (0, 0).
            let p = PlateTransformHomography.apply(m, to: CGPoint(x: 100, y: 0))
            #expect(abs(p.x - 0) < 1.0)
            #expect(abs(p.y - 0) < 1.0)
        }
    }
}
