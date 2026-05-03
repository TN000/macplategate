import Foundation

/// Parsovaný SDP description z RTSP DESCRIBE odpovědi. Obsahuje vše co potřebujeme
/// pro setup VTDecompressionSession a interleaved RTP.
///
/// VIGI C250 SDP příklad:
/// ```
/// v=0
/// o=- 14665860 31787219 1 IN IP4 192.0.2.162
/// s=Session streamed by "TP-LINK RTSP Server"
/// t=0 0
/// a=smart_encoder:virtualIFrame=1
/// m=video 0 RTP/AVP 96
/// c=IN IP4 0.0.0.0
/// b=AS:4096
/// a=range:npt=0-
/// a=control:track1
/// a=rtpmap:96 H265/90000
/// a=fmtp:96 profile-space=0;profile-id=1;tier-flag=0;level-id=150;sprop-vps=QAEMAf//AWAAAAMA…;sprop-sps=QgEBAWAAAAMA…;sprop-pps=RAHAcvCcPHmyQA==
/// m=audio 0 RTP/AVP 8
/// a=control:track2
/// ```
struct SDPDescription {
    /// Video track control URL suffix (relative). Např. "track1".
    let videoControlPath: String
    /// RTP payload type (typicky 96 dynamic).
    let videoPayloadType: UInt8
    /// Codec name (musíme verifikovat == "H265" — H264/AAC etc. nepodporujeme zatím).
    let videoCodec: String
    /// Clock rate (H265 = 90000 Hz).
    let videoClockRate: UInt32
    /// H265 parameter sets — Annex-B raw NAL units (bez startcode prefixu).
    /// Caller je předá VTDecompressionSession jako CMVideoFormatDescription.
    ///
    /// Mohou být **prázdné** (`Data()`) — některé kamery/firmwary VPS/SPS/PPS
    /// v SDP neposílají a spoléhají na in-band bootstrap z prvního IDR framu.
    /// `H265Decoder` zachytí NAL types 32/33/34 přímo z RTP streamu a
    /// konfiguruje se sám. Caller v tom případě `decoder.configure(...)` nevolá.
    let vps: Data
    let sps: Data
    let pps: Data

    /// True pokud všechny tři parameter sets jsou k dispozici a decoder
    /// může být nakonfigurován hned ze SDP.
    var hasParameterSets: Bool { !vps.isEmpty && !sps.isEmpty && !pps.isEmpty }
}

enum SDPParserError: Error, CustomStringConvertible {
    case missingVideoMedia
    case unsupportedCodec(String)
    case missingFmtp
    case missingParameterSet(String)
    case invalidBase64(String)
    case invalidPayloadType(String)

    var description: String {
        switch self {
        case .missingVideoMedia: return "SDP nemá m=video sekci"
        case .unsupportedCodec(let c): return "Nepodporovaný codec: \(c) (jen H265)"
        case .missingFmtp: return "SDP fmtp řádka chybí pro video payload"
        case .missingParameterSet(let s): return "Chybí sprop-\(s) parametr v fmtp"
        case .invalidBase64(let s): return "sprop-\(s) base64 dekódování selhalo"
        case .invalidPayloadType(let s): return "Neplatný payload type: \(s)"
        }
    }
}

