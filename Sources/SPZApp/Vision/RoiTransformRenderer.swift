import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

/// Shared ROI transform stack for UI previews.
///
/// Keep this in sync with `PlateOCR.recognize`: ROI crop -> rotation ->
/// legacy perspective sliders -> 8-DOF calibration -> detection-area crop.
/// Individual calibration screens can opt out of the last steps when they edit
/// that exact layer.
enum RoiTransformRenderer {
    struct Options {
        var applyPerspectiveCalibration: Bool = true
        var applyDetectionQuad: Bool = true
        var maxOutputWidth: CGFloat? = nil
    }

    static func renderCIImage(from pixelBuffer: CVPixelBuffer,
                              roi: RoiBox,
                              options: Options = Options()) -> CIImage? {
        let imgW = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let imgH = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let rect = roi.cgRect.intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))
        guard !rect.isNull, rect.width >= 8, rect.height >= 8 else { return nil }

        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let ciRect = CGRect(x: rect.minX, y: imgH - rect.maxY,
                            width: rect.width, height: rect.height)
        var cropped = ci.cropped(to: ciRect)
            .transformed(by: CGAffineTransform(translationX: -ciRect.minX, y: -ciRect.minY))

        if abs(roi.rotationRadians) > 0.001 {
            let cx = rect.width / 2
            let cy = rect.height / 2
            let t = CGAffineTransform(translationX: -cx, y: -cy)
                .concatenating(CGAffineTransform(rotationAngle: roi.rotationRadians))
            cropped = cropped.transformed(by: t)
            let ext = cropped.extent
            cropped = cropped.transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
        }

        if let pc = roi.perspective, !pc.isIdentity {
            if let corrected = PlateOCR.applyPerspective(cropped,
                                                         width: cropped.extent.width,
                                                         height: cropped.extent.height,
                                                         perspective: pc) {
                cropped = corrected
            }
        }

        if options.applyPerspectiveCalibration,
           let calibrated = applyPerspectiveCalibration(cropped, roi: roi) {
            cropped = calibrated
        }

        if options.applyDetectionQuad,
           let quadCropped = applyDetectionQuad(cropped, roi: roi) {
            cropped = quadCropped
        }

        if let maxW = options.maxOutputWidth, cropped.extent.width > maxW {
            let scale = maxW / cropped.extent.width
            cropped = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        return cropped
    }

    static func applyPerspectiveCalibration(_ image: CIImage, roi: RoiBox) -> CIImage? {
        guard let calib = roi.perspectiveCalibration,
              calib.sourceQuad.count == 4,
              calib.destinationQuad.count == 4 else {
            return nil
        }
        let workW = image.extent.width
        let workH = image.extent.height
        let toCi = { (p: CGPoint) -> CGPoint in
            CGPoint(x: p.x * workW, y: (1 - p.y) * workH)
        }
        let src = calib.sourceQuad.map(toCi)
        let dst = calib.destinationQuad.map(toCi)
        guard let warped = PerspectiveTransform.apply(image, source: src, destination: dst) else {
            return nil
        }
        // Aplikuj scale (kolem středu) + translaci jako affinní vrstvu nad warpem.
        let cx = workW / 2, cy = workH / 2
        let sx = CGFloat(max(0.05, calib.scaleX))
        let sy = CGFloat(max(0.05, calib.scaleY))
        let tx = CGFloat(calib.offsetX) * workW
        let ty = -CGFloat(calib.offsetY) * workH  // TL-origin Y → BL-origin Y
        let affine = CGAffineTransform(translationX: -cx, y: -cy)
            .concatenating(CGAffineTransform(scaleX: sx, y: sy))
            .concatenating(CGAffineTransform(translationX: cx + tx, y: cy + ty))
        let transformed = warped.transformed(by: affine)
        let outRect = CGRect(x: 0, y: 0, width: workW, height: workH)
        let cropped = transformed.cropped(to: outRect)
        let ext = cropped.extent
        if abs(ext.minX) > 0.001 || abs(ext.minY) > 0.001 {
            return cropped.transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
        }
        return cropped
    }

    static func applyDetectionQuad(_ image: CIImage, roi: RoiBox) -> CIImage? {
        guard let dq = roi.detectionQuad, dq.count == 4 else { return nil }
        let xs = dq.map { $0.x }
        let ys = dq.map { $0.y }
        let nMinX = max(0, min(1, xs.min() ?? 0))
        let nMaxX = max(0, min(1, xs.max() ?? 1))
        let nMinY = max(0, min(1, ys.min() ?? 0))
        let nMaxY = max(0, min(1, ys.max() ?? 1))
        let isFull = nMinX < 0.01 && nMaxX > 0.99 && nMinY < 0.01 && nMaxY > 0.99
        guard !isFull, nMaxX > nMinX + 0.02, nMaxY > nMinY + 0.02 else { return nil }

        let workW = image.extent.width
        let workH = image.extent.height
        let pxMinX = nMinX * workW
        let pxMaxX = nMaxX * workW
        let pxMinYBL = (1 - nMaxY) * workH
        let pxMaxYBL = (1 - nMinY) * workH
        let cropRect = CGRect(x: pxMinX, y: pxMinYBL,
                              width: pxMaxX - pxMinX,
                              height: pxMaxYBL - pxMinYBL)
        return image.cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
    }
}
