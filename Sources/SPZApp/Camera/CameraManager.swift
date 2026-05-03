import Foundation
import Combine
import SwiftUI

/// Spravuje N kamer paralelně — každá má svou CameraService (native RTSP +
/// VTDecompressionSession pipeline) + PlatePipeline (tracker / commit).
@MainActor
final class CameraManager: ObservableObject {
    @Published private(set) var services: [String: CameraService] = [:]
    @Published private(set) var pipelines: [String: PlatePipeline] = [:]
    /// Aggregate — true pokud ALESPOŇ JEDNA kamera je connected. Používá ho
    /// StatusBadge v header baru. Udržuje se přes Combine sink na `$connected`
    /// každé CameraService.
    @Published private(set) var anyConnected: Bool = false

    /// Per-camera Combine subscription. Indexováno jménem kamery, aby bylo možné
    /// cancelovat tu konkrétní při removal (jinak by sink držel ref na publisher
    /// a CameraService nikdy nebyla dealokovaná).
    private var connectionCancellables: [String: AnyCancellable] = [:]
    private weak var state: AppState?

    /// Per-camera last-applied URL — distinguishing URL change od settings tweak
    /// (label, ROI, FPS). URL change = reconnect + tracker reset; settings tweak
    /// → updatePollFps + tracker zachován (jinak by každá Settings save resetla
    /// tracker uprostřed detekce).
    private var lastAppliedURL: [String: String] = [:]

    /// ResourceBudget evaluace timer. 5 s interval, pipeline-only restart na
    /// mode change (NIKDY svc.connect() — RTSP DESCRIBE/SETUP/PLAY churn by
    /// adaptive throttling spamovala kamera). Cleanup v `stopAll()` aby
    /// LaunchAgent restart cyklus nevyrobil duplicate timery.
    private var budgetTimer: Timer?

    /// Cached effective FPS per camera. Pokud mode change → spočítá novou FPS,
    /// ale restartne pipeline JEN pokud effective FPS skutečně se liší (plus
    /// epsilon 0.1). Eliminuje zbytečný tracker reset při normal↔warm flicker
    /// kde base FPS clamp dá stejnou hodnotu (např. base=2 + multiplier 0.7
    /// → 2 fps obě modes díky `max(2, …)` floor).
    private var lastAppliedFps: [String: Double] = [:]

    // MARK: - Idle režim (per-camera tracking pro UI)
    /// Kamery aktuálně v idle režimu. Publikováno pro UI (indikátor).
    /// Logika samotná (throttle OCR) je v PlatePipeline — native decoder běží
    /// nezávisle, stream se neresetuje při přechodech idle/active.
    @Published private(set) var idleActiveCameras: Set<String> = []

    /// Bind na AppState — voláno jednou z UI po initu.
    /// Zároveň předá reference do WebServer.shared aby webUI mohlo bez race
    /// fire manual open-gate snapshot i když server startnul před tím než
    /// StreamView dostal `.onAppear` (autostart path: loadSettings → webUIEnabled
    /// didSet → start() PŘED tím než UI stackne environmentObjects).
    func bind(state: AppState) {
        self.state = state
        WebServer.shared.bindCameras(self)
    }

    /// Voláno PlatePipeline při VALIDNÍ plate detekci (po format filtrech).
    /// Resetuje idle timer; pokud byla kamera v idle, exit.
    func markActivity(for cameraName: String) {
        state?.markVisionActivity(for: cameraName)
        if idleActiveCameras.remove(cameraName) != nil {
            FileHandle.safeStderrWrite("[Idle] \(cameraName) → exit (valid plate)\n".data(using: .utf8)!)
        }
    }

    /// Voláno PlatePipeline když detekuje že jsme prošli idle threshold.
    func markIdle(for cameraName: String, reason: String) {
        if !idleActiveCameras.contains(cameraName) {
            idleActiveCameras.insert(cameraName)
            FileHandle.safeStderrWrite("[Idle] \(cameraName) → enter (\(reason))\n".data(using: .utf8)!)
        }
    }

    /// Voláno PlatePipeline když idle exituje bez validní plate (user vypnul
    /// úsporný režim nebo threshold změněn). Oddělené od markActivity aby
    /// nevyvolávalo confusing log o „valid plate".
    func exitIdlePublication(for cameraName: String) {
        if idleActiveCameras.remove(cameraName) != nil {
            FileHandle.safeStderrWrite("[Idle] \(cameraName) → exit (mode disabled / threshold)\n".data(using: .utf8)!)
        }
    }

