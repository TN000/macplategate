import Foundation
import AppKit
import CoreImage
import CoreVideo

/// Helper pro načítání statických „zmrazených" snímků (uložených JPG/HEIC),
/// jejich konverzi na CVPixelBuffer a poskytování příslušných CGImage cache.
///
/// Use case: uživatel si vyfotí celý stream během průjezdu auta (přes Snap
/// photo v fullPreview módu nebo manuálně) a chce ho pak v klidu použít k
/// nastavení ROI / kalibraci perspektivy bez potřeby další skutečné jízdy.
enum FrozenFrame {

    /// Načte image z disku a převede na BGRA CVPixelBuffer kompatibilní
    /// s živým streamem (CIImage ho akceptuje stejně jako NV12).
    static func loadPixelBuffer(from url: URL) -> CVPixelBuffer? {
        guard let nsImage = NSImage(contentsOf: url) else { return nil }
        return makePixelBuffer(from: nsImage)
    }

    /// Konvertuje NSImage → CVPixelBuffer (BGRA).
    static func makePixelBuffer(from nsImage: NSImage) -> CVPixelBuffer? {
        guard let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return makePixelBuffer(from: cg)
    }

    /// Konvertuje CGImage → CVPixelBuffer (BGRA, full range).
    static func makePixelBuffer(from cg: CGImage) -> CVPixelBuffer? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pb: CVPixelBuffer?
        let rc = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                     kCVPixelFormatType_32BGRA,
                                     attrs as CFDictionary, &pb)
        guard rc == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let base = CVPixelBufferGetBaseAddress(pb)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue
                 | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: base, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: cs, bitmapInfo: info) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return pb
    }

    /// Konvertuje CVPixelBuffer (libovolný formát) na CGImage — pro statický
    /// preview v fullStreamStage během ROI selectu při zmrazeném snímku.
    /// Sdílený CIContext (SharedCIContext.shared) — vytváření kontextu je
    /// drahá operace, opakované volání by alokovalo ~10 MB GPU resources
    /// per call.
    static func makeCGImage(from pb: CVPixelBuffer) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: pb)
        return SharedCIContext.shared.createCGImage(ci, from: ci.extent)
    }
}