enum SDPParser {
    /// Parsuje raw SDP string (typicky z body RTSP DESCRIBE odpovědi).
    /// Zpracovává jen video media; audio a další tracks ignoruje (pro SPZ irrelevant).
    static func parse(_ sdpText: String) throws -> SDPDescription {
        // SDP je line-based, "\r\n" oddělené (per RFC 4566). Foundation
        // components(separatedBy:) je reliable pro multi-character separator
        // (Swift split(separator: Character) by sice taky fungoval, ale je
        // jednodušší trim a být explicit).
        let normalized = sdpText.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var inVideo = false
        var videoPayload: UInt8? = nil
        var videoControl: String? = nil
        var rtpmap: (codec: String, clock: UInt32)? = nil
        var fmtpParams: [String: String] = [:]

        for line in lines {
            // m=video 0 RTP/AVP 96
            if line.hasPrefix("m=") {
                let isVideo = line.hasPrefix("m=video")
                inVideo = isVideo
                if isVideo {
                    let parts = line.components(separatedBy: " ").filter { !$0.isEmpty }
                    // m=video <port> <proto> <pt>
                    if parts.count >= 4, let pt = UInt8(parts[3]) {
                        videoPayload = pt
                    } else {
                        throw SDPParserError.invalidPayloadType(line)
                    }
                }
                continue
            }
            guard inVideo else { continue }

            // a=control:track1
            if line.hasPrefix("a=control:") {
                videoControl = String(line.dropFirst("a=control:".count))
                continue
            }
            // a=rtpmap:96 H265/90000
            if line.hasPrefix("a=rtpmap:") {
                let body = String(line.dropFirst("a=rtpmap:".count))
                let parts = body.components(separatedBy: " ").filter { !$0.isEmpty }
                if parts.count >= 2 {
                    let codecParts = parts[1].components(separatedBy: "/")
                    if codecParts.count >= 2,
                       let clock = UInt32(codecParts[1]) {
                        rtpmap = (codec: codecParts[0].uppercased(), clock: clock)
                    }
                }
                continue
            }
            // a=fmtp:96 profile-space=0;profile-id=1;...;sprop-vps=BASE64;sprop-sps=BASE64;sprop-pps=BASE64
            if line.hasPrefix("a=fmtp:") {
                let body = String(line.dropFirst("a=fmtp:".count))
                // Po "<pt> " jsou params separated by ";"
                guard let firstSpace = body.firstIndex(of: " ") else { continue }
                let paramStr = String(body[body.index(after: firstSpace)...])
                for kv in paramStr.components(separatedBy: ";") {
                    let trimmed = kv.trimmingCharacters(in: .whitespaces)
                    if let eq = trimmed.firstIndex(of: "=") {
                        let k = String(trimmed[..<eq])
                        let v = String(trimmed[trimmed.index(after: eq)...])
                        fmtpParams[k] = v
                    }
                }
                continue
            }
        }

        guard videoPayload != nil else { throw SDPParserError.missingVideoMedia }
        guard let map = rtpmap else { throw SDPParserError.missingFmtp }
        // Zatím podporujeme pouze H265. H264 by vyžadovalo svůj depacketizer (RFC 6184) a
        // jiný NAL header layout — nedělat dnes.
        guard map.codec == "H265" || map.codec == "HEVC" else {
            throw SDPParserError.unsupportedCodec(map.codec)
        }

        // Parameter sets (VPS/SPS/PPS) jsou PREFEROVANÉ ale ne POVINNÉ — některé
        // RTSP servery je neposílají v fmtp a spoléhají na in-band bootstrap
        // z IDR framu. Pokud chybí, vrátíme prázdné Data a H265Decoder se
        // nakonfiguruje dynamicky z prvních VPS/SPS/PPS NAL unitů v RTP streamu.
        func parseOrWarn(_ key: String) -> Data {
            guard let b64 = fmtpParams["sprop-\(key)"] else {
                FileHandle.safeStderrWrite(
                    "[SDPParser] sprop-\(key) chybí v fmtp — in-band bootstrap\n"
                        .data(using: .utf8)!)
                return Data()
            }
            guard let data = decodeBase64(b64) else {
                FileHandle.safeStderrWrite(
                    "[SDPParser] sprop-\(key) base64 decode selhal — in-band fallback\n"
                        .data(using: .utf8)!)
                return Data()
            }
            return data
        }
        let vps = parseOrWarn("vps")
        let sps = parseOrWarn("sps")
        let pps = parseOrWarn("pps")

        return SDPDescription(
            videoControlPath: videoControl ?? "",
            videoPayloadType: videoPayload!,
            videoCodec: map.codec,
            videoClockRate: map.clock,
            vps: vps, sps: sps, pps: pps
        )
    }

    /// SDP base64 hodnoty někdy obsahují `,` separator pro multiple parameter sets.
    /// Audit #10: bereme jen první PS z comma-separated seznamu (typický VIGI/TP-Link
    /// případ — vždy single VPS/SPS/PPS). Pro Hikvision/multi-slice encoders s N
    /// parameter sets by bylo třeba iterovat a configure() postupně. Nepřekáží nám
    /// protože H265Decoder má in-band bootstrap path: když SDP je neúplný, decoder
    /// se zbootstrapuje z IDR v RTP streamu (VPS/SPS/PPS NAL types 32/33/34).
    private static func decodeBase64(_ str: String) -> Data? {
        let cleaned = str.split(separator: ",").first.map(String.init) ?? str
        // Apple Data(base64Encoded:) přijímá standard alphabet (+ / =), tolerantní k whitespace.
        return Data(base64Encoded: cleaned, options: [.ignoreUnknownCharacters])
    }
}