    /// Aktualizuje runtime set kamer dle konfigurace. Volá se při startu appky
    /// a při změnách `AppState.cameras` (add/remove/rename) nebo `CameraConfig.enabled`.
    func sync(cameras: [CameraConfig]) {
        guard let state else { return }
        let activeNames = Set(cameras.filter { $0.enabled }.map { $0.name })
        ResourceBudget.shared.setActiveCameras(activeNames.count)
        if !activeNames.isEmpty { startBudgetMonitoring() } else { stopBudgetMonitoring() }

        // Disable zmizevší / toggled-off kamery
        for name in Array(services.keys) where !activeNames.contains(name) {
            services[name]?.disconnect()
            pipelines[name]?.stop()
            services.removeValue(forKey: name)
            lastAppliedURL.removeValue(forKey: name)
            lastAppliedFps.removeValue(forKey: name)
            pipelines.removeValue(forKey: name)
            // Drop Combine subscription pro tuto kameru — jinak by sink held ref
            // na CameraService a ten by nikdy nebyl dealokovaný (VT decompression
            // session + RTSP connection by leakly per remove/add cyklus).
            connectionCancellables.removeValue(forKey: name)
        }

        // Start new / update URL pokud se změnil
        for cam in cameras where cam.enabled {
            if let existing = services[cam.name] {
                // Distinguish URL change od settings tweak (label, ROI, FPS).
                // URL change → connect + tracker reset (nový stream, stará detekce
                // nesouvisí). Same URL → updatePollFps a zachovej tracker.
                let prevURL = lastAppliedURL[cam.name]
                lastAppliedURL[cam.name] = cam.rtspURL
                existing.connect(rtspURL: cam.rtspURL)  // idempotent při same URL
                if prevURL != cam.rtspURL {
                    // Skutečná URL změna → fresh tracker via start(fps:).
                    onStreamNominalFpsChanged(for: cam.name, resetPipeline: true)
                } else if let pipe = pipelines[cam.name] {
                    // Same URL, jen settings tweak. Update FPS bez resetu trackeru.
                    let fps = state.effectiveDetectionFps(
                        streamNominalFps: existing.streamNominalFps,
                        measuredCaptureFps: state.pipelineStats.captureFps
                    )
                    lastAppliedFps[cam.name] = fps
                    pipe.updatePollFps(fps)
                }
            } else {
                let svc = CameraService()
                svc.displayName = cam.label.isEmpty ? cam.name : cam.label
                let pipe = PlatePipeline()
                pipe.bind(state: state, camera: svc, cameraName: cam.name)
                pipe.cameraManager = self  // pro idle watcher signál
                services[cam.name] = svc
                pipelines[cam.name] = pipe
                // Subscribe na $connected ať header status badge reaguje.
                // Per-camera storage (ne Set) aby šlo cancel při removal.
                connectionCancellables[cam.name] = svc.$connected
                    .receive(on: RunLoop.main)
                    .sink { [weak self] _ in self?.refreshAggregate() }
                svc.connect(rtspURL: cam.rtspURL)
                // Start PlatePipeline hned po connect. Native decoder streamNominalFps
                // neemituje (nemá stderr parse), takže musíme pipeline startnout hned;
                // jinak UI metriky ZACHYCENÍ/DETEKCE/VÝPOČET zůstaly na 0.
                let initialFps = state.effectiveDetectionFps(
                    streamNominalFps: svc.streamNominalFps,
                    measuredCaptureFps: state.pipelineStats.captureFps
                )
                lastAppliedFps[cam.name] = initialFps
                pipe.start(fps: initialFps)

                // VIGI C250 ONVIF event subscription nefunguje (firmware vrací
                // `400 ter:InvalidArgVal` na všechny variants). Vehicle attribute
                // data zůstává uvnitř VIGI VMS app, není externally consumable.
                // Pivot: VehicleClassifier.swift (Core ML + VNClassifyImage)
                // produkuje color + type lokálně z video frame.
                _ = cam  // reserved pro budoucí C485/C540V upgrade
            }
        }
        refreshAggregate()
    }

    /// Debounce pro anyConnected = false transition. Zabraňuje "NEPŘIPOJENO"
    /// flashům v UI při krátkých reconnect cyklech (RTSP connecting → playing
    /// trvá ~200 ms, ale v mezičase anyConnected briefly false).
    private var disconnectDebounceTask: Task<Void, Never>?
    private static let disconnectDebounceSec: TimeInterval = 2.0

