import Foundation

/// H.265 (HEVC) RTP depacketizer per RFC 7798.
///
/// Vstupní RTP packet payload (po stripped 12-byte RTP header) obsahuje H265 NAL units
/// ve třech variantách:
/// - **Single NAL unit packet** — payload = jeden kompletní NAL (NAL type < 48)
/// - **Aggregation Packet (AP)** — payload = vícero NAL units zabalených pomocí
///   16-bit length prefixed slots (NAL type = 48)
/// - **Fragmentation Unit (FU)** — payload = část velkého NAL rozbitého do více
///   RTP packetů (NAL type = 49). Reassembly podle Start/End bitů.
///
/// Paged Aggregation (PACI, type 50) ignorujeme — VIGI/TP-Link produkce nepoužívá.
///
/// Výstup: úplné H265 NAL units v Annex-B formátu (s prefixem 0x00 0x00 0x00 0x01),
/// readyto-feed pro VTDecompressionSession (přes CMBlockBuffer).
final class RTPDepacketizer {
    /// Bere kompletní RTP packet (s headerem) a vrátí (NALs, isAUEnd) — seznam Annex-B
    /// NAL units kompletně obsažených v tomto packetu, plus bool označující M bit
    /// (RTP marker = poslední packet access unitu / konec frame). Decoder pak může
    /// flushnout celý AU jako jeden CMSampleBuffer.
    func process(rtpPacket: Data) -> (nals: [Data], isAUEnd: Bool) {
        let signpostID = SPZSignposts.signposter.makeSignpostID()
        let state = SPZSignposts.signposter.beginInterval(SPZSignposts.Name.rtpDepacketize, id: signpostID)
        defer { SPZSignposts.signposter.endInterval(SPZSignposts.Name.rtpDepacketize, state) }
        guard let header = parseRTPHeader(rtpPacket) else { return ([], false) }
        let payload = rtpPacket.subdata(in: header.payloadOffset..<rtpPacket.count)
        guard payload.count >= 2 else { return ([], false) }

        // Audit fix #3: RTP sequence-number gap detection. Per RFC 3550 §3.2 má seq monotonicky
        // rostoucí (s modulo 2^16 wraparound). Gap → packet loss → FU reassembly corruption.
        // Rozlišujeme tři případy:
        //   seq == prev         — duplicate (retransmit, valid per RFC) → ignore, drop payload
        //   seq == prev + 1     — expected next → happy path
        //   jinak               — gap/reorder → log + zahodit fuBuffer (corrupted reassembly)
        if let prev = lastSequence {
            let expected = prev &+ 1
            if header.sequenceNumber == prev {
                // Duplicate RTP packet — silently ignore (neupdatovat state)
                return ([], false)
            }
            if header.sequenceNumber != expected {
                let gap = Int(Int16(bitPattern: header.sequenceNumber &- expected))
                droppedPackets &+= abs(gap)
                if droppedPackets <= 10 || droppedPackets % 50 == 0 {
                    FileHandle.safeStderrWrite(
                        "[RTPDepacketizer] RTP gap: prev=\(prev) got=\(header.sequenceNumber) (gap=\(gap), total dropped=\(droppedPackets))\n"
                            .data(using: .utf8)!)
                }
                if fuBuffer != nil {
                    fuBuffer = nil  // corrupted reassembly — zahodit
                }
            }
        }
        lastSequence = header.sequenceNumber

        // H265 NAL header je 2 bytes (vs H264 1 byte):
        //   F (1) | NAL Type (6) | LayerId (6) | TID (3)
        // První byte = (F<<7) | (NalType<<1) | (LayerId>>5)
        // Druhý byte = ((LayerId & 0x1F) << 3) | TID
        let nalUnitType = (payload[0] >> 1) & 0x3F

        switch nalUnitType {
        case 48:  // AP — Aggregation Packet
            return (parseAggregationPacket(payload: payload), header.marker)
        case 49:  // FU — Fragmentation Unit
            if let nal = parseFragmentationUnit(payload: payload, marker: header.marker) {
                return ([nal], header.marker)
            }
            return ([], header.marker)
        case 50:  // PACI — neimplementováno (VIGI nepoužívá)
            return ([], header.marker)
        default:
            return ([annexBPrefix(payload)], header.marker)
        }
    }

    /// Reset interního stavu (volá se při disconnect / RTSP TEARDOWN).
    func reset() {
        fuBuffer = nil
        fuType = 0
        fuLayerId = 0
        fuTID = 0
        lastSequence = nil
        droppedPackets = 0
    }

    /// Audit fix #3: RTP sequence tracking pro gap detection a FU reassembly integrity.
    /// Sequence wraparound 65535 → 0 je handled přes UInt16 `&-` arithmetic.
    private var lastSequence: UInt16? = nil
    private var droppedPackets: Int = 0

    // MARK: - RTP header parse

    private struct RTPHeader {
        let marker: Bool         // M bit — typicky pro H265 značí poslední fragment NAL nebo VCL boundary
        let sequenceNumber: UInt16
        let timestamp: UInt32
        let payloadOffset: Int   // index v packetu kde začíná payload
    }

