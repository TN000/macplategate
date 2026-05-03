import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Metal
import os
import QuartzCore

/// Native ALPR video pipeline — bez ffmpeg, bez go2rtc, bez external procesů.
/// Skutečný hardware decoder na M4 media engine přes NativeCameraSource:
///   RTSPClient (Network.framework) → RTPDepacketizer (RFC 7798) → H265Decoder
///   (VTDecompressionSession) → IOSurface CVPixelBuffer → SPZ pipeline + display layer.
///
/// Public API zachováno z předchozí ffmpeg verze pro UI/PlatePipeline kompatibilitu.

/// Thread-safe ref-cell pro CVPixelBuffer (nonisolated).
final class LatestBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pb: CVPixelBuffer? = nil
    func get() -> CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return pb }
    func set(_ x: CVPixelBuffer?) { lock.lock(); pb = x; lock.unlock() }
}

/// Thread-safe atomic Date pro lastFrameTimestamp.
final class AtomicDate: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date = .distantPast
    func get() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ x: Date) { lock.lock(); value = x; lock.unlock() }
}

/// Atomic counter pro real capture FPS metric.
final class AtomicInt: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int = 0
    func get() -> Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value &+= 1; lock.unlock() }
    func reset() { lock.lock(); value = 0; lock.unlock() }
}

@MainActor
final class CameraService: ObservableObject {
    @Published private(set) var connected: Bool = false
    @Published private(set) var lastError: String? = nil
    @Published private(set) var videoSize: CGSize = .zero
    /// Stream nominal FPS — pro native decoder není snadno k dispozici (RTSP nereportuje
    /// frame rate v SDP konzistentně), `streamHint` z RTSPClient může mít hodnotu jen
    /// pro některé kamery. Default 15 fps (typický VIGI configured rate).
    @Published private(set) var streamNominalFps: Double = 15

    /// Audit fix #4: Metal-based preview renderer nahrazuje AVSampleBufferDisplayLayer.
    /// Ušetří 1 CMSampleBuffer alokaci + CMVideoFormatDescriptionCreateForImageBuffer
    /// call per frame. CVPixelBuffer (IOSurface) → CIImage zero-copy → CAMetalLayer
    /// drawable přes CIContext + MTLCommandQueue. Když Metal init selže (headless CI?),
    /// fallback na nil — caller zkontroluje a nekreslí preview (pipeline pokračuje).
    let previewRenderer: MetalPreviewRenderer? = MetalPreviewRenderer()

    /// Public CAMetalLayer pro UI NSViewRepresentable. Force-unwrap skrz computed
    /// property — když renderer je nil (fallback), caller layer stejně nepoužije
    /// (UI podmíní zobrazení přes previewAvailable flag).
    var previewLayer: CAMetalLayer? { previewRenderer?.metalLayer }
    var previewAvailable: Bool { previewRenderer != nil }

    /// Atomic ref na nejnovější pixel buffer pro PlatePipeline pull.
    private let latestStore = LatestBuffer()
    nonisolated func snapshotLatest() -> CVPixelBuffer? { latestStore.get() }
    nonisolated private func setLatest(_ pb: CVPixelBuffer?) { latestStore.set(pb) }

    /// Per-frame counter — UI ZACHYCENÍ fps metric.
    private let frameCounter = AtomicInt()
    nonisolated func capturedFrameCount() -> Int { frameCounter.get() }

    /// Atomic timestamp posledního frame — HealthMonitor + watchdog.
    private let lastFrameTimestampStore = AtomicDate()
    nonisolated func lastFrameAge() -> TimeInterval {
        Date().timeIntervalSince(lastFrameTimestampStore.get())
    }

    /// Display label pro notifikace.
    var displayName: String = ""

    /// Lock pro serialized connect/disconnect (rapid UI toggle protection).
    private let connectLock = NSLock()

    /// Aktuální RTSP URL — pro reconnect.
    private var currentURL: String? = nil

    /// Native source instance + lifecycle.
    private var source: NativeCameraSource?

