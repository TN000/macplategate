import Foundation
import os

/// OSSignpost instrumentation pro Instruments Time Profiler + Points of Interest.
///
/// **Use:** spusť Instruments → Time Profiler (nebo "Points of Interest") → vyber SPZ.app
/// → record. V swim lanes uvidíš per-frame breakdown: RTP depacketize → H265 decode →
/// CI render → Vision OCR → commit. Každá vrstva vlastní barvou.
///
/// **Zero overhead** když Instruments neattach — `OSSignposter.beginInterval` je
/// no-op pokud os_signpost_enabled(log) == false. Bezpečné nechat permanentně zapojené.
enum SPZSignposts {
    /// Hlavní subsystem log. Všechny naše signposty chodí sem.
    static let log = OSLog(subsystem: "app.macplategate", category: "pipeline")

    /// Modernější API — `OSSignposter` s auto-ID allocation a hierarchical intervals.
    static let signposter = OSSignposter(subsystem: "app.macplategate", category: "pipeline")

    /// Známé názvy intervalů — konzistentní napříč místy volání, lepší filter v Instruments.
    enum Name {
        static let rtpDepacketize: StaticString = "RTP.depacketize"
        static let h265Decode: StaticString = "H265.decode"        // flushAU → VT output callback
        static let h265Configure: StaticString = "H265.configure"  // VPS/SPS/PPS bootstrap
        static let metalPreview: StaticString = "Metal.preview"    // CIImage → CAMetalLayer render
        static let pipelineTick: StaticString = "Pipeline.tick"    // PlatePipeline poll
        static let visionOCR: StaticString = "Vision.OCR"          // VNRecognizeTextRequest
        static let plateCommit: StaticString = "Plate.commit"      // tracker → DB/JSONL/webhook
    }
}
