import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import os

/// VideoToolbox H265 hardware decoder wrapper. Bere Annex-B NAL units (z RTPDepacketizer),
/// akumuluje je do **per-access-unit** bufferu a flushuje je jako JEDEN CMSampleBuffer
/// při každém konci AU (RTP marker bit). VTDecompressionSession na M4 media engine
/// dekóduje → vrací IOSurface-backed CVPixelBuffer přes output callback.
///
/// **Klíčová invariant:** HEVC multi-slice pictures vyžadují všechny slice NALs
/// stejného frame v jednom CMSampleBuffer. Feedovat slices po jednom = -12909
/// BadDataErr. VIGI C250 posílá min. VPS+SPS+PPS+SEI+IDR per keyframe = 5+ NAL
/// units jednoho access unitu.
final class H265Decoder {
    /// Callback dispatched ze VT thread po úspěšném dekódování. CVPixelBuffer je už
    /// IOSurface-backed, můžeš ho přímo použít pro AVSampleBufferDisplayLayer.enqueue
    /// + Vision request handler. Caller je odpovědný za thread hop, pokud potřebuje.
    var onDecodedFrame: ((CVPixelBuffer, CMTime) -> Void)?

    // MARK: - Configuration state

    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var currentVPS: Data?
    private var currentSPS: Data?
    private var currentPPS: Data?
    private var pendingStreamVPS: Data? = nil
    private var pendingStreamSPS: Data? = nil
    private var pendingStreamPPS: Data? = nil

    // MARK: - Access unit buffering

    /// Akumulace AVCC bytes pro aktuální access unit. Každý VCL slice je konvertován
    /// z Annex-B na AVCC (4B big-endian length prefix + NAL body) a appendnut sem.
    /// `flushAU()` vytvoří jeden CMSampleBuffer s celým obsahem.
    private var auBuffer = Data()
    /// True pokud aktuální AU obsahuje IDR/CRA (sync point). Nastavíme správné
    /// sample attachments — DependsOnOthers=false pro keyframes.
    private var auIsKeyframe: Bool = false
    /// Timestamp hostime při startu AU — používá se jako PTS pro CMSampleBuffer.
    /// Valid PTS je důležitý: `.invalid` někdy způsobuje decoder glitches.
    private var auStartHostTime: CMTime = .invalid

    // MARK: - Diagnostics

    /// Dump first IDR AU to /tmp pro external ffmpeg validaci (pokud bychom měli bug
    /// v depacketizeru). Ověří se tím zda AVCC bytes jsou well-formed HEVC.
    private var didDumpFirstAU = false

    /// Counter race: `framesDecoded` čte output callback (VT thread), `auFlushed` čte
    /// addNAL/flushAU path (RTSP receive queue). Bez zámku = read-modify-write race
    /// → nepřesné logging metriky. `OSAllocatedUnfairLock` je lightweight wrapper
    /// (nemá malloc overhead, inline-friendly).
    fileprivate let framesDecodedLock = OSAllocatedUnfairLock<Int>(initialState: 0)
    fileprivate let auFlushedLock = OSAllocatedUnfairLock<Int>(initialState: 0)

    deinit {
        invalidate()
    }

    // MARK: - Configure