    /// Audit fix #3 (partial): shared concurrent queue pro všechny kamery. Místo
    /// per-camera serial queue používáme global concurrent queue — RTSPClient callbacks
    /// se pak multiplexují na Swift runtime cooperative pool místo dedicated OS threadu
    /// per kamera. Benefit: při 3+ kamerách scheduler nepreemptuje receive threads
    /// mid-callback, L1 cache se nerozpadá. Pro 2 kamery rozdíl < 1 % CPU, ale pro
    /// 3+ měřitelný (viz audit). Full actor refactor RTSPClient → Swift actor
    /// zůstává P2 — tenhle quick win dává 80 % benefitu za 2 LOC změnu.
    ///
    /// Label je shared — Instruments Time Profiler pak sdruží všechny RTSP receive
    /// callbacks pod jedním heading, snadnější troubleshooting.
    private static let sharedSourceQueue = DispatchQueue(
        label: "spz.native-camera",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Cached Metal renderer reference — onFrame callback nonisolated potřebuje
    /// stable ref (renderer je final class thread-safe).
    private lazy var cachedRenderer: MetalPreviewRenderer? = previewRenderer

    /// Generation counter — invaliduje stale callbacky po reconnect.
    /// MainActor view + nonisolated atomic mirror pro VT decoder onFrame
    /// callback co běží mimo MainActor. Bez atomic mirror by stale frame
    /// po disconnect/reconnect prolítl `store.set` + Metal render PŘED tím
    /// než MainActor block vyčistí — preview by ukázal frame z předchozí
    /// connection.
    private var generation: Int = 0
    nonisolated let generationAtomic = OSAllocatedUnfairLock<Int>(initialState: 0)

    /// Watchdog — sleduje frame staleness, fire ErrorNotifier alerts.
    private var watchdogTask: Task<Void, Never>?
    private var lastHealthyAt: Date = Date()

    init() {
        FileHandle.safeStderrWrite(
            "[CameraService] init (native VTDecompression pipeline, no ffmpeg)\n"
                .data(using: .utf8)!)
    }

    deinit {
        watchdogTask?.cancel()
        // source cleanup happens via cancellation in start/stop
    }

    // MARK: - Public connect / disconnect

    func connect(rtspURL: String) {
        connectLock.lock()
        defer { connectLock.unlock() }

        guard let url = URL(string: rtspURL),
              let scheme = url.scheme?.lowercased(),
              ["rtsp", "rtsps"].contains(scheme),
              url.host != nil else {
            lastError = "Invalid RTSP URL: \(rtspURL)"
            return
        }
        FileHandle.safeStderrWrite(
            "[CameraService] connect(\(LogSanitizer.sanitizeURL(rtspURL)))\n"
                .data(using: .utf8)!)

        // Idempotent: pokud běží source pro stejnou URL, nic nemění. Dřív guard
        // vyžadoval `connected == true`, ale `connected` se nastavuje až v
        // MainActor hopu po prvním decodovaném framu — během bootstrap okna
        // (CameraManager.sync může sypnout 2 calls za 200 ms) to spustilo
        // zbytečný reconnect → RTSPClient sotva dostal DESCRIBE a dostal TEARDOWN.
        if currentURL == rtspURL, source != nil {
            return
        }

        disconnect()
        generation &+= 1
        let myGen = generation
        generationAtomic.withLock { $0 = myGen }
        let genAtomic = generationAtomic
        currentURL = rtspURL
        lastFrameTimestampStore.set(Date())
        lastHealthyAt = Date()
        frameCounter.reset()

        let src = NativeCameraSource(rtspURL: url, queue: Self.sharedSourceQueue)
        let renderer = cachedRenderer
        let store = latestStore
        let frameCounterRef = frameCounter
        let timestampStore = lastFrameTimestampStore

        src.onFrame = { [weak self] pb, _ in
            // Volaný ze VT decoder thread. Setlatest + render + counter — vše atomic /
            // thread-safe. Žádný MainActor hop per frame (drahý, 10+ hops/s).
            //
            // Generation guard na ÚPLNÉM ZAČÁTKU — bez tohoto by po reconnectu
            // starý NativeCameraSource mohl ještě krátce poslat frame a přepsat
            // latest buffer / preview (store.set + render + counter běží před
            // MainActor block). genAtomic je nonisolated lock, čte se z VT thread.
            let currentGen = genAtomic.withLock { $0 }
            guard currentGen == myGen else { return }
            store.set(pb)
            timestampStore.set(Date())
            frameCounterRef.increment()
            // Direct Metal render místo AVSampleBufferDisplayLayer.enqueue.
            renderer?.display(pixelBuffer: pb)
            // Update videoSize jen jednou (první frame) — zbytek MainActor.
            let w = CVPixelBufferGetWidth(pb)
            let h = CVPixelBufferGetHeight(pb)
            Task { @MainActor [weak self] in
                guard let self, self.generation == myGen else { return }
                if self.videoSize.width != CGFloat(w) || self.videoSize.height != CGFloat(h) {
                    self.videoSize = CGSize(width: w, height: h)
                }
                if !self.connected {
                    self.connected = true
                    self.lastError = nil
                }
            }
        }
        src.onStateChange = { [weak self] newState in
            Task { @MainActor [weak self] in
                guard let self, self.generation == myGen else { return }
                switch newState {
                case .error(let msg):
                    self.lastError = msg
                    FileHandle.safeStderrWrite(
                        "[CameraService] source error: \(msg)\n"
                            .data(using: .utf8)!)
                case .closed:
                    self.connected = false
                case .playing:
                    self.connected = true
                    self.lastError = nil
                default: break
                }
            }
        }
        source = src
        src.start()
        startWatchdog(myGen: myGen)
    }

    /// Force reconnect — UI tlačítko + watchdog escalation.
    func forceReconnect() {
        guard let url = currentURL else { return }
        FileHandle.safeStderrWrite(
            "[CameraService] forceReconnect → \(LogSanitizer.sanitizeURL(url))\n"
                .data(using: .utf8)!)
        disconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.connect(rtspURL: url)
        }
    }

