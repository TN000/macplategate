import Testing
import Foundation
@testable import SPZApp

@Suite("SDPParser")
struct SDPParserTests {

    /// Typický SDP z VIGI C250 — base64 VPS/SPS/PPS v fmtp, H265 payload type 96.
    private let vigiSDP = """
    v=0\r
    o=- 14665860 31787219 1 IN IP4 192.0.2.162\r
    s=Session streamed by "TP-LINK RTSP Server"\r
    t=0 0\r
    a=smart_encoder:virtualIFrame=1\r
    m=video 0 RTP/AVP 96\r
    c=IN IP4 0.0.0.0\r
    b=AS:4096\r
    a=range:npt=0-\r
    a=control:track1\r
    a=rtpmap:96 H265/90000\r
    a=fmtp:96 profile-space=0;profile-id=1;tier-flag=0;level-id=150;sprop-vps=QAEMAf//AWAAAAMAAAMAAAMAAAMAlqwJ;sprop-sps=QgEBAWAAAAMAAAMAAAMAAAMAlqADKIALQf4qtO6JLubgwMDAgA27oADN/mAE;sprop-pps=RAHAcvCUNNkg\r
    m=audio 0 RTP/AVP 8\r
    a=rtpmap:8 PCMA/8000\r
    a=control:track2\r
    a=recvonly\r
    """

    @Test func parsesVIGISDP_extractsVideoTrack() throws {
        let desc = try SDPParser.parse(vigiSDP)
        #expect(desc.videoCodec == "H265")
        #expect(desc.videoPayloadType == 96)
        #expect(desc.videoClockRate == 90000)
        #expect(desc.videoControlPath == "track1")
    }

    @Test func parsesVIGISDP_decodesParameterSets() throws {
        let desc = try SDPParser.parse(vigiSDP)
        // VPS = 24 B (starts with 0x40 = NAL type 32 = VPS)
        #expect(desc.vps.count == 24)
        #expect(desc.vps[0] == 0x40)
        // SPS = 45 B (starts with 0x42 = NAL type 33 = SPS)
        #expect(desc.sps.count == 45)
        #expect(desc.sps[0] == 0x42)
        // PPS = 9 B (starts with 0x44 = NAL type 34 = PPS)
        #expect(desc.pps.count == 9)
        #expect(desc.pps[0] == 0x44)
        #expect(desc.hasParameterSets)
    }

    @Test func tolerates_LF_only_lineEndings() throws {
        let lfSdp = vigiSDP.replacingOccurrences(of: "\r\n", with: "\n")
        let desc = try SDPParser.parse(lfSdp)
        #expect(desc.videoCodec == "H265")
        #expect(desc.vps.count > 0)
    }

    @Test func missingVideoMedia_throws() {
        let audioOnly = """
        v=0\r
        m=audio 0 RTP/AVP 8\r
        a=rtpmap:8 PCMA/8000\r
        """
        #expect(throws: SDPParserError.self) {
            try SDPParser.parse(audioOnly)
        }
    }

    @Test func unsupportedCodec_H264_throws() {
        let h264 = """
        v=0\r
        m=video 0 RTP/AVP 96\r
        a=rtpmap:96 H264/90000\r
        a=fmtp:96 profile-level-id=42001f\r
        """
        #expect(throws: SDPParserError.self) {
            try SDPParser.parse(h264)
        }
    }

    @Test func missingParameterSets_returnsEmptyData_forInBandBootstrap() throws {
        // Některé kamery neposílají sprop-* v fmtp a spoléhají na in-band VPS/SPS/PPS
        // v RTP streamu. Parser musí takový SDP přijmout (empty Data) — H265Decoder
        // se pak bootstrapne z prvního IDR NAL unitů.
        let noSprop = """
        v=0\r
        m=video 0 RTP/AVP 96\r
        a=control:track1\r
        a=rtpmap:96 H265/90000\r
        a=fmtp:96 profile-id=1\r
        """
        let desc = try SDPParser.parse(noSprop)
        #expect(desc.videoCodec == "H265")
        #expect(desc.vps.isEmpty)
        #expect(desc.sps.isEmpty)
        #expect(desc.pps.isEmpty)
        #expect(!desc.hasParameterSets)
    }

    @Test func hasParameterSets_falseWhenAnyMissing() throws {
        // Jen VPS, bez SPS/PPS → hasParameterSets false (partial config unusable)
        let partial = """
        v=0\r
        m=video 0 RTP/AVP 96\r
        a=rtpmap:96 H265/90000\r
        a=fmtp:96 sprop-vps=QAEMAf//AWAAAAMAAAMAAAMAAAMAlqwJ\r
        """
        let desc = try SDPParser.parse(partial)
        #expect(desc.vps.count > 0)
        #expect(desc.sps.isEmpty)
        #expect(!desc.hasParameterSets)
    }

    @Test func fmtp_spacedParams_parsedCorrectly() throws {
        // Některé servery vkládají whitespace mezi ";" a klíčem — parser musí tolerovat.
        let spacedFmtp = """
        v=0\r
        m=video 0 RTP/AVP 96\r
        a=rtpmap:96 H265/90000\r
        a=fmtp:96 profile-id=1; sprop-vps=QAEMAf//AWAAAAMAAAMAAAMAAAMAlqwJ; sprop-sps=QgEBAWAAAAMAAAMAAAMAAAMAlqADKIALQf4qtO6JLubgwMDAgA27oADN/mAE; sprop-pps=RAHAcvCUNNkg\r
        """
        let desc = try SDPParser.parse(spacedFmtp)
        #expect(desc.vps.count == 24)
        #expect(desc.sps.count == 45)
        #expect(desc.pps.count == 9)
    }
}