    private func refreshAggregate() {
        let any = services.values.contains { $0.connected }
        if any {
            // Okamžitá transition na true — hned zrušit případný pending debounce.
            disconnectDebounceTask?.cancel()
            disconnectDebounceTask = nil
            if !anyConnected { anyConnected = true }
        } else {
            // Latency na false. Pokud během 2 s se connected obnoví, UI nebliká.
            guard disconnectDebounceTask == nil else { return }
            disconnectDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.disconnectDebounceSec * 1_000_000_000))
                guard let self = self, !Task.isCancelled else { return }
                let stillDown = !self.services.values.contains { $0.connected }
                if stillDown && self.anyConnected {
                    self.anyConnected = false
                }
                self.disconnectDebounceTask = nil
            }
        }
    }

    /// Reaguje na změnu nominal FPS konkrétní kamery. Běžná změna FPS mění jen
    /// poll cadence; tracker reset patří jen k fyzické změně streamu/URL.
    func onStreamNominalFpsChanged(for name: String, resetPipeline: Bool = false) {
        guard let state, let svc = services[name], let pipe = pipelines[name] else { return }
        let detectFps = state.effectiveDetectionFps(
            streamNominalFps: svc.streamNominalFps,
            measuredCaptureFps: state.pipelineStats.captureFps
        )
        lastAppliedFps[name] = detectFps
        if resetPipeline {
            pipe.start(fps: detectFps)
        } else {
            pipe.updatePollFps(detectFps)
        }
    }

    /// Upraví detection FPS bez resetu trackerů (user toggluje detect rate).
    func restartAllPipelines() {
        guard let state else { return }
        for (name, svc) in services {
            guard svc.connected else { continue }
            let fps = state.effectiveDetectionFps(
                streamNominalFps: svc.streamNominalFps,
                measuredCaptureFps: state.pipelineStats.captureFps
            )
            lastAppliedFps[name] = fps
            pipelines[name]?.updatePollFps(fps)
        }
    }

    /// Reconnectne všechny s aktuální capture FPS (user toggluje capture rate).
    /// Native pipeline ignoruje captureFps (dekóduje všechny framy), ale
    /// idempotent connect nic nerozbije a udrží API kompatibilitu s UI toggle.
    func applyCaptureRateAll() {
        guard let state else { return }
        for (name, svc) in services {
            guard let cam = state.cameras.first(where: { $0.name == name }), cam.enabled else { continue }
            svc.connect(rtspURL: cam.rtspURL)
        }
    }

    func service(for name: String) -> CameraService? { services[name] }
    func pipeline(for name: String) -> PlatePipeline? { pipelines[name] }

    /// Start budget evaluation timer. Idempotent — pokud už běží, no-op
    /// (zabraňuje duplicate timeru při LaunchAgent restart cyklu).
    func startBudgetMonitoring() {
        stopBudgetMonitoring()  // defensive — invalidate předchozí pokud existuje
        budgetTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluateBudgetMode() }
        }
    }

    func stopBudgetMonitoring() {
        budgetTimer?.invalidate()
        budgetTimer = nil
    }

    /// Po 5 s interval ResourceBudget classify mode → pokud changed, restart
    /// pipelines s novou base FPS — ale pouze pokud SKUTEČNĚ se efektivní FPS
    /// liší od posledně aplikované hodnoty. Při floor clamp (`max(2, …)`)
    /// může mode warm vs constrained dát stejnou výslednou FPS = bezvýznamný
    /// restart by jen reset trackeru bez benefit. NIKDY nereconnectne
    /// CameraService — to by způsobilo RTSP DESCRIBE/SETUP/PLAY churn.
    private func evaluateBudgetMode() {
        let (_, changed) = ResourceBudget.shared.evaluate()
        guard changed else { return }
        guard let state else { return }
        for (name, svc) in services {
            let fps = state.effectiveDetectionFps(
                streamNominalFps: svc.streamNominalFps,
                measuredCaptureFps: state.pipelineStats.captureFps
            )
            let last = lastAppliedFps[name] ?? -1
            if abs(fps - last) > 0.1 {
                lastAppliedFps[name] = fps
                // **DŮLEŽITÉ:** updatePollFps NE start(fps:) — start() volá
                // tracker.reset() + recentCommitTimes.removeAll() = zahodit
                // rozjeté tracky uprostřed průjezdu nebo umožnit duplicate
                // commit. Adaptive throttling musí měnit pouze poll cadence,
                // ne pipeline state.
                pipelines[name]?.updatePollFps(fps)
            }
        }
    }

    /// Clean shutdown — volá se z applicationWillTerminate (přes state).
    func stopAll() {
        stopBudgetMonitoring()
        for (_, svc) in services { svc.disconnect() }
        for (_, pipe) in pipelines { pipe.stop() }
        services.removeAll()
        pipelines.removeAll()
        connectionCancellables.removeAll()
        lastAppliedFps.removeAll()
        lastAppliedURL.removeAll()
    }
}
