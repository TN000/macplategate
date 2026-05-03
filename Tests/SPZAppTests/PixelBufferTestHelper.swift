import Foundation
import CoreVideo

/// Synthetic CVPixelBuffer factory pro motion gate / preprocessing tests.
/// Vrací NV12 buffer s plně Y-plane controlled obsahem; chroma plane (UV)
/// je vyplněn neutral šedou (128, 128) — testy se na něj nedotýkají.
enum PixelBufferTestHelper {
    /// `yFill: (x, y) -> luma 0-255` — naplní Y plane podle callback.
    static func makeNV12(width: Int, height: Int,
                         yFill: (Int, Int) -> UInt8) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                          kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                          attrs as CFDictionary, &pb)
        guard status == kCVReturnSuccess, let buf = pb else { return nil }

        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }

        // Y plane (plane 0)
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buf, 0) else { return nil }
        let yBpr = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
        let yPtr = yBase.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                yPtr[y * yBpr + x] = yFill(x, y)
            }
        }

        // UV plane (plane 1) — neutral 128 (gray).
        if let uvBase = CVPixelBufferGetBaseAddressOfPlane(buf, 1) {
            let uvBpr = CVPixelBufferGetBytesPerRowOfPlane(buf, 1)
            let uvPtr = uvBase.assumingMemoryBound(to: UInt8.self)
            let uvHeight = height / 2
            let uvWidth = width  // packed UV pairs = width bytes per row
            for y in 0..<uvHeight {
                for x in 0..<uvWidth {
                    uvPtr[y * uvBpr + x] = 128
                }
            }
        }
        return buf
    }
}
