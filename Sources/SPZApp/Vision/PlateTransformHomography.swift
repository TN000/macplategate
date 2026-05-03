import Foundation
import CoreGraphics
import simd

/// Compositor — z per-camera config (ROI, rotation, perspective, detectionQuad)
/// sestaví **inverse 3×3 homography matrix** která mapuje destination pixel
/// (canonical output) → source pixel (raw frame z VT decoderu).
///
/// Slouží jako náhrada CI chainu (`cropped → rotated → CIPerspectiveTransform
/// → quad crop`) při použití `PlateTransformKernel`. CI chain je 3-4 Metal
/// passy + lazy graph eval; single homography + GPU compute kernel = 1 pass.
///
/// **Math:** composition of forward transforms
/// 1. `src(raw frame)` → offset to ROI: subtract ROI.origin
/// 2. ROI → rotation around ROI center: rotate angle θ
/// 3. rotated → perspective-corrected: CIPerspectiveTransform M_p
/// 4. perspective → detectionQuad-cropped: subtract quad.origin, clamp to quad size
/// 5. quad-cropped → canonical output: scale to (outW, outH)
///
/// `M_forward` = M5·M4·M3·M2·M1 mapping source → destination (canonical).
/// `M_inverse` = inv(M_forward) pro dst → src lookup v Metal shaderu.
///
/// Dnes implementujeme **affine subset** (translation + rotation + scale) pro
/// simple cases bez perspective (`perspective == nil || .isIdentity`). Full
/// perspective compositor by vyžadoval 8-DOF homography solve (4 corner pairs
/// → linear system via SVD). Pro cameras co použijí perspective, fallback na
/// CI chain je nutný (viz `useMetalPath` return false).
struct PlateTransformHomography {

