import Foundation
import CoreImage

/// Sdílená CIContext instance pro celou aplikaci. CIContext alokace je ~MB a má
/// interní GPU state cache, takže několik instancí = zbytečná paměť + overhead.
///
/// Konfigurace: Metal renderer (useSoftwareRenderer=false) + **color management vypnutý**
/// (workingColorSpace/outputColorSpace = NSNull). Bez color mgmt je crop raw-pixel copy
/// bez sRGB gamma konverze, jinak by gamma degradovala OCR confidence na malých ROI cropech.
enum SharedCIContext {
    static let shared: CIContext = {
        let opts: [CIContextOption: Any] = [
            .useSoftwareRenderer: false,
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
            // cacheIntermediates=false: každý frame má unikátní pixel buffer, cache
            // between invocations nepomáhá a CIContext pool by jinak rostl ~5 MB/min.
            .cacheIntermediates: false,
        ]
        return CIContext(options: opts)
    }()
}