    /// RFC 3550 § 5.1 RTP header — fixed 12 B, optional CSRC list, optional extension.
    private func parseRTPHeader(_ data: Data) -> RTPHeader? {
        guard data.count >= 12 else { return nil }
        let firstByte = data[0]
        let version = firstByte >> 6
        guard version == 2 else { return nil }
        let cc = Int(firstByte & 0x0F)         // CSRC count
        let extensionPresent = (firstByte & 0x10) != 0
        let secondByte = data[1]
        let marker = (secondByte & 0x80) != 0

        let seqNum = (UInt16(data[2]) << 8) | UInt16(data[3])
        let ts = (UInt32(data[4]) << 24) | (UInt32(data[5]) << 16)
                | (UInt32(data[6]) << 8) | UInt32(data[7])

        var offset = 12 + 4 * cc  // skip CSRC list
        if extensionPresent {
            // Extension header: 2 B profile + 2 B length (in 32-bit words)
            guard data.count >= offset + 4 else { return nil }
            let extLen = (Int(data[offset + 2]) << 8) | Int(data[offset + 3])
            offset += 4 + 4 * extLen
        }
        guard data.count > offset else { return nil }
        return RTPHeader(marker: marker, sequenceNumber: seqNum,
                         timestamp: ts, payloadOffset: offset)
    }

    // MARK: - Aggregation Packet (AP)

    /// AP layout: AP header (2 B = NAL type 48) následovaný N krát:
    ///   2 B size + N B NAL data.
    /// Optional DONL (decoding order number) per fmtp `sprop-max-don-diff` — neřešíme,
    /// VIGI nepoužívá.
    private func parseAggregationPacket(payload: Data) -> [Data] {
        var out: [Data] = []
        var idx = 2  // skip AP header
        while idx + 2 <= payload.count {
            let size = (Int(payload[idx]) << 8) | Int(payload[idx + 1])
            idx += 2
            guard idx + size <= payload.count, size > 0 else { break }
            let nalRange = idx..<(idx + size)
            out.append(annexBPrefix(payload.subdata(in: nalRange)))
            idx += size
        }
        return out
    }

    // MARK: - Fragmentation Unit (FU)

    /// FU layout:
    ///   2 B FU header (NAL type 49 ve standard NAL bytes) + 1 B FU header
    ///   FU header byte: S(1) | E(1) | FuType(6)
    /// Pokud S=1 → start, alokujeme buffer; následující packety appendují data;
    /// E=1 → konec, vrátíme reassembled NAL.
    private var fuBuffer: Data? = nil
    private var fuType: UInt8 = 0
    private var fuLayerId: UInt8 = 0
    private var fuTID: UInt8 = 0
    private var fuLostStartCount: Int = 0

    private func parseFragmentationUnit(payload: Data, marker: Bool) -> Data? {
        guard payload.count >= 3 else { return nil }
        // Original NAL header byty 0-1 jsou nahrazené FU NAL type 49.
        // Z původního headeru musíme vytáhnout LayerId + TID.
        // První byte original (před FU): F + OrigNalType + LayerId(MSB)
        // FU packet: bytes [0,1] = NAL type 49 header, byte [2] = FU header
        let layerId = ((payload[0] & 0x01) << 5) | (payload[1] >> 3)
        let tid = payload[1] & 0x07
        let fuHeader = payload[2]
        let start = (fuHeader & 0x80) != 0
        let end = (fuHeader & 0x40) != 0
        let origNalType = fuHeader & 0x3F

        let fragData = payload.subdata(in: 3..<payload.count)

        if start {
            // Začátek nového NAL — alokuj buffer s rekonstruovaným NAL headerem.
            // Reconstruct NAL header: F(0) | OrigType(6) | LayerId(6) | TID(3)
            var nalHeader = Data(count: 2)
            nalHeader[0] = (origNalType << 1) | (layerId >> 5)
            nalHeader[1] = ((layerId & 0x1F) << 3) | tid
            fuBuffer = nalHeader
            fuBuffer?.append(fragData)
            fuType = origNalType
            fuLayerId = layerId
            fuTID = tid
            // Pokud je single-fragment (start+end na jednom packetu, nestandardní ale možné)
            if end {
                let result = fuBuffer
                fuBuffer = nil
                return result.map { annexBPrefix($0) }
            }
            return nil
        }

        // Continuation — append do existujícího bufferu (pokud máme).
        guard fuBuffer != nil else {
            // Lost first fragment — drop celý NAL. Audit fix #3: log pro observability.
            fuLostStartCount &+= 1
            if fuLostStartCount <= 5 || fuLostStartCount % 50 == 0 {
                FileHandle.safeStderrWrite(
                    "[RTPDepacketizer] FU continuation bez start (lost FU-S packet) — count=\(fuLostStartCount)\n"
                        .data(using: .utf8)!)
            }
            return nil
        }
        fuBuffer?.append(fragData)

        if end || marker {
            let result = fuBuffer
            fuBuffer = nil
            return result.map { annexBPrefix($0) }
        }
        return nil
    }

    // MARK: - Annex-B framing

    /// Připojí Annex-B startcode prefix (00 00 00 01) před NAL data. VTDecompressionSession
    /// pak konzumuje skrze CMBlockBuffer + parameter sets ve format description.
    private func annexBPrefix(_ nal: Data) -> Data {
        var out = Data(capacity: nal.count + 4)
        out.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        out.append(nal)
        return out
    }
}