    /// Spočítá inverse 3×3 matrix mapping dst[x,y,1] → src[u,v,w] kde finální
    /// pixel je (u/w, v/w). Pro affine case je w vždy 1; pro perspective je
    /// nil a caller musí fallback na CI path.
    static func compose(
        roi: CGRect,
        rotationRadians: CGFloat,
        perspectiveIsIdentity: Bool,
        detectionQuadNormalized: [CGPoint]?,  // 4 rohy v [0,1] quadN
        workspaceSize: CGSize,   // rozměr post-rotate image (pre-perspective)
        outputSize: CGSize       // canonical output (např. 600×130)
    ) -> simd_float3x3? {
        // Unsupported: perspective non-identity. Caller fallback.
        guard perspectiveIsIdentity else { return nil }

        // 1. Compute post-rotate workspace dimensions. Rotation of rect (cropW × cropH)
        //    around center produces bounding box rotW × rotH.
        let cropW = roi.width
        let cropH = roi.height
        let cosT = abs(cos(rotationRadians))
        let sinT = abs(sin(rotationRadians))
        let rotW = cropW * cosT + cropH * sinT
        let rotH = cropW * sinT + cropH * cosT
        guard rotW > 0, rotH > 0 else { return nil }

        // 2. Extract detectionQuad pixel coords v post-rotate space
        let quadPx: CGRect
        if let quad = detectionQuadNormalized, quad.count == 4 {
            let xs = quad.map { $0.x }, ys = quad.map { $0.y }
            let nMinX = max(0, min(1, xs.min() ?? 0))
            let nMaxX = max(0, min(1, xs.max() ?? 1))
            let nMinY = max(0, min(1, ys.min() ?? 0))
            let nMaxY = max(0, min(1, ys.max() ?? 1))
            let isFull = nMinX < 0.01 && nMaxX > 0.99 && nMinY < 0.01 && nMaxY > 0.99
            if isFull {
                quadPx = CGRect(x: 0, y: 0, width: rotW, height: rotH)
            } else {
                quadPx = CGRect(
                    x: nMinX * rotW,
                    y: nMinY * rotH,
                    width: (nMaxX - nMinX) * rotW,
                    height: (nMaxY - nMinY) * rotH
                )
            }
        } else {
            quadPx = CGRect(x: 0, y: 0, width: rotW, height: rotH)
        }
        guard quadPx.width > 0, quadPx.height > 0 else { return nil }

        // 3. Compose inverse mapping: dst_canonical(x,y) → src_rawFrame(u,v)
        //
        //    Step A: canonical → post-quad space
        //       u_quad = x * quadPx.w / outputSize.w
        //       v_quad = y * quadPx.h / outputSize.h
        //    Step B: post-quad → post-rotate (pre-quad) space
        //       u_rot = u_quad + quadPx.x
        //       v_rot = v_quad + quadPx.y
        //    Step C: post-rotate → pre-rotate (ROI-cropped) space
        //       Shift to center of rotation (rotW/2, rotH/2), apply inverse rotation,
        //       shift back to ROI center (cropW/2, cropH/2):
        //       [u_crop, v_crop] = R^-1 * [u_rot - rotW/2, v_rot - rotH/2] + [cropW/2, cropH/2]
        //       R^-1 = [cos(-θ), -sin(-θ); sin(-θ), cos(-θ)] = [cos θ, sin θ; -sin θ, cos θ]
        //    Step D: ROI-cropped → raw frame
        //       u_src = u_crop + roi.x
        //       v_src = v_crop + roi.y
        //
        // Sloučené do single 3×3 affine:

        let sx = Float(quadPx.width / outputSize.width)
        let sy = Float(quadPx.height / outputSize.height)
        let tx1 = Float(quadPx.minX)
        let ty1 = Float(quadPx.minY)
        let cx_rot = Float(rotW / 2)
        let cy_rot = Float(rotH / 2)
        let cx_crop = Float(cropW / 2)
        let cy_crop = Float(cropH / 2)
        let cosR = Float(cos(rotationRadians))
        let sinR = Float(sin(rotationRadians))
        let tx_roi = Float(roi.minX)
        let ty_roi = Float(roi.minY)

        // M = M_roi_shift · M_rotate_center_compose · M_shift_post_quad · M_scale_canonical
        //
        // Step A (scale canonical → quad): u' = sx·x, v' = sy·y
        //   [sx 0 0; 0 sy 0; 0 0 1]
        // Step B (translate quad offset): u'' = u' + tx1, v'' = v' + ty1
        //   [1 0 tx1; 0 1 ty1; 0 0 1]
        // Step C (rotate around center): complex — shift to rot center, rotate, shift to crop center
        //   T(-cx_rot, -cy_rot) · R(rotRadians inverted = -rotRadians) · T(cx_crop, cy_crop)
        //   But wait — we need inverse of forward rotation. Forward rotation mapped
        //   crop → rot by rotating around crop center θ. Inverse: rotate post-rot
        //   point by -θ around rot center, then re-anchor to crop center.
        //
        //   Concretely: point P_rot ∈ post-rotate space. To get P_crop:
        //     P_centered_rot = P_rot - (rotW/2, rotH/2)
        //     P_centered_crop = R(-θ) · P_centered_rot
        //     P_crop = P_centered_crop + (cropW/2, cropH/2)
        //
        //   R(-θ) = [ cos θ, sin θ; -sin θ, cos θ ]
        //
        // Step D (translate to raw frame): P_src = P_crop + (roi.x, roi.y)

        // Let's compose incrementally. P = dst pixel (x, y).
        // After Step A+B:
        //   u_B = sx·x + tx1
        //   v_B = sy·y + ty1
        // After Step C (shift to rot center → rotate → shift to crop center):
        //   u_C_centered = (u_B - rotW/2)·cos θ + (v_B - rotH/2)·sin θ
        //   v_C_centered = -(u_B - rotW/2)·sin θ + (v_B - rotH/2)·cos θ
        //   u_C = u_C_centered + cropW/2
        //   v_C = v_C_centered + cropH/2
        // After Step D:
        //   u_src = u_C + roi.x
        //   v_src = v_C + roi.y
        //
        // Expanding as matrix — 3×3 affine acting on [x, y, 1]:
        //   u_B coefficient on x = sx, on y = 0, const = tx1 - rotW/2
        //   v_B coefficient on x = 0, on y = sy, const = ty1 - rotH/2
        //   u_C_centered = u_B·cos θ + v_B·sin θ  (after subtracting rotW/2, rotH/2 from inside)
        //     = (sx·x + tx1 - rotW/2)·cos θ + (sy·y + ty1 - rotH/2)·sin θ
        //     = sx·cos θ·x + sy·sin θ·y + [(tx1 - rotW/2)·cos θ + (ty1 - rotH/2)·sin θ]
        //   v_C_centered = -u_B·sin θ + v_B·cos θ
        //     = -(sx·x + tx1 - rotW/2)·sin θ + (sy·y + ty1 - rotH/2)·cos θ
        //     = -sx·sin θ·x + sy·cos θ·y + [-(tx1 - rotW/2)·sin θ + (ty1 - rotH/2)·cos θ]
        //   u_C = u_C_centered + cropW/2
        //   v_C = v_C_centered + cropH/2
        //   u_src = u_C + roi.x
        //   v_src = v_C + roi.y

        let bx = tx1 - Float(rotW / 2)   // = tx1 - cx_rot*2/... actually cx_rot = rotW/2 as defined
        // Re-derive cleanly:
        let shiftB_x = tx1 - cx_rot
        let shiftB_y = ty1 - cy_rot

        let m00 = sx * cosR
        let m01 = sy * sinR
        let m02 = shiftB_x * cosR + shiftB_y * sinR + cx_crop + tx_roi

        let m10 = -sx * sinR
        let m11 = sy * cosR
        let m12 = -shiftB_x * sinR + shiftB_y * cosR + cy_crop + ty_roi

        // simd_float3x3 columns (simd convention: column-major)
        let col0 = simd_float3(m00, m10, 0)
        let col1 = simd_float3(m01, m11, 0)
        let col2 = simd_float3(m02, m12, 1)
        _ = bx  // silence unused warning
        return simd_float3x3(columns: (col0, col1, col2))
    }

    /// Helper — applies matrix to a point for testing.
    static func apply(_ m: simd_float3x3, to point: CGPoint) -> CGPoint {
        let v = m * simd_float3(Float(point.x), Float(point.y), 1)
        return CGPoint(x: CGFloat(v.x / v.z), y: CGFloat(v.y / v.z))
    }
}
