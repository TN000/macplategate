import Testing
import CoreGraphics
@testable import SPZApp

@Suite("PlateOCRCluster")
struct PlateOCRClusterTests {
    @Test func clusterByYAxisGroupsCloseY() {
        let boxes = [
            CGRect(x: 10, y: 100, width: 80, height: 20),
            CGRect(x: 120, y: 106, width: 90, height: 22),
            CGRect(x: 10, y: 220, width: 80, height: 20)
        ]

        let groups = PlateOCR.clusterByYAxis(boxes: boxes)

        #expect(groups.count == 2)
        #expect(Set(groups[0]) == Set([0, 1]))
        #expect(Set(groups[1]) == Set([2]))
    }

    @Test func upscaleFactorIsSmoothAndCapped() {
        // OCR retry + snapshot: 2.5× cap, target 120 px height.
        let tiny = CGRect(x: 0, y: 0, width: 120, height: 40)
        let small = CGRect(x: 0, y: 0, width: 200, height: 60)
        let medium = CGRect(x: 0, y: 0, width: 300, height: 90)

        #expect(PlateOCR.ocrUpscaleFactor(for: tiny) == 2.5)
        #expect(PlateOCR.ocrUpscaleFactor(for: small) == 2.0)
        #expect(abs(PlateOCR.ocrUpscaleFactor(for: medium) - 1.3333333333) < 0.001)

        #expect(PlateOCR.snapshotUpscaleFactor(for: tiny) == 2.5)
        #expect(PlateOCR.snapshotUpscaleFactor(for: small) == 2.0)
        #expect(abs(PlateOCR.snapshotUpscaleFactor(for: medium) - 1.3333333333) < 0.001)

        let renderSmall = PlateOCR.ocrRetryRenderSize(for: small)
        #expect(renderSmall.width == 400)
        #expect(renderSmall.height == 120)

        let snapshotSmall = PlateOCR.snapshotRenderSize(for: small)
        #expect(snapshotSmall.width == 400)
        #expect(snapshotSmall.height == 120)
    }
}
