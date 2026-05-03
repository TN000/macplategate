import Testing
import Foundation
@testable import SPZApp

@Suite("RTPDepacketizer")
struct RTPDepacketizerTests {

    /// Vytvoří minimální RTP packet (12B header + payload). Seq/timestamp/SSRC na defaulty.
    private func rtp(payload: [UInt8], marker: Bool = false, seq: UInt16 = 1) -> Data {
        var pkt = Data()
        // Byte 0: V=2 (0x80), P=0, X=0, CC=0
        pkt.append(0x80)
        // Byte 1: M bit + PT (96 dynamic pro H265)
        pkt.append((marker ? 0x80 : 0x00) | 0x60)
        // Seq number BE
        pkt.append(UInt8((seq >> 8) & 0xFF))
        pkt.append(UInt8(seq & 0xFF))
        // Timestamp BE (4 B)
        pkt.append(contentsOf: [0, 0, 0, 0])
        // SSRC BE (4 B)
        pkt.append(contentsOf: [0, 0, 0, 1])
        // Payload
        pkt.append(contentsOf: payload)
        return pkt
    }

    @Test func singleNAL_passesThroughWithAnnexBPrefix() {
        let dep = RTPDepacketizer()
        // Single NAL: NAL header byte 0 with NAL type 19 (IDR_W_RADL) = (19<<1)|0 = 0x26
        let nal: [UInt8] = [0x26, 0x01, 0xAF, 0xBE, 0xEF]
        let result = dep.process(rtpPacket: rtp(payload: nal, marker: true))
        #expect(result.nals.count == 1)
        #expect(result.isAUEnd)
        // Output = Annex-B startcode + NAL body
        let expected: [UInt8] = [0x00, 0x00, 0x00, 0x01] + nal
        #expect(Array(result.nals[0]) == expected)
    }

    @Test func aggregationPacket_unpacksMultipleNALs() {
        let dep = RTPDepacketizer()
        // AP NAL type = 48. Payload = [AP header 2B][size1 2B][nal1][size2 2B][nal2]
        // AP header byte 0: NAL type 48 = (48<<1)|0 = 0x60
        let nal1: [UInt8] = [0x42, 0x01, 0x01, 0x02]  // SPS-like (NAL type 33)
        let nal2: [UInt8] = [0x44, 0x01, 0x03]         // PPS-like (NAL type 34)
        var payload: [UInt8] = [0x60, 0x01]  // AP header (2B)
        payload.append(0x00); payload.append(UInt8(nal1.count))
        payload.append(contentsOf: nal1)
        payload.append(0x00); payload.append(UInt8(nal2.count))
        payload.append(contentsOf: nal2)

        let result = dep.process(rtpPacket: rtp(payload: payload, marker: true))
        #expect(result.nals.count == 2)
        // Each NAL wrapped in Annex-B
        #expect(Array(result.nals[0].dropFirst(4)) == nal1)
        #expect(Array(result.nals[1].dropFirst(4)) == nal2)
    }

    @Test func fragmentationUnit_reassemblesAcrossPackets() {
        let dep = RTPDepacketizer()
        // FU layout: [FU NAL header 2B (type 49)][FU header 1B: S|E|Type][fragment data]
        // Original NAL type 19 (IDR), LayerId 0, TID 1
        // FU header byte 0: NAL type 49 = (49<<1)|0 = 0x62
        // FU header byte 1: LayerId low bits (0) << 3 | TID (1) = 0x01

        // Sekvenční seq per RFC 3550 — depacketizer má audit-fix #3 gap detection,
        // stejné seq by interpretoval jako duplicate a dropl payload.
        // Start fragment (S=1, E=0, FuType=19)
        let fuStart: [UInt8] = [0x62, 0x01, 0x80 | 0x13, 0xAA, 0xBB]
        let r1 = dep.process(rtpPacket: rtp(payload: fuStart, seq: 100))
        #expect(r1.nals.isEmpty)  // čekáme na další fragment

        // Middle fragment (S=0, E=0)
        let fuMid: [UInt8] = [0x62, 0x01, 0x13, 0xCC, 0xDD]
        let r2 = dep.process(rtpPacket: rtp(payload: fuMid, seq: 101))
        #expect(r2.nals.isEmpty)

        // End fragment (S=0, E=1)
        let fuEnd: [UInt8] = [0x62, 0x01, 0x40 | 0x13, 0xEE, 0xFF]
        let r3 = dep.process(rtpPacket: rtp(payload: fuEnd, marker: true, seq: 102))
        #expect(r3.nals.count == 1)
        #expect(r3.isAUEnd)

        // Reassembled NAL = reconstructed NAL header (2B) + concatenated fragment data
        let nal = r3.nals[0]
        // Annex-B prefix (4B)
        #expect(nal[0] == 0x00 && nal[1] == 0x00 && nal[2] == 0x00 && nal[3] == 0x01)
        // NAL header byte 0 = (origNalType 19 << 1) | layerIdHigh (0) = 0x26
        #expect(nal[4] == 0x26)
        // NAL header byte 1 = (layerIdLow 0 << 3) | TID (1) = 0x01
        #expect(nal[5] == 0x01)
        // Fragment body: AA BB CC DD EE FF
        let body = Array(nal.dropFirst(6))
        #expect(body == [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
    }