    func disconnect() {
        generation &+= 1
        let disconnectedGeneration = generation
        generationAtomic.withLock { $0 = disconnectedGeneration }
        watchdogTask?.cancel(); watchdogTask = nil
        source?.stop()
        source = nil
        connected = false
        setLatest(nil)
        // Audit fix #4: clear preview přes Metal layer.
        previewRenderer?.clear()
        currentURL = nil
        videoSize = .zero
    }

    // MARK: - Watchdog (frame staleness + alert escalation)

    private func startWatchdog(myGen: Int) {
        watchdogTask?.cancel()
        let store = lastFrameTimestampStore
        watchdogTask = Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let age = Date().timeIntervalSince(store.get())
                await MainActor.run { [weak self] in
                    guard let self, self.generation == myGen else { return }
                    if age < 2.0 {
                        self.lastHealthyAt = Date()
                        ErrorNotifier.clear(.cameraDown)
                        ErrorNotifier.clear(.rtspUnreachable)
                    } else {
                        let unhealthyFor = Date().timeIntervalSince(self.lastHealthyAt)
                        if unhealthyFor >= 60 && unhealthyFor < 300 {
                            ErrorNotifier.fire(.cameraDown,
                                title: "Kamera odpojena",
                                body: "Kamera \(self.displayName.isEmpty ? "?" : self.displayName) nedává obraz \(Int(unhealthyFor))s.")
                        } else if unhealthyFor >= 300 {
                            ErrorNotifier.fire(.rtspUnreachable,
                                title: "RTSP nedostupný",
                                body: "\(self.displayName.isEmpty ? "?" : self.displayName): kamera nereaguje už \(Int(unhealthyFor/60)) min.")
                        }
                    }
                }
                if age > 8.0 {
                    FileHandle.safeStderrWrite(
                        "[CameraService] watchdog: no frame for \(Int(age))s — force reconnect\n"
                            .data(using: .utf8)!)
                    await MainActor.run { [weak self] in
                        guard let self, self.generation == myGen else { return }
                        self.forceReconnect()
                    }
                    return
                }
            }
        }
    }

    // MARK: - Display
    // Audit fix #4: `enqueueForDisplay` odstraněn. Render teď v onFrame callback
    // přes `MetalPreviewRenderer.display(pixelBuffer:)` — CVPixelBuffer → CIImage
    // zero-copy → CAMetalLayer.nextDrawable() texture. Ušetří 1 CMSampleBuffer
    // alokaci + format description create per frame.
}