    /// Konfigurace/rekonfigurace z VPS/SPS/PPS. Unchanged → no-op. Při změně invaliduje
    /// starý session. Volá se automaticky z `addNAL` když se v streamu objeví VPS+SPS+PPS
    /// set (in-band bootstrap nebo mid-stream change).
    func configure(vps: Data, sps: Data, pps: Data) -> Bool {
        let signpost = SPZSignposts.signposter.beginInterval(SPZSignposts.Name.h265Configure)
        defer { SPZSignposts.signposter.endInterval(SPZSignposts.Name.h265Configure, signpost) }
        if currentVPS == vps, currentSPS == sps, currentPPS == pps, session != nil {
            return true
        }
        invalidate()
        auBuffer.removeAll(keepingCapacity: true)
        auIsKeyframe = false

        var fd: CMVideoFormatDescription? = nil
        let status = vps.withUnsafeBytes { vpsBuf -> OSStatus in
            sps.withUnsafeBytes { spsBuf -> OSStatus in
                pps.withUnsafeBytes { ppsBuf -> OSStatus in
                    guard let vpsP = vpsBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let spsP = spsBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let ppsP = ppsBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return -1
                    }
                    let pointers: [UnsafePointer<UInt8>] = [vpsP, spsP, ppsP]
                    let sizes: [Int] = [vps.count, sps.count, pps.count]
                    return pointers.withUnsafeBufferPointer { setsBuf in
                        sizes.withUnsafeBufferPointer { sizesBuf in
                            guard let setBase = setsBuf.baseAddress,
                                  let sizeBase = sizesBuf.baseAddress else {
                                return -1
                            }
                            return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                                allocator: kCFAllocatorDefault,
                                parameterSetCount: 3,
                                parameterSetPointers: setBase,
                                parameterSetSizes: sizeBase,
                                nalUnitHeaderLength: 4,  // AVCC 4-byte length prefix
                                extensions: nil,
                                formatDescriptionOut: &fd
                            )
                        }
                    }
                }
            }
        }
        guard status == noErr, let fd = fd else {
            FileHandle.safeStderrWrite(
                "[H265Decoder] format desc create failed: \(status)\n".data(using: .utf8)!)
            return false
        }
        let dims = CMVideoFormatDescriptionGetDimensions(fd)
        FileHandle.safeStderrWrite(
            "[H265Decoder] format desc OK: \(dims.width)×\(dims.height) (vps=\(vps.count) sps=\(sps.count) pps=\(pps.count))\n"
                .data(using: .utf8)!)
        self.formatDescription = fd
        self.currentVPS = vps
        self.currentSPS = sps
        self.currentPPS = pps

        // Explicitní NV12 (biplanar 4:2:0 video range) — konzistentní s naším
        // sampleROIHash v PlatePipeline (čte Y plane jako byte[]) a CameraService
        // display layer enqueue. Bez explicitního formátu VT někdy produkuje
        // 10-bit nebo jiný layout → crash v downstream readech.
        //
        // Audit fix #2: CVPixelBufferPool hint přes `kCVPixelBufferPoolMinimumBufferCountKey`.
        // VT interně vytvoří CVPixelBufferPool co pre-alokuje N bufferů (s konzistentními
        // IOSurface IDs → GPU cache locality) a recykluje je místo per-frame alloc.
        // 6 buffers = 1 current display + 1 in-flight OCR + 1 Metal preview + 3 safety
        // margin pro bursty VT output nebo pomalý PlatePipeline pull.
        let pixelBufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferPoolMinimumBufferCountKey as String: 6,
        ]

        var outputCallback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: H265Decoder.decompressionCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        var sessionRef: VTDecompressionSession? = nil
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: fd,
            decoderSpecification: nil,
            imageBufferAttributes: pixelBufferAttrs as CFDictionary,
            outputCallback: &outputCallback,
            decompressionSessionOut: &sessionRef
        )
        guard sessionStatus == noErr, let session = sessionRef else {
            FileHandle.safeStderrWrite(
                "[H265Decoder] VTDecompressionSessionCreate failed: \(sessionStatus)\n"
                    .data(using: .utf8)!)
            return false
        }

        VTSessionSetProperty(session,
            key: kVTDecompressionPropertyKey_RealTime,
            value: kCFBooleanTrue)

        self.session = session
        return true
    }

    // MARK: - NAL input (from depacketizer)

    /// Přidá jeden Annex-B NAL do buffer. Parameter sets (VPS/SPS/PPS) se cachou
    /// a při kompletní trojici (re)konfigurují decoder. VCL NALs se konvertují na
    /// AVCC a akumulují do `auBuffer`. Volání `flushAU()` pak dekóduje celý AU.
    func addNAL(annexBNAL: Data) {
        guard annexBNAL.count > 4 else { return }
        let nalType = (annexBNAL[4] >> 1) & 0x3F
        let nalBody = annexBNAL.subdata(in: 4..<annexBNAL.count)

        // Audit fix #1: PTS musí být set na prvním NAL každé AU, bez ohledu na typ.
        // Dřív se nastavoval jen při `auBuffer.isEmpty` — ale když AU začíná VPS/SPS/PPS
        // (parameter set), ty se neappendují do auBuffer, takže PTS zůstal `.invalid`
        // pro celý AU. PTS = CMClockGetHostTimeClock() při prvním jakémkoli NALu nové AU.
        if auStartHostTime == .invalid {
            auStartHostTime = CMClockGetTime(CMClockGetHostTimeClock())
        }

        switch nalType {
        case 32: // VPS
            pendingStreamVPS = nalBody
            tryConfigureIfReady()
            return
        case 33: // SPS
            pendingStreamSPS = nalBody
            tryConfigureIfReady()
            return
        case 34: // PPS
            pendingStreamPPS = nalBody
            tryConfigureIfReady()
            return
        case 35, 36, 37, 38:  // AUD, EOS, EOB, FD — non-VCL, ignore (decoder nepotřebuje)
            return
        case 39, 40:  // SEI prefix/suffix — ignore (informational)
            return
        default:
            break
        }

        // VCL NAL (slice). Musíme mít session + format description.
        guard session != nil, formatDescription != nil else {
            return  // čekáme na bootstrap (VPS/SPS/PPS v streamu přijdou před IDR)
        }

        // Set keyframe flag pokud je IDR/CRA. Attachment na sample buffer ovlivní decoder.
        // Keyframe types: 19 (IDR_W_RADL), 20 (IDR_N_LP), 21 (CRA_NUT).
        if nalType == 19 || nalType == 20 || nalType == 21 {
            auIsKeyframe = true
        }

        // Append AVCC: [4B big-endian length][NAL body]. Length = NAL body size (neobsahuje
        // length prefix samotný).
        let len = UInt32(nalBody.count)
        auBuffer.append(UInt8((len >> 24) & 0xFF))
        auBuffer.append(UInt8((len >> 16) & 0xFF))
        auBuffer.append(UInt8((len >> 8) & 0xFF))
        auBuffer.append(UInt8(len & 0xFF))
        auBuffer.append(nalBody)
    }

    /// Audit fix #2: order-independent parameter-set ready check. Dřív se čekalo jen
    /// v PPS case — když kamera poslala SPS před VPS, configure() se nezavolal nikdy.
    /// Teď po každém PS NALu zkusíme: pokud mám všechny tři a kombinace se liší od
    /// currentVPS/SPS/PPS, rekonfigurujeme (nebo bootstrap když session == nil).
    private func tryConfigureIfReady() {
        guard let v = pendingStreamVPS,
              let s = pendingStreamSPS,
              let p = pendingStreamPPS else { return }
        let needsConfig = session == nil || v != currentVPS || s != currentSPS || p != currentPPS
        guard needsConfig else { return }
        FileHandle.safeStderrWrite(
            "[H265Decoder] \(session == nil ? "bootstrap" : "reconfig") PS vps=\(v.count) sps=\(s.count) pps=\(p.count)\n"
                .data(using: .utf8)!)
        _ = configure(vps: v, sps: s, pps: p)
    }

    /// Signál konce access unit (volá NativeCameraSource po RTP marker bit nebo při
    /// změně RTP timestamp). Flush → dekóduje aktuální auBuffer jako jeden sample.
    func flushAU() {
        let signpost = SPZSignposts.signposter.beginInterval(SPZSignposts.Name.h265Decode)
        defer { SPZSignposts.signposter.endInterval(SPZSignposts.Name.h265Decode, signpost) }
        guard !auBuffer.isEmpty else { return }
        guard let session = session, let fd = formatDescription else {
            auBuffer.removeAll(keepingCapacity: true)
            auIsKeyframe = false
            return
        }

        let auData = auBuffer
        let isKeyframe = auIsKeyframe
        let pts = auStartHostTime
        auBuffer.removeAll(keepingCapacity: true)
        auIsKeyframe = false
        // Audit fix #1: reset PTS na .invalid po flushi — příští addNAL nastaví nové PTS
        // z host clocku na prvním NALu další AU (bez ohledu na typ).
        auStartHostTime = .invalid

        // Dump first AU k /tmp pro external validaci (jen once)
        if !didDumpFirstAU && isKeyframe {
            didDumpFirstAU = true
            dumpAUToDisk(auData: auData)
        }

        // Audit note #8: intentional single memcpy. Swift Data nemá stabilní pointer napříč
        // async boundaries (VTDecompressionSessionDecodeFrame může retain CMBlockBuffer déle
        // než scope withUnsafeBytes). Alternativa (zero-copy přes CMBlockBufferCustomBlockSource
        // s retained Data boxem) by vyžadovala stejnou kopii do stable ContiguousArray,
        // takže netto žádný benefit. Na 4 Mbps × 15 fps × 2 kamery = ~1.5 MB/s, M4 memcpy ~100 GB/s
        // — benchmarkovaný overhead <0.01 % CPU.
        // malloc + memcpy — CMBlockBuffer si ponechá ownership a free-ne přes kCFAllocatorMalloc.
        let auLen = auData.count
        guard let mem = malloc(auLen) else { return }
        auData.withUnsafeBytes { src in
            if let base = src.baseAddress { memcpy(mem, base, auLen) }
        }
        var blockBuffer: CMBlockBuffer? = nil
        let bbStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: mem,
            blockLength: auLen,
            blockAllocator: kCFAllocatorMalloc,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: auLen,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard bbStatus == kCMBlockBufferNoErr, let bb = blockBuffer else {
            free(mem); return
        }

        var sampleBuffer: CMSampleBuffer? = nil
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleSize = auLen
        let sbStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            formatDescription: fd,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sb = sampleBuffer else { return }

        // Sample attachments — kritické pro správnou práci VT dekodéru.
        // NotSync: false = sync point (IDR/CRA), true = delta frame.
        // DependsOnOthers: false = nezávislý (IDR), true = reference dependent (P/B).
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [[CFString: Any]],
           !attachments.isEmpty {
            let mut = NSMutableArray(array: attachments)
            if let dict = mut[0] as? NSMutableDictionary {
                dict[kCMSampleAttachmentKey_NotSync] = !isKeyframe
                dict[kCMSampleAttachmentKey_DependsOnOthers] = !isKeyframe
            }
        }

        // Audit fix #4: atomic counter increment. Read-modify-write pod zámkem.
        let flushCount = auFlushedLock.withLock { count -> Int in
            count &+= 1
            return count
        }
        if flushCount <= 10 || flushCount % 30 == 0 {
            FileHandle.safeStderrWrite(
                "[H265Decoder] flush AU #\(flushCount) size=\(auLen) keyframe=\(isKeyframe)\n".data(using: .utf8)!)
        }

        var flagsOut: VTDecodeInfoFlags = []
        let decStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sb,
            flags: [],
            frameRefcon: nil,
            infoFlagsOut: &flagsOut
        )
        if decStatus != noErr && flushCount <= 10 {
            FileHandle.safeStderrWrite(
                "[H265Decoder] DecodeFrame AU #\(flushCount) status=\(decStatus)\n".data(using: .utf8)!)
        }
    }

    // MARK: - Output callback

    private static let decompressionCallback: VTDecompressionOutputCallback = {
        (refCon, _, status, _, imageBuffer, pts, _) in
        if status != noErr {
            FileHandle.safeStderrWrite("[H265Decoder] decode status=\(status)\n".data(using: .utf8)!)
            return
        }
        guard let imageBuffer = imageBuffer, let refCon = refCon else { return }
        let decoder = Unmanaged<H265Decoder>.fromOpaque(refCon).takeUnretainedValue()
        // Audit fix #4: atomic counter increment (callback běží na VT thread).
        let n = decoder.framesDecodedLock.withLock { count -> Int in
            count &+= 1
            return count
        }
        if n <= 5 || n % 30 == 0 {
            let w = CVPixelBufferGetWidth(imageBuffer)
            let h = CVPixelBufferGetHeight(imageBuffer)
            FileHandle.safeStderrWrite(
                "[H265Decoder] decoded #\(n) (\(w)×\(h))\n".data(using: .utf8)!)
        }
        decoder.onDecodedFrame?(imageBuffer, pts)
    }

    func invalidate() {
        // Audit fix #7: odstraněné `VTDecompressionSessionWaitForAsynchronousFrames`.
        // Výzva blokuje caller dokud všechny async callbacky nedoběhnou. Pokud callback
        // (line 311) držel MainActor reference přes Task@MainActor hop a současný caller
        // invalidate()-uje z MainActor hopu (připadně z CameraService.disconnect()),
        // vznikal klasický A↔B deadlock. `VTDecompressionSessionInvalidate` sám rozruší
        // session — callbacky co přijdou potom dostanou error (status != noErr) a my je
        // ignorujeme (guard v decompressionCallback).
        if let s = session {
            VTDecompressionSessionInvalidate(s)
        }
        session = nil
        formatDescription = nil
    }

    // MARK: - Diagnostics: dump AU to disk for external ffmpeg decode test

    private func dumpAUToDisk(auData: Data) {
        // Build combined VPS+SPS+PPS+AU as Annex-B bytestream. External tool
        // (ffmpeg) can then try to decode to verify our bytes are well-formed HEVC.
        var stream = Data()
        func appendAnnexB(_ nal: Data) {
            stream.append(contentsOf: [0, 0, 0, 1])
            stream.append(nal)
        }
        if let v = currentVPS { appendAnnexB(v) }
        if let s = currentSPS { appendAnnexB(s) }
        if let p = currentPPS { appendAnnexB(p) }
        // Convert AVCC AU back to Annex-B (strip 4B length, prepend startcode per NAL)
        var idx = 0
        while idx + 4 <= auData.count {
            let n0 = UInt32(auData[idx])
            let n1 = UInt32(auData[idx + 1])
            let n2 = UInt32(auData[idx + 2])
            let n3 = UInt32(auData[idx + 3])
            let nalLen = Int((n0 << 24) | (n1 << 16) | (n2 << 8) | n3)
            idx += 4
            guard idx + nalLen <= auData.count else { break }
            let nal = auData.subdata(in: idx..<(idx + nalLen))
            appendAnnexB(nal)
            idx += nalLen
        }
        let path = "/tmp/spz-first-au.hevc"
        try? stream.write(to: URL(fileURLWithPath: path))
        FileHandle.safeStderrWrite(
            "[H265Decoder] dumped first AU (\(stream.count) B) → \(path) for external validation\n"
                .data(using: .utf8)!)
    }
}