    @Test func fragmentationUnit_lostStartFragment_dropsSubsequent() {
        let dep = RTPDepacketizer()
        // Continuation bez start fragmentu = decoder dropne (fuBuffer nil)
        let fuMid: [UInt8] = [0x62, 0x01, 0x13, 0xCC, 0xDD]
        let r = dep.process(rtpPacket: rtp(payload: fuMid))
        #expect(r.nals.isEmpty)  // nothing yielded
    }

    @Test func markerBit_propagatesToIsAUEnd() {
        let dep = RTPDepacketizer()
        let nal: [UInt8] = [0x02, 0x01, 0xAA]  // TRAIL_N (type 1)

        let r1 = dep.process(rtpPacket: rtp(payload: nal, marker: false, seq: 400))
        #expect(r1.nals.count == 1)
        #expect(!r1.isAUEnd)

        let r2 = dep.process(rtpPacket: rtp(payload: nal, marker: true, seq: 401))
        #expect(r2.nals.count == 1)
        #expect(r2.isAUEnd)
    }

    @Test func emptyPayload_returnsNoNals() {
        let dep = RTPDepacketizer()
        let empty: [UInt8] = []
        let r = dep.process(rtpPacket: rtp(payload: empty))
        #expect(r.nals.isEmpty)
    }

    /// Audit fix #3: packet loss uprostřed FU reassembly → zahodit corrupted buffer.
    @Test func rtpGap_duringFUReassembly_dropsCorruptedBuffer() {
        let dep = RTPDepacketizer()
        let fuStart: [UInt8] = [0x62, 0x01, 0x80 | 0x13, 0xAA, 0xBB]
        _ = dep.process(rtpPacket: rtp(payload: fuStart, seq: 200))
        // Skip seq 201 (lost packet). seq 202 příjde jako FU-E, ale fuBuffer je kill-ed
        // gap detectorem → empty buffer → continuation bez start → drop.
        let fuEnd: [UInt8] = [0x62, 0x01, 0x40 | 0x13, 0xEE, 0xFF]
        let r = dep.process(rtpPacket: rtp(payload: fuEnd, marker: true, seq: 202))
        #expect(r.nals.isEmpty)  // gap zahodilo buffer
    }

    /// Audit fix #3: duplicate RTP seq (retransmit per RFC 3550) = ignore, ne gap.
    @Test func rtpDuplicate_isIgnored_notTreatedAsGap() {
        let dep = RTPDepacketizer()
        let nal: [UInt8] = [0x02, 0x01, 0xAA]  // TRAIL_N
        let r1 = dep.process(rtpPacket: rtp(payload: nal, seq: 300))
        #expect(r1.nals.count == 1)
        // Duplicate seq=300 → silent drop (neconsumuje state, nezahazuje buffer)
        let r2 = dep.process(rtpPacket: rtp(payload: nal, seq: 300))
        #expect(r2.nals.isEmpty)
        // Další sekvenční seq pokračuje normálně
        let r3 = dep.process(rtpPacket: rtp(payload: nal, marker: true, seq: 301))
        #expect(r3.nals.count == 1)
        #expect(r3.isAUEnd)
    }

    @Test func reset_clearsFUState() {
        let dep = RTPDepacketizer()
        let fuStart: [UInt8] = [0x62, 0x01, 0x80 | 0x13, 0xAA, 0xBB]
        _ = dep.process(rtpPacket: rtp(payload: fuStart))
        dep.reset()
        // Po resetu continuation fragment by měl být dropped (buffer cleared)
        let fuEnd: [UInt8] = [0x62, 0x01, 0x40 | 0x13, 0xCC]
        let r = dep.process(rtpPacket: rtp(payload: fuEnd, marker: true))
        #expect(r.nals.isEmpty)  // start byl zrušen, konec bez startu → drop
    }
}
