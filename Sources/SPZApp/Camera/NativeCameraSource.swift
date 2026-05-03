import Foundation
import CoreVideo
import CoreMedia

/// Native ALPR video pipeline bez ffmpeg / go2rtc — všechno přes Apple frameworks.
/// Drží `RTSPClient` (Network.framework), `RTPDepacketizer` (RFC 7798 H265),
/// `H265Decoder` (VideoToolbox HW decoder). Vytváří IOSurface-backed
/// CVPixelBuffer (NV12) přímo na M4 media engine — žádné memcpy mezi kapacitami.
///
/// Volá `onFrame(pb, presentationTime)` pro každý dekódovaný frame. Caller (CameraService)
/// předá pb dál na display layer + pipeline tick.
///
/// Reconnect: pokud RTSPClient přejde do .error nebo .closed, automaticky čeká 1.5 s
/// a znovu connect. Žádný external proces, žádný launchd dependency.
/// `@unchecked Sendable`: vnitřní stav (`rtspClient`, `reconnectTask`, `stopped`) je
/// manipulovaný výhradně přes svůj `queue` DispatchQueue, takže je de facto serializovaný.
final class NativeCameraSource: @unchecked Sendable {
    let rtspURL: URL
    private let queue: DispatchQueue
    private let depacketizer = RTPDepacketizer()
    private let decoder = H265Decoder()
    private var rtspClient: RTSPClient?

    /// Task místo DispatchWorkItem pro reconnect — lightweight (~200 B vs ~16 KB
    /// OS thread stack), cancellation je explicit přes Task.isCancelled check.
    private var reconnectTask: Task<Void, Never>?
    private var stopped = false

    /// Callback ze VT thread po dekódování frame. Caller je odpovědný za thread hop.
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    /// Lifecycle / error reporting do CameraService.
    var onStateChange: ((RTSPClient.State) -> Void)?

    init(rtspURL: URL, queue targetQueue: DispatchQueue) {
        self.rtspURL = rtspURL
        // Per-source serial queue with the shared camera queue as target.
        // The target keeps RTSP work on the common QoS/pool, while this serial
        // queue preserves the class invariant that `stopped`, `rtspClient`,
        // depacketizer and decoder are never touched concurrently.
        self.queue = DispatchQueue(
            label: "spz.native-camera.source.\(UUID().uuidString)",
            qos: .userInitiated,
            target: targetQueue
        )

        decoder.onDecodedFrame = { [weak self] pb, pts in
            self?.onFrame?(pb, pts)
        }
    }

    /// Start kamery. Zaručeně dispatchuje work na `queue` aby se internal state
    /// (`stopped`, `rtspClient`, callbacks) nemodifikoval z volajícího threadu
    /// paralelně s reconnect/RTP callbacks běžícími na queue. Bez tohoto by start/stop
    /// z MainActor + state-change callback z RTSP queue generovalo race na `stopped`
    /// flag → potenciální use-after-disconnect.
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = false
            self.connectInternal()
        }
    }

    /// Stop. Async via queue — pokud caller potřebuje synchronní zánik (např.
    /// během CameraService.disconnect → re-connect), `queue.sync` z volajícího
    /// MainActor je bezpečné jen mimo connect path. Pro app shutdown stačí
    /// async — RTSPClient.disconnect je idempotent.
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.reconnectTask?.cancel()
            self.reconnectTask = nil
            self.rtspClient?.disconnect()
            self.rtspClient = nil
            self.depacketizer.reset()
            self.decoder.invalidate()
        }
    }

    private func connectInternal() {
        guard !stopped else { return }
        // Tear down předchozí instance pokud existovala.
        rtspClient?.disconnect()
        rtspClient = nil
        depacketizer.reset()

        let client: RTSPClient
        do {
            client = try RTSPClient(url: rtspURL, queue: queue)
        } catch {
            FileHandle.safeStderrWrite("[NativeCamera] RTSPClient init failed: \(error)\n".data(using: .utf8)!)
            scheduleReconnect()
            return
        }
        client.onSDPReceived = { [weak self] sdp in
            guard let self = self else { return }
            // Konfiguruj H265 decoder z VPS/SPS/PPS extracted v SDP. Pokud SDP
            // parameter sets neobsahoval, odložíme konfiguraci — H265Decoder
            // zachytí in-band VPS/SPS/PPS NALs z prvního IDR framu a
            // bootstrapne se sám.
            guard sdp.hasParameterSets else {
                FileHandle.safeStderrWrite(
                    "[NativeCamera] SDP bez parameter sets — in-band bootstrap z IDR\n"
                        .data(using: .utf8)!)
                return
            }
            let ok = self.decoder.configure(vps: sdp.vps, sps: sdp.sps, pps: sdp.pps)
            if !ok {
                FileHandle.safeStderrWrite("[NativeCamera] decoder configure failed\n".data(using: .utf8)!)
            }
        }
        client.onRTPPacket = { [weak self] rtpPacket in
            guard let self = self else { return }
            // Depack → Annex-B NALs + AU end marker → buffer do decoderu.
            // HEVC multi-slice picture = všechny VCL slices jednoho frame MUSÍ být
            // v JEDNOM CMSampleBuffer. RTP marker bit (M=1) signalizuje end of AU;
            // tehdy flush akumulovaný buffer a spustí VTDecompressionSessionDecodeFrame.
            let result = self.depacketizer.process(rtpPacket: rtpPacket)
            for nal in result.nals {
                self.decoder.addNAL(annexBNAL: nal)
            }
            if result.isAUEnd {
                self.decoder.flushAU()
            }
        }
        client.onStateChange = { [weak self] newState in
            guard let self = self else { return }
            self.onStateChange?(newState)
            switch newState {
            case .error, .closed:
                if !self.stopped {
                    self.scheduleReconnect()
                }
            default:
                break
            }
        }
        rtspClient = client
        client.connect()
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        reconnectTask?.cancel()
        // Task detached aby nepretekly actor isolation constraints; queue.async pro
        // navrat na source queue (connectInternal je closure-based, ne actor method).
        reconnectTask = Task.detached { [weak self, queue] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self = self else { return }
            queue.async { [weak self] in
                self?.connectInternal()
            }
        }
    }
}
