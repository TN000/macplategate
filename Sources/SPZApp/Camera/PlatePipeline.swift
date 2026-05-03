import Foundation
import AppKit
import Combine
import CoreGraphics
import CoreImage

private final class SecondaryOCRMergeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [PlateOCRReading]?

    func store(_ newValue: [PlateOCRReading]) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }

    func load() -> [PlateOCRReading]? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

private final class CICacheClearCadence: @unchecked Sendable {
    private let lock = NSLock()
    private var counter: Int = 0
    private var lastClear: Date = Date()

    func shouldClear(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        counter &+= 1
        let byCount = counter % 60 == 0
        let byTime = now.timeIntervalSince(lastClear) >= 15.0
        if byCount || byTime {
            lastClear = now
            return true
        }
        return false
    }
}


/// Spojuje CameraService → snapshot → Vision OCR → tracker → AppState.
/// Spouští timer s detect_fps cadence, vytahuje snapshot z VLCVideoView,
/// spouští Vision na background queue, výsledky publikuje do AppState.
@MainActor
final class PlatePipeline: ObservableObject {
    private weak var state: AppState?
    private weak var camera: CameraService?
    /// Back-ref na CameraManager — pipeline signalizuje Vision activity do
    /// idle watcheru (markActivity). Nastaveno v configure() z CameraManager.
    weak var cameraManager: CameraManager?
    /// Timestamp poslední VALIDNÍ plate detekce (candidates po filtrech), ne
    /// raw Vision readings. Užívá se pro idle throttle gate.
    private var validActivityTs: Date = Date()
    /// Timestamp posledního OCR tiku přijatého ke zpracování. Idle throttle musí
    /// měřit od přijetí tiku, ne od konce Vision inference, jinak se cílové fps
    /// snižuje o dobu inference.
    private var lastProcessedAt: Date = .distantPast
    private var wasIdlePublished: Bool = false
    /// Pipeline ID = camera name ("vjezd" / "vyjezd"). Commits se označují TÍMTO
    /// jménem, ne `state.activeCameraName` — obě pipelines běží paralelně a
    /// musí identifikovat svou kameru bez ohledu na UI view.
    private var cameraName: String = ""
    private let tracker = IoUTracker()
    private static var sharedCIContext: CIContext { SharedCIContext.shared }
    private var frameIdx: Int = 0
    private var commitsTotal: Int = 0
    private var fpsWindowDetect: [Date] = []
    /// **Concurrent** worker pool pro Vision inference. `attributes: .concurrent`
    /// = GCD pustí paralelně až `ocrMaxConcurrent` workerů.
    ///
    /// Motivace: ANE má throughput ~15–20 inf/s, ale serial queue s `.accurate`
    /// requestem bloqovala queue kevent_id sleepem (~90% času) → efektivní
    /// throughput 7 fps. S 2-3 concurrent requests ANE se využívá naplno.
    /// Performance profile (sample 30s sled, před refactorem):
    ///   - spz.ocr queue 7183 samples: 90% kevent wait, 10% CPU
    ///   - ANE power 734 mW (10% kapacity)
    /// Po refactoru target: ~14–20 fps per camera, ANE ~40–60% power.
    private let processingQueue = DispatchQueue(
        label: "spz.ocr.pool", qos: .userInitiated, attributes: .concurrent)
    /// Limit concurrent Vision inferencí. ANE je single-engine, takže >1 concurrent
    /// per pipeline neškáluje (ANE interní queue beztak serializuje). Adaptive gate
    /// drží 1 nebo 2 podle p95 OCR latency (viz hysteresis konstanty níže).
    private static let ocrMaxConcurrentNormal: Int = 2
    private static let ocrMaxConcurrentConstrained: Int = 1
    /// Hysteresis: když jsme v `2 concurrent`, p95 musí přerušit ceiling-up
    /// abychom drop-ovali na 1. Když jsme v `1 concurrent`, p95 musí klesnout
    /// pod ceiling-down. Eliminuje flapping kolem boundary.
    private static let ocrConcurrencyCeilingUpMs: Double = 100   // 2→1 trigger
    private static let ocrConcurrencyCeilingDownMs: Double = 60  // 1→2 release
    /// Runtime-adjustable counting gate. Unlike DispatchSemaphore, this can safely
    /// change its max from 1↔2 without losing permits while workers are in flight.
    private let ocrGate = AdaptiveConcurrencyGate()
    private var currentOcrMaxConcurrent: Int = PlatePipeline.ocrMaxConcurrentConstrained

    /// Burst mode — max HW fps lift při jakémkoliv signálu (motion gate
    /// nebo Vision detect). Cíl: zachytit **co nejvíc readings** za co
    /// nejkratší čas → tracker buduje consensus přes 5–10 obs místo fast-single.
    ///
    /// Trigger zdroje (per priority):
    /// 1. Motion gate `motionDetected = true` → instant burst start (bez čekání na OCR)
    /// 2. tracker.update vrátí active/finalized/readings (already triggered above ale
    ///    extension on continuing activity)
    ///
    /// Target fps během burst = **max HW limit** (Vision .accurate ANE per-camera
    /// cap ~14 fps). Multiplier ignored — chceme max výkon, ne user multiplier.
    private var burstUntilTs: Date? = nil
    private static let burstHoldSec: TimeInterval = 4.0
    /// Vision .accurate ANE per-camera ceiling. Apple-level limit, vyšší fps
    /// dropuje v Vision request queue. 14 je empirically max stable na M4.
    private static let burstFpsTarget: Double = 14.0
    /// Cached target fps před burst (pro revert).
    private var burstBaselineFps: Double = 0
    private var lastPixelBuffer: CVPixelBuffer? = nil  // pro commit thumbnail
    private var pollTickCounter: Int = 0
    private var pollTimer: Timer?
    private var currentPollFps: Double = 0
    // Capture FPS — z reálných dekódovaných framů (přes CameraService.capturedFrameCount delty)
    private var lastCaptureCheck: (count: Int, ts: TimeInterval) = (0, 0)
    private var captureFpsEMA: Double = 0
    /// Recent commit ledger pro recommitDelay gate + Vrstva 5 qualifying-prior
    /// lookup. Pole místo dictionary — robustnější (žádné key collision při
    /// repeat commits stejné SPZ), explicit cameraName per entry pro multi-camera.
    /// Vrstvy 1-4 (existing dedup) iterují přes všechny entries v cutoff window.
    fileprivate struct RecentCommit {
        let plate: String
        let ts: Date
        let conf: Float
        let cameraName: String
    }
    private var recentCommits: [RecentCommit] = []

    /// **Vrstva 5: delayed drop pro weak fast-single + prior fragment.**
    /// Detekuje garbage misread duplicate (např. 1AB2978 1.7s po 1AB2345 consensus).
    /// Hold 1.5s, pak vždy drop. Žádný release path.
    fileprivate struct PendingDropCandidate {
        let bestText: String
        let bestConf: Float
        let registeredAt: Date
        let dropAfter: Date
        let cameraName: String
        let priorMatchPlate: String
        let priorMatchConf: Float
        let priorMatchAgeMs: Int
    }
    private var pendingDropCandidates: [PendingDropCandidate] = []

    /// Tunable constants (extracted pro test boundary cases).
    private let delayedDropRecentWindow: TimeInterval = 3.0
    private let delayedDropHoldDuration: TimeInterval = 1.5
    private let delayedDropHighConfThreshold: Float = 0.85
    private let delayedDropLowConfThreshold: Float = 0.75
    private let delayedDropMaxHits = 1
    private let delayedDropMaxObservations = 2
    /// Static-scene OCR cache — hash ROI pixel bufferu. Pokud je identický N framů
    /// po sobě, OCR je skipnuto (kromě každého 5. kontrolního framu). Motion-aware
    /// FPS: idle = ~1 fps detect, motion = plná 5 fps.
    private var lastROIHash: UInt64 = 0
    /// **Separate** hash pro motion-wake probe (aktualizován KAŽDOU pollTick).
    /// `lastROIHash` se aktualizuje jen v static-scene cache bloku (throttled),
    /// takže pro motion detection byl nespolehlivý.
    private var motionProbeLastHash: UInt64 = 0

    /// Bucket-level motion probe (per-sample bucket compare, nikoli hash avalanche).
    /// 12 buckets × 4-bit. Motion = pokud ≥ 3 buckets changed od last tick.
    private var motionProbeBuckets: [UInt8] = Array(repeating: 0, count: 12)
    /// Pre-allocated current-buckets buffer pro sampleBucketDiff(buckets:inout)
    /// — eliminuje per-tick alokaci 12 B array (10-20× tick/s × N pipelines).
    private var motionProbeCurrentBuckets: [UInt8] = Array(repeating: 0, count: 12)

    /// Tick counter pro noční pauzu — log line ~1× za 5 min v pauze.
    private var nightPausePollCounter: Int = 0
    private var motionProbeBucketsInitialized: Bool = false
    private var sameHashCount: Int = 0
    /// Motion-active no-commit diagnostic state. Když motion je kontinuálně
    /// detekovaná >5 s ale žádný commit se neobjevil, logneme 1× — indikátor
    /// že OCR úplně propadl (dirty plate, špatný úhel, glare). Loguje jen jednou
    /// per motion burst aby nespamoval.
    private var motionStartedAt: Date? = nil
    private var commitsAtMotionStart: Int = 0
    private var motionNoCommitLogged: Bool = false
    private var noMotionTickCount: Int = 0
    private static let idleHoldFrames: Int = 10  // 2 s @ 5 fps
    private static let idleSkipEvery: Int = 5    // idle: OCR každý 5. frame

    /// Lokální (CEST/CET) ISO8601 formatter pro stderr logy. `Store.sharedISO8601`
    /// zůstává UTC pro DB/snapshots/jsonl back-compat. Tady chceme `[Commit] ts=…`
    /// v lokálním čase aby se user nemusel mentálně konvertovat ±2h při čtení logu.
    nonisolated static func localTimestampString(from date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f.string(from: date)
    }

    /// Sdílený sekundární engine — jedna ORT session per process. ORT init je
    /// drahý (model load ~50 ms) a session je read-only `run`-callable; není
    /// důvod duplikovat per-pipeline. Engine contract je `Sendable`; vlastní
    /// circuit breaker dál serializuje `run` call per camera.
    nonisolated static let sharedSecondaryEngine: PlateRecognitionEngine? = FastPlateOCROnnxEngine()
    nonisolated private static let secondaryEngineTimeoutMs: Int = 60

    /// Per-pipeline circuit breaker (state per kamera). Failure isolation:
    /// timeout na vjezdu nezakáže sekundární engine na vyjezdu.
    /// Backward-compat alias `Self.secondaryEngine` zůstává pro API stabilitu —
    /// vrací sdílený engine, ne circuit.
    nonisolated static var secondaryEngine: PlateRecognitionEngine? { sharedSecondaryEngine }
    nonisolated let secondaryCircuit: SecondaryEngineCircuit = SecondaryEngineCircuit(
        engine: PlatePipeline.sharedSecondaryEngine
    )

    func bind(state: AppState, camera: CameraService, cameraName: String = "") {
        self.state = state
        self.camera = camera
        self.cameraName = cameraName
        tracker.reset()
    }

    /// Aktuální camera config pro TUTO pipeline (ne state.activeCamera, která
    /// tracks UI-zvolenou kameru; pipelines běží paralelně).
    private var myCamera: CameraConfig? {
        state?.cameras.first(where: { $0.name == cameraName })
    }

    func start(fps: Double) {
        stop()
        tracker.reset()  // Fresh start — žádné staré tracky z předchozího streamu
        burstUntilTs = nil
        burstBaselineFps = 0
        recentCommits.removeAll()
        pendingDropCandidates.removeAll()
        lastROIHash = 0
        motionProbeLastHash = 0
        for i in motionProbeBuckets.indices { motionProbeBuckets[i] = 0 }
        motionProbeBucketsInitialized = false
        sameHashCount = 0
        lastHandledFrameIdx = 0  // reset out-of-order guard
        slotsBusyStartTs = 0
        FileHandle.safeStderrWrite(
            "[PlatePipeline \(cameraName)] start(fps=\(fps))\n".data(using: .utf8)!)
        let effectiveFps = max(0.5, fps)
        currentPollFps = effectiveFps
        let interval = 1.0 / effectiveFps
        // Timer closure je @Sendable — skip-if-busy flag musí být nonisolated atomic,
        // aby ho mohl fire bez MainActor hopu. Task Main Actor fakticky drainuje serialized,
        // ale Sendable closure k MainActor-isolated property nesmí.
        let busyFlag = self.pollBusyFlag
        _ = busyFlag  // legacy, ponecháno kvůli binary compat s ostatními paths
        // Timer.scheduledTimer běží na main run loop (kde je main actor).
        // `MainActor.assumeIsolated` odstraní Task hop (~5–10 ms latency per
        // tick) který při 5 fps snižoval efektivní rate na ~4.7 fps.
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollAndProcess()
            }
        }
        // Tolerance — bez tohoto má Timer default ~10 % jitter pro power-savings,
        // což při 5 fps znamená 200 ms ±20 ms → efektivní rate 4.5 fps. Nastavíme
        // na 5 ms (2,5 % při 200 ms intervalu) = ztráta max 0.1 fps.
        timer.tolerance = min(0.005, interval * 0.025)
        pollTimer = timer
    }

    /// Adjust poll FPS BEZ resetu trackeru / commit cache / motion probe state.
    /// Volá CameraManager.evaluateBudgetMode() když ResourceBudget mode change
    /// dá novou base FPS. start(fps:) by tracker.reset() shodil rozjeté tracky
    /// uprostřed průjezdu → buď ztráta detekce, nebo (pokud auto stálo) duplicate
    /// commit po recentCommitTimes wipe.
    ///
    /// Behavior: invalidate stary timer + create nový s nový interval. Tracker
    /// state, recentCommitTimes, motion probe buffers — vše zachováno.
    func updatePollFps(_ newFps: Double) {
        guard pollTimer != nil else {
            start(fps: newFps)
            return
        }
        let effectiveFps = max(0.5, newFps)
        if burstUntilTs != nil, effectiveFps < Self.burstFpsTarget {
            burstBaselineFps = effectiveFps
            FileHandle.safeStderrWrite(
                "[PlatePipeline \(cameraName)] updatePollFps(fps=\(String(format: "%.1f", effectiveFps))) deferred until burst end\n"
                    .data(using: .utf8)!)
            return
        }
        let interval = 1.0 / effectiveFps
        pollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollAndProcess()
            }
        }
        timer.tolerance = min(0.005, interval * 0.025)
        pollTimer = timer
        currentPollFps = effectiveFps
        FileHandle.safeStderrWrite(
            "[PlatePipeline \(cameraName)] updatePollFps(fps=\(String(format: "%.1f", effectiveFps))) — tracker zachován\n"
                .data(using: .utf8)!)
    }

    /// Atomic bool — Timer closure fires na background threadu (Swift 6 Sendable),
    /// nesmí koukat na MainActor-isolated state. Atomic flag je safe z obou stran.
    private let pollBusyFlag = AtomicFlag()

    func stop() {
        pollTimer?.invalidate(); pollTimer = nil
    }

    nonisolated deinit {
        // Timer.invalidate() musí na main thread; capture jen RAII pattern
        Task { @MainActor [weak self] in
            self?.stop()
        }
    }

    private func pollAndProcess() {
        let signpost = SPZSignposts.signposter.beginInterval(SPZSignposts.Name.pipelineTick)
        defer { SPZSignposts.signposter.endInterval(SPZSignposts.Name.pipelineTick, signpost) }
        guard let camera else { return }

        // **Noční pauza:** během konfigurovaného window vypne OCR/tracker/commit
        // pipeline. RTSP stream + decoder + preview běží dál (žádný reconnect
        // overhead na konci pauzy). Use case: brána se mechanicky uzavře 23:00–05:00.
        // Periodic log 1× za ~5 min že jsme v pauze, jinak silent.
        if let s = state, s.isInNightPause() {
            nightPausePollCounter &+= 1
            // 1 log line per ~5 min při 10 fps poll = 3000 ticků; round up.
            if nightPausePollCounter % 3000 == 1 {
                FileHandle.safeStderrWrite(
                    "[PlatePipeline \(cameraName)] noční pauza aktivní (\(s.nightPauseStartHour):00–\(s.nightPauseEndHour):00) — OCR skip\n"
                        .data(using: .utf8)!)
            }
            return
        } else {
            nightPausePollCounter = 0
        }

        // Real capture FPS — delta capturedFrameCount za reálný čas mezi tiky
        let count = camera.capturedFrameCount()
        let now = ProcessInfo.processInfo.systemUptime
        if lastCaptureCheck.ts > 0, now - lastCaptureCheck.ts >= 0.5 {
            let dCount = count - lastCaptureCheck.count
            let dT = now - lastCaptureCheck.ts
            let inst = dT > 0 ? Double(dCount) / dT : 0
            captureFpsEMA = captureFpsEMA == 0 ? inst : captureFpsEMA * 0.6 + inst * 0.4
            state?.pipelineStats.captureFps = captureFpsEMA
            lastCaptureCheck = (count, now)
        } else if lastCaptureCheck.ts == 0 {
            lastCaptureCheck = (count, now)
        }
        // **Burst decay:** pokud byl burst aktivní a deadline uplynul, revert
        // na baseline fps. Per-tick aby revert bylo deterministicky < 1 burst
        // frame interval po expire.
        if let until = burstUntilTs, Date() >= until {
            burstUntilTs = nil
            let baseline = burstBaselineFps > 0 ? burstBaselineFps : (state?.detectionFpsManual ?? 3.0)
            updatePollFps(baseline)
            Audit.event("detection_burst_end", [
                "camera": cameraName,
                "fps": baseline
            ])
        }

        // Vrstva 5 lifecycle hook — každý poll tick check expired pending drops.
        // Zajišťuje, že hold se uvolní i když žádný další commit nepřijde.
        evaluatePendingDrops()

        // Periodic debug heartbeat — každých 5 s log captureFps + detectFps, aby šlo
        // snadno verify že pipeline tiká a UI metriky jsou propojené s AppState.
        pollTickCounter &+= 1
        if pollTickCounter % 50 == 0 {
            FileHandle.safeStderrWrite(
                "[PlatePipeline \(cameraName)] heartbeat captureFps=\(String(format: "%.1f", captureFpsEMA)) detectFps=\(String(format: "%.1f", state?.pipelineStats.detectFps ?? 0)) frames=\(count)\n"
                    .data(using: .utf8)!)
        }

        // ===== Úsporný režim =====
        // Když user zapnul idleModeEnabled a uplynulo > idleAfterSec bez VALIDNÍ
        // plate detekce, throttlneme OCR poll na 1 fps. Snapshot state v jedné
        // atomické kontextu — brání race když user během toggluje nastavení.
        let idleEnabled = state?.idleModeEnabled ?? false
        let idleThreshold = state?.idleAfterSec ?? 2.0
        let inIdle: Bool = {
            guard idleEnabled else { return false }
            return Date().timeIntervalSince(validActivityTs) > idleThreshold
        }()
        // Sync UI indikátor vždy na aktuální stav (ne jen při přechodu), aby se
        // stuck stav „idle" nemohl zaseknout ani když uživatel vypne mode.
        if inIdle != wasIdlePublished {
            wasIdlePublished = inIdle
            let name = cameraName
            let reason = "no valid plate for \(String(format: "%.1f", idleThreshold))s"
            Task { @MainActor [weak self] in
                if inIdle {
                    self?.cameraManager?.markIdle(for: name, reason: reason)
                } else {
                    self?.cameraManager?.exitIdlePublication(for: name)
                }
            }
        }
        // Motion wake z idle: každá pollTick (15 Hz) compare current hash vs
        // last-tick hash. Hash MUSÍ být update-ován každou pollTick (ne jen v
        // throttled static-scene bloku), jinak car enter mezi intervaly = no wake.
        let pbForMotion = camera.snapshotLatest()
        var motionDetected = false
        var currentHash: UInt64 = 0
        if let pb = pbForMotion, let roi = myCamera?.roi?.cgRect {
            // Sparse 12-bucket diff sampler — production motion gate.
            let result = Self.sampleBucketDiff(pb, roi: roi,
                                                buckets: &motionProbeCurrentBuckets,
                                                prevBuckets: motionProbeBuckets)
            // Swap current → prev in-place (12 byte memcpy bez Array re-alloc).
            for i in 0..<12 { motionProbeBuckets[i] = motionProbeCurrentBuckets[i] }
            currentHash = result.hash
            if motionProbeBucketsInitialized && result.diffCount >= 3 {
                motionDetected = true
            }
            motionProbeBucketsInitialized = true
            motionProbeLastHash = currentHash
        }

        // **Instant burst trigger z motion gate:** auto vjíždí do scény → motion
        // detected v this tick. Burst start IHNED, ne až po OCR (latence ~100-150 ms
        // by ztratila první frame plate detect).
        if motionDetected {
            startOrExtendBurst(trigger: "motion_gate", extra: [:])
        }

        // Motion-active no-commit detector (diagnostic — counts missed OCR events).
        if motionDetected {
            noMotionTickCount = 0
            if motionStartedAt == nil {
                motionStartedAt = Date()
                commitsAtMotionStart = commitsTotal
                motionNoCommitLogged = false
            } else if !motionNoCommitLogged,
                      let start = motionStartedAt,
                      Date().timeIntervalSince(start) > 5.0,
                      commitsTotal == commitsAtMotionStart {
                FileHandle.safeStderrWrite(
                    "[PlatePipeline \(cameraName)] motion-active \(String(format: "%.1f", Date().timeIntervalSince(start)))s no-commit — OCR nic nezachytil (dirty plate / úhel / glare?)\n"
                        .data(using: .utf8)!)
                motionNoCommitLogged = true
            }
        } else {
            noMotionTickCount += 1
            // Motion burst skončil (2 po sobě jdoucí no-motion ticky) → reset state.
            if noMotionTickCount >= 2 {
                motionStartedAt = nil
                motionNoCommitLogged = false
            }
        }

        // **Idle throttle:** v "opravdu idle" scéně (idle mode ON + žádný motion
        // + žádný recent plate burst) cap na user-configured `idleDetectionFps`
        // (default 1 fps, range 0.5–5). Reaguje na motion detect okamžitě.
        if idleEnabled && inIdle && !motionDetected && burstUntilTs == nil {
            let idleFps = max(0.5, min(5.0, state?.idleDetectionFps ?? 1.0))
            let idleInterval = 1.0 / idleFps
            if Date().timeIntervalSince(lastProcessedAt) < idleInterval {
                return  // throttle na user idleDetectionFps během opravdového idle
            }
        }
        guard let pb = pbForMotion ?? camera.snapshotLatest() else { return }
        // Non-blocking OCR gate — pokud jsou všechny runtime sloty obsazené,
        // skipni tick. Timer fires zas za ~1/fps s a nejnovější frame zkusíme
        // znovu. Pipeline nikdy nezablokuje main thread.
        let nowTs = ProcessInfo.processInfo.systemUptime
        let budgetSnapshot = ResourceBudget.shared.currentSnapshot()
        let maxConcurrent = ocrConcurrencyLimit(for: budgetSnapshot)
        if maxConcurrent != currentOcrMaxConcurrent {
            currentOcrMaxConcurrent = maxConcurrent
            Audit.event("ocr_concurrency_change", [
                "camera": cameraName,
                "max": maxConcurrent,
                "mode": budgetSnapshot.mode.rawValue,
                "ocrP95Ms": Double(budgetSnapshot.ocrP95Ms)
            ])
            FileHandle.safeStderrWrite(
                "[PlatePipeline \(cameraName)] OCR concurrent=\(maxConcurrent) mode=\(budgetSnapshot.mode.rawValue) p95=\(Int(budgetSnapshot.ocrP95Ms))ms\n"
                    .data(using: .utf8)!)
        }
        guard ocrGate.tryAcquire(maxConcurrent: maxConcurrent) else {
            if slotsBusyStartTs == 0 { slotsBusyStartTs = nowTs }
            if nowTs - slotsBusyStartTs > 5.0 {
                FileHandle.safeStderrWrite("[PlatePipeline] WATCHDOG OCR gate stuck >5s, resetting in-flight counter\n".data(using: .utf8)!)
                ocrGate.reset()
                slotsBusyStartTs = 0  // reset counter — fresh slate
            }
            return
        }
        // Úspěšný acquire → clear busy timer. Reset musí být tady (ne na každém
        // acquire), aby watchdog měřil "čas jak dlouho je stuck", ne "čas od
        // posledního acquiru".
        slotsBusyStartTs = 0
        if let prev = lastPixelBuffer, prev === pb {
            // Same buffer → duplicate tick, skip + release slot.
            ocrGate.release()
            return
        }

        // Static-scene cache + motion-aware rate. Pokud ROI pixels se nemění ≥ idleHoldFrames
        // frames, jedeme jen každý 5. frame. Úspora CPU ~80 % v idle (prázdná scéna).
        // `myCamera?.roi` je per-pipeline correct (NE `state.activeCamera?.roi`,
        // ten by v dual-camera setupu throttloval na cizí ROI).
        let explicitIdleActive = state?.idleModeEnabled ?? false
        if !explicitIdleActive, currentHash != 0, !motionDetected {
            // Reuse hash z motion-wake probe — same frame, same ROI → same hash
            // (recompute = 2× CVPixelBufferLockBaseAddress per tick = ~0.4 ms wasted).
            // Skip také když motion detected — víme že scene se změnila.
            let h = currentHash
            if h == lastROIHash {
                sameHashCount += 1
                if sameHashCount > Self.idleHoldFrames && sameHashCount % Self.idleSkipEvery != 0 {
                    // Burst bypass — během 4s burst window zachovat plný throughput
                    // (auto v záboru = potřebujeme každý frame).
                    if burstUntilTs == nil {
                        ocrGate.release()  // release slot, nothing to process
                        return
                    }
                }
            } else {
                sameHashCount = 0
                lastROIHash = h
            }
        }

        lastProcessedAt = Date()
        lastPixelBuffer = pb
        tick(pixelBuffer: pb)  // slot release happens in worker's defer
    }

    /// 8-pixel quantized hash pro detection static scene. Sampleuje Y plane
    /// (NV12 plane 0, 1 B/px luminance). 4-bit quantizace = tolerant vůči drobným
    /// sensor noise fluktuacím, sensitive na reálné motion (plate enter, light
    /// change ≥ 16 levels). Chroma plane ignorujeme — luminance sama stačí pro
    /// static-scene detection a je 2× rychlejší read (1 B/px vs 4).
    private static func sampleROIHash(_ pb: CVPixelBuffer, roi: CGRect) -> UInt64 {
        // CRITICAL defensive guards: CVPixelBuffer z VTDecompressionSession může mít
        // unpredictable layout / lifecycle vs. naš předchozí ffmpeg-produkovaný pool.
        // Lock return value + plane count + base address nil-check + bounds clamping.
        let lockStatus = CVPixelBufferLockBaseAddress(pb, .readOnly)
        guard lockStatus == kCVReturnSuccess else { return 0 }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        guard w > 0, h > 0 else { return 0 }

        // Y plane access (NV12 plane 0 = luminance). isPlanar musí být true pro NV12;
        // defensively handle non-planar / missing-plane případy (decoder občas
        // vrací jiný format než expected, např. při error recovery).
        let isPlanar = CVPixelBufferIsPlanar(pb)
        let planeCount = CVPixelBufferGetPlaneCount(pb)
        guard !isPlanar || planeCount >= 1 else { return 0 }

        guard let base = isPlanar
            ? CVPixelBufferGetBaseAddressOfPlane(pb, 0)
            : CVPixelBufferGetBaseAddress(pb) else { return 0 }
        let bpr = isPlanar
            ? CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            : CVPixelBufferGetBytesPerRow(pb)
        guard bpr > 0 else { return 0 }

        // Plane dims (Y plane = full frame pro NV12)
        let planeW = isPlanar ? CVPixelBufferGetWidthOfPlane(pb, 0) : w
        let planeH = isPlanar ? CVPixelBufferGetHeightOfPlane(pb, 0) : h
        guard planeW > 0, planeH > 0 else { return 0 }

        let x0 = max(0, min(planeW - 1, Int(roi.minX)))
        let y0 = max(0, min(planeH - 1, Int(roi.minY)))
        let x1 = max(x0 + 1, min(planeW, Int(roi.maxX)))
        let y1 = max(y0 + 1, min(planeH, Int(roi.maxY)))
        let rw = x1 - x0, rh = y1 - y0
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var hash: UInt64 = 0xcbf29ce484222325  // FNV-1a offset
        // 3×4 grid (12 samples) — top/middle/bottom × 4 columns. Bottom row je
        // kritická pro bumper-level view, kde plate často je.
        for gy in 0..<3 {
            // gy=0 top, gy=1 middle, gy=2 bottom — vše in-bounds [y0, y1-1].
            let y = y0 + (rh - 1) * gy / 2
            for gx in 0..<4 {
                let x = x0 + (rw - 1) * gx / 3  // 4 sloupce: left, 1/3, 2/3, right
                // Bounds check — defensivně proti ptr[out-of-range]
                let offset = y * bpr + x
                guard offset >= 0, offset < bpr * planeH else { continue }
                let luma = ptr[offset]
                let quant = UInt64(luma >> 4)
                hash ^= quant
                hash = hash &* 0x100000001b3
            }
        }
        return hash
    }

    /// Sample 12 luma buckets (3×4 grid, 4-bit each) + compare k prevBuckets + FNV hash.
    /// Vrátí (diffCount, hash) — diff = počet buckets co se změnily ≥ 2 levels
    /// (tolerance ±1 proti noise), hash = FNV-1a over buckets pro static-scene cache.
    ///
    /// `inout buckets:` aby caller pre-alokoval (žádný hot-path malloc; pollTick
    /// fires ~10 Hz × 2 kamery × 86400 s = ~17 M ticks/den).
    private static func sampleBucketDiff(_ pb: CVPixelBuffer, roi: CGRect,
                                          buckets: inout [UInt8],
                                          prevBuckets: [UInt8]) -> (diffCount: Int, hash: UInt64) {
        // buckets má capacity 12 — guarded caller. In-place reset.
        for i in 0..<12 { buckets[i] = 0 }
        let lockStatus = CVPixelBufferLockBaseAddress(pb, .readOnly)
        guard lockStatus == kCVReturnSuccess else { return (0, 0) }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard w > 0, h > 0 else { return (0, 0) }
        let isPlanar = CVPixelBufferIsPlanar(pb)
        let planeCount = CVPixelBufferGetPlaneCount(pb)
        guard !isPlanar || planeCount >= 1 else { return (0, 0) }
        guard let base = isPlanar
            ? CVPixelBufferGetBaseAddressOfPlane(pb, 0)
            : CVPixelBufferGetBaseAddress(pb) else { return (0, 0) }
        let bpr = isPlanar ? CVPixelBufferGetBytesPerRowOfPlane(pb, 0) : CVPixelBufferGetBytesPerRow(pb)
        guard bpr > 0 else { return (0, 0) }
        let planeW = isPlanar ? CVPixelBufferGetWidthOfPlane(pb, 0) : w
        let planeH = isPlanar ? CVPixelBufferGetHeightOfPlane(pb, 0) : h
        guard planeW > 0, planeH > 0 else { return (0, 0) }
        let x0 = max(0, min(planeW - 1, Int(roi.minX)))
        let y0 = max(0, min(planeH - 1, Int(roi.minY)))
        let x1 = max(x0 + 1, min(planeW, Int(roi.maxX)))
        let y1 = max(y0 + 1, min(planeH, Int(roi.maxY)))
        let rw = x1 - x0, rh = y1 - y0
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var hash: UInt64 = 0xcbf29ce484222325  // FNV-1a offset
        var idx = 0
        for gy in 0..<3 {
            let y = y0 + (rh - 1) * gy / 2
            for gx in 0..<4 {
                let x = x0 + (rw - 1) * gx / 3
                let offset = y * bpr + x
                if offset >= 0 && offset < bpr * planeH {
                    let quant = ptr[offset] >> 4  // 4-bit bucket
                    buckets[idx] = quant
                    hash ^= UInt64(quant)
                    hash = hash &* 0x100000001b3
                }
                idx += 1
            }
        }
        guard prevBuckets.count == 12 else { return (0, hash) }
        var diffCount = 0
        for i in 0..<12 {
            let delta = Int(buckets[i]) - Int(prevBuckets[i])
            if abs(delta) >= 2 { diffCount += 1 }
        }
        return (diffCount, hash)
    }

    /// Timestamp kdy byly slots naposledy všechny obsazené — watchdog uvolňuje
    /// po 5 s stuck state.
    private var slotsBusyStartTs: TimeInterval = 0

    /// Spustí nebo prodlouží burst — instantní max-HW fps boost (14 fps ANE limit).
    /// Idempotentní: druhý call v aktivním burst window jen prodlouží deadline.
    /// Audit `detection_burst_start` jen na first start; extension silent.
    private func startOrExtendBurst(trigger: String, extra: [String: Any]) {
        let now = Date()
        let extendedDeadline = now.addingTimeInterval(Self.burstHoldSec)
        let shouldStart = burstUntilTs == nil
        if burstUntilTs == nil || extendedDeadline > burstUntilTs! {
            burstUntilTs = extendedDeadline
        }
        guard shouldStart else { return }
        let baseline = currentPollFps > 0 ? currentPollFps : (state?.detectionFpsManual ?? 10.0)
        burstBaselineFps = baseline
        // Max HW: ANE per-camera ceiling. Override jakýkoliv user multiplier —
        // burst window je krátký (4 s), absolute speed je priorita.
        updatePollFps(Self.burstFpsTarget)
        var fields: [String: Any] = [
            "camera": cameraName,
            "burstFps": Self.burstFpsTarget,
            "baselineFps": baseline,
            "trigger": trigger
        ]
        for (k, v) in extra { fields[k] = v }
        Audit.event("detection_burst_start", fields)
    }

    private func ocrConcurrencyLimit(for budget: ResourceBudget.Snapshot) -> Int {
        // **Burst override:** během burst window force max 2 concurrent.
        // Burst je krátký (4s), chceme max throughput.
        if burstUntilTs != nil, budget.mode == .normal {
            return Self.ocrMaxConcurrentNormal
        }
        guard budget.mode == .normal else {
            return Self.ocrMaxConcurrentConstrained
        }
        let p95 = budget.ocrP95Ms
        if p95 == 0 {
            return Self.ocrMaxConcurrentNormal  // no measurement yet → trust normal
        }
        // **Hysteresis:**
        //  - když jsme v 2 → drop na 1 jen při p95 > 100ms
        //  - když jsme v 1 → release na 2 jen při p95 < 60ms
        // Eliminuje flapping kolem 80ms boundary.
        if currentOcrMaxConcurrent == Self.ocrMaxConcurrentNormal {
            return p95 > Self.ocrConcurrencyCeilingUpMs ? Self.ocrMaxConcurrentConstrained : Self.ocrMaxConcurrentNormal
        } else {
            return p95 < Self.ocrConcurrencyCeilingDownMs ? Self.ocrMaxConcurrentNormal : Self.ocrMaxConcurrentConstrained
        }
    }

    private func tick(pixelBuffer pb: CVPixelBuffer) {
        guard let state else {
            ocrGate.release()  // zdroje nejsou dostupné, uvolni slot
            return
        }
        guard let cam = myCamera else {
            ocrGate.release()
            return
        }

        let pbW = CGFloat(CVPixelBufferGetWidth(pb))
        let pbH = CGFloat(CVPixelBufferGetHeight(pb))
        let videoSize = CGSize(width: pbW, height: pbH)
        // ROI v config je již v native pixelech, stejných jako pixelBuffer
        let roiRect: CGRect? = cam.roi?.cgRect
        let roiRotation: CGFloat = cam.roi?.rotationRadians ?? 0
        let perspective: PerspectiveConfig? = cam.roi?.perspective
        let detectionQuad: [CGPoint]? = cam.roi?.detectionQuad
        let exclusionMasks: [CGRect] = cam.roi?.exclusionMasks ?? []
        let perspectiveCalibration: PerspectiveCalibration? = cam.roi?.perspectiveCalibration
        let camNameSnapshot = cameraName  // snapshot pro nonisolated doOCRTick
        let allowVanity = state.allowVanityPlates
        let allowForeign = state.allowForeignPlates
        // Per-camera hodnoty (vjezd/výjezd mají vlastní tuning). Fallback na
        // AppState defaulty kdyby nebyly v CameraConfig (forward-compat).
        let minObsFrac = CGFloat(cam.ocrMinObsHeightFraction)
        // Sync tracker parametry z AppState — user-nastavitelné v Settings.
        tracker.recommitAfterSec = state.recommitDelaySec
        tracker.iouThreshold = CGFloat(state.trackerIouThreshold)
        tracker.maxLostFrames = state.trackerMaxLostFrames
        tracker.minHitsToCommit = state.trackerMinHitsToCommit
        tracker.forceCommitAfterHits = state.trackerForceCommitAfterHits
        tracker.minWinnerVotes = state.trackerMinWinnerVotes
        tracker.minWinnerVoteShare = Float(state.trackerMinWinnerVoteShare)
        tracker.minPlateWidthFraction = CGFloat(state.trackerMinPlateWidthFraction)
        tracker.minPlateWidthSafetyMult = state.trackerMinPlateWidthSafetyMult
        let budgetMode = ResourceBudget.shared.currentMode
        let enhancedRetryEnabled = state.enhancedRetryEnabled && budgetMode == .normal
        let secondaryEngineEnabled = state.useSecondaryEngine
            && budgetMode == .normal
            && secondaryCircuit.allowsRun()
        tracker.originVoteConfig = (enhancedRetryEnabled || secondaryEngineEnabled)
            ? OriginVoteConfig(
                enhancedVoteWeight: enhancedRetryEnabled ? Float(state.enhancedVoteWeight) : 1.0,
                baseVoteWeightWhenEnhancedOverlap: enhancedRetryEnabled ? Float(state.baseVoteWeightWhenEnhancedOverlap) : 1.0,
                crossValidatedVoteWeight: secondaryEngineEnabled ? Float(state.crossValidatedVoteWeight) : 1.0
            )
            : .neutral
        // Exit mode: vyjezd kamera má rychlejší auta + větší úhel → commit ASAP.
        // Trigger: cameraName obsahuje "vyjezd" nebo "exit". Jinak standard gates.
        tracker.exitMode = cameraName.lowercased().contains("vyjezd")
            || cameraName.lowercased().contains("exit")
        tracker.cameraName = cameraName
        Store.shared.snapshotRetentionDays = Double(state.snapshotRetentionDays)
        Store.shared.snapshotMaxFiles = state.snapshotRetentionMaxCount
        Store.shared.manualPassesMaxCount = state.manualPassesMaxCount
        WebhookClient.shared.maxRetryCount = state.webhookRetryCount
        WebhookClient.shared.timeoutSec = Double(state.webhookTimeoutMs) / 1000.0
        // Snapshot známých SPZ pro fuzzy snap (Levenshtein-1) v background closure.
        // Bez snapshotu bychom museli přeskakovat na MainActor uprostřed OCR pipeline.
        let knownSnapshot = KnownPlates.shared.entries.map { $0.plate }
        // customWords = jen whitelist (přidávání top-history plates z DB blokovalo
        // pipeline kvůli Store query na MainActor + Vision customWords > 50 entries).
        let customWordsHint = knownSnapshot
        let rotationActive = abs(roiRotation) > 0.001
        let fastMode = state.ocrFastMode
        let dualPass = state.ocrDualPassEnabled
        let enhancedRetryThreshold = Float(state.enhancedRetryThreshold)
        let maxRetryBoxes = state.enhancedRetryMaxBoxes

        frameIdx += 1
        let myFrameIdx = frameIdx
        let t0 = Date()

        // Wrap pb do Sendable boxu — CVPixelBuffer není `Sendable` v Swift 6,
        // ale CF retain/release + Lock jsou atomic (thread-safe API).
        let pbBox = PixelBufferBox(pb)
        // Capture semafor PŘED weak-self guard — kdyby `self` bylo nil (pipeline
        // torn-down během reconnectu / settings toggle mid-flight), guard
        // return by skočil ZA `defer`, slot by se nikdy neuvolnil = permit leak.
        // Každý takový cyklus snižuje semafor capacity o 1, po N reconnectech
        // pipeline dead-locked. Capture lokálně obchází capture cyklus self.
        let gate = self.ocrGate
        processingQueue.async { [weak self] in
            defer { gate.release() }  // release VŽDY — i když self deallocated
            guard let self else { return }
            autoreleasepool {
                self.doOCRTick(pb: pbBox.pb, roiRect: roiRect, roiRotation: roiRotation,
                               rotationActive: rotationActive, allowVanity: allowVanity,
                               allowForeign: allowForeign, knownSnapshot: knownSnapshot,
                               customWordsHint: customWordsHint,
                               minObsFrac: minObsFrac, perspective: perspective,
                               detectionQuad: detectionQuad,
                               exclusionMasks: exclusionMasks,
                               perspectiveCalibration: perspectiveCalibration,
                               fastMode: fastMode,
                               dualPass: dualPass,
                               enhancedRetryEnabled: enhancedRetryEnabled,
                               secondaryEngineEnabled: secondaryEngineEnabled,
                               enhancedRetryThreshold: enhancedRetryThreshold,
                               maxRetryBoxes: maxRetryBoxes,
                               videoSize: videoSize, myFrameIdx: myFrameIdx, t0: t0,
                               cameraName: camNameSnapshot)
            }
        }
    }

    /// Běží na processingQueue (non-MainActor) — neobsahuje žádné přímé čtení
    /// `self.state` mimo Task { @MainActor }. Proto nonisolated OK.
    nonisolated private func doOCRTick(pb: CVPixelBuffer, roiRect: CGRect?, roiRotation: CGFloat,
                                       rotationActive: Bool, allowVanity: Bool, allowForeign: Bool,
                                       knownSnapshot: [String], customWordsHint: [String],
                                       minObsFrac: CGFloat,
                                       perspective: PerspectiveConfig?,
                                       detectionQuad: [CGPoint]?,
                                       exclusionMasks: [CGRect],
                                       perspectiveCalibration: PerspectiveCalibration?,
                                       fastMode: Bool,
                                       dualPass: Bool,
                                       enhancedRetryEnabled: Bool,
                                       secondaryEngineEnabled: Bool,
                                       enhancedRetryThreshold: Float,
                                       maxRetryBoxes: Int,
                                       videoSize: CGSize, myFrameIdx: Int, t0: Date,
                                       cameraName camNameCopy: String) {
        let visionReadings = PlateOCR.recognize(in: pb, roiInPixels: roiRect,
                                                rotationRadians: roiRotation,
                                                perspective: perspective,
                                                detectionQuad: detectionQuad,
                                                exclusionMasks: exclusionMasks,
                                                perspectiveCalibration: perspectiveCalibration,
                                                customWords: customWordsHint,
                                                minObsHeightFraction: minObsFrac,
                                                fastMode: fastMode,
                                                dualPass: dualPass,
                                                enhancedRetryEnabled: enhancedRetryEnabled,
                                                enhancedRetryThreshold: enhancedRetryThreshold,
                                                maxRetryBoxes: maxRetryBoxes,
                                                auditCamera: camNameCopy,
                                                auditFrameIdx: myFrameIdx)
        // **Sekundární OCR engine cross-validation:** když flag ON a
        // `FastPlateOCROnnxEngine` má načtený ONNX model, pošli každý Vision
        // reading do sekundárního recognizeru. Exact shoda → `.crossValidated`
        // (2× vote weight v trackeru). L-1 shoda → `.crossValidatedFuzzy`
        // (observation-mode nejistota, bez text override). Async merge je
        // sync-blocking přes timeoutovaný DispatchSemaphore — plugin nesmí
        // zastavit primární Vision cestu.
        let readings: [PlateOCRReading]
        let circuit = secondaryCircuit
        if secondaryEngineEnabled, let secondary = circuit.engine,
           circuit.tryBegin() {
            let semaphore = DispatchSemaphore(value: 0)
            let box = SecondaryOCRMergeBox()
            Task.detached {
                defer { circuit.finish() }
                let merged = await PlateReadingMerger.mergeWithSecondary(
                    visionReadings: visionReadings,
                    secondaryEngine: secondary,
                    cameraID: camNameCopy,
                    audit: true
                )
                box.store(merged)
                semaphore.signal()
            }
            let timeout = DispatchTime.now() + .milliseconds(Self.secondaryEngineTimeoutMs)
            if semaphore.wait(timeout: timeout) == .success, let merged = box.load() {
                readings = merged
            } else {
                circuit.trip(seconds: 300, reason: "timeout", camera: camNameCopy)
                Audit.event("engine_timeout", [
                    "engine": secondary.name,
                    "camera": camNameCopy,
                    "timeout_ms": Self.secondaryEngineTimeoutMs,
                    "readings": visionReadings.count
                ])
                readings = visionReadings
            }
        } else {
            readings = visionReadings
        }
        // (Idle signál je dál po filtrech — až když máme validní candidates,
        //  ne jen raw Vision readings které mohou být pouhý noise text.)
        let candidates = readings.compactMap { r -> PlateOCRReading? in
            guard r.confidence >= 0.5 else { return nil }
            let textsToTry = [r.text] + r.altTexts
            var picked: (norm: String, region: PlateRegion)? = nil
            for t in textsToTry {
                let (norm, valid, region) = CzNormalizer.process(t)
                guard valid else { continue }
                if region == .czVanity && !allowVanity { continue }
                if region == .foreign && !allowForeign { continue }
                if !rotationActive {
                    guard PlateValidator.aspectMatches(r.bbox) else { continue }
                }
                if let prev = picked {
                    if regionScore(region) > regionScore(prev.region) {
                        picked = (norm, region)
                    }
                } else {
                    picked = (norm, region)
                }
                if region == .cz || region == .czElectric { break }
            }
            guard let pick = picked else { return nil }
            let snapped = fuzzySnapToKnown(pick.norm, known: knownSnapshot)
            let strictEngineBacked = (r.origin == .passTwoEnhanced || r.origin == .crossValidated)
                && (pick.region == .cz || pick.region == .czElectric || pick.region == .sk)
            return PlateOCRReading(text: snapped, altTexts: [], confidence: r.confidence, bbox: r.bbox,
                                   workBox: r.workBox, workSize: r.workSize, region: r.region,
                                   workspaceImage: r.workspaceImage,
                                   rawWorkspaceImage: r.rawWorkspaceImage,
                                   origin: r.origin,
                                   isStrictValidCz: r.isStrictValidCz || strictEngineBacked,
                                   toneMeta: r.toneMeta)
        }
        let inferenceMs = Date().timeIntervalSince(t0) * 1000

        // Periodic CI texture cache clear — bez tohoto CIContext drží GPU textury
        // z každého rotated cropu. Po ~500 framech (~2 min @ 5 fps) může být v cachi
        // 100+ MB. `clearCaches` je levný — <1 ms. Spustíme každých ~60 framů
        // NEBO každých 15 s (kterékoliv první nastane — time-based fallback chrání
        // před scenariem "pipeline hanglo / throttluje na 1 fps → counter neroste
        // dost rychle → cache neskončí". Watchdog zajišťuje bounded GPU memory.)
        if Self.ciCacheClearCadence.shouldClear() {
            SharedCIContext.shared.clearCaches()
        }

        // Signál idle watcheru — JEN když máme validní candidates (po formát
        // filtrech). Raw Vision readings obsahují i noise text (scéna má vždy
        // nějaký text). Tímto idle mode skutečně nastupuje když není auto.
        let hasValidPlate = !candidates.isEmpty
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.handleResults(candidates, frameIdx: myFrameIdx,
                               sourceSize: videoSize, inferenceMs: inferenceMs,
                               pixelBuffer: pb)
            if hasValidPlate {
                // Exit idle — reset FPS okýnka aby zobrazovaný detectFps
                // nebyl bržděn staršími idle vzorky. Bez tohoto by UI metrika
                // ukazovala ramp 1→5 fps přes ~5 s (window bounded convergence).
                if self.wasIdlePublished {
                    self.fpsWindowDetect.removeAll(keepingCapacity: true)
                    self.captureFpsEMA = 0  // next tick resets from measured delta
                    self.lastCaptureCheck = (0, 0)
                }
                self.validActivityTs = Date()
                self.cameraManager?.markActivity(for: camNameCopy)
            }
        }
    }

    nonisolated private static let ciCacheClearCadence = CICacheClearCadence()

    /// Nejvyšší frameIdx který už tracker viděl. S concurrent workers může
    /// dokončení proběhnout out-of-order (slot B dokončí frame 11 dřív než
    /// slot A dokončí frame 10). Zahodíme late result → tracker konzistentní,
    /// drop frame je akceptovatelný (další příští tik přijde do 70 ms).
    private var lastHandledFrameIdx: Int = 0

    private func handleResults(_ readings: [PlateOCRReading], frameIdx: Int, sourceSize: CGSize, inferenceMs: Double = 0, pixelBuffer: CVPixelBuffer? = nil) {
        guard let state else { return }
        // Out-of-order guard — late frame zahozený, novější už updatoval tracker.
        guard frameIdx > lastHandledFrameIdx else { return }
        lastHandledFrameIdx = frameIdx

        fpsWindowDetect.append(Date())
        if fpsWindowDetect.count > 30 { fpsWindowDetect.removeFirst(fpsWindowDetect.count - 30) }
        state.pipelineStats.detectFps = fps(window: fpsWindowDetect)
        state.pipelineStats.ocrLatencyMs = inferenceMs
        // Step 5: feed ResourceBudget OCR latency p95 ring buffer per kamera.
        // Budget evaluator readuje p95 jako jeden ze 4 signálů (proc CPU,
        // sys CPU, thermal, ocr p95) pro mode classification.
        if inferenceMs > 0 {
            ResourceBudget.shared.recordOcrLatency(inferenceMs, for: cameraName)
        }

        // Snapshot whitelist plate stringů — `handleResults` běží na MainActor,
        // takže přístup k @MainActor `KnownPlates.shared` je safe. Tracker
        // tento snapshot použije pro whitelist-override gating bez nutnosti
        // volat MainActor.assumeIsolated z processingQueue (silent race).
        let snapshot = Set(KnownPlates.shared.entries.map { $0.plate })
        let (active, finalized) = tracker.update(
            detections: readings, frameIdx: frameIdx,
            knownSnapshot: snapshot
        )

        // **Burst extension:** pokud tracker má active/finalized track nebo dostal
        // čerstvé readings, prodluž burst window. Trigger samotný se spouští už
        // dříve v `pollAndProcess` přes motion gate.
        let hasActivity = !active.isEmpty || !finalized.isEmpty || !readings.isEmpty
        if hasActivity {
            startOrExtendBurst(trigger: !active.isEmpty ? "active_track"
                : !finalized.isEmpty ? "finalized_track" : "raw_reading",
                extra: [
                    "activeCount": active.count,
                    "finalizedCount": finalized.count,
                    "readingsCount": readings.count
                ])
        }

        // Live overlay — 1 dominantní track per kamera. Priorita:
        //  1. Track updated TENTO tick (čerstvá pozice) — důležité při rychlém pohybu,
        //     kdy IoU-mismatch vytvoří nový track a starý dočasně žije v maxLostFrames;
        //     bez tohoto by overlay zamrzal na staré pozici 2 s.
        //  2. Mezi čerstvými → track s nejvíc hits (dominantní plate).
        //  3. Fallback (žádný čerstvý) → nejnovější updated + nejvíc hits.
        let valid = active.filter { $0.lastWorkBox != .zero && $0.lastWorkSize != .zero }
        // Fresh = track byl aktualizován v tomto tiku NEBO v předchozím
        // (2-frame grace kvůli IoU-miss při rychlém pohybu — bez toho bbox
        // blikne při každém frame kde Vision mine match). Starší track se
        // NEZOBRAZUJE — "nevidim spz" overlay nastoupí okamžitě po ztrátě.
        let fresh = valid.filter { frameIdx - $0.lastSeenFrame <= 1 }
        let bestTrack = fresh.max { a, b in
            if a.lastSeenFrame != b.lastSeenFrame { return a.lastSeenFrame < b.lastSeenFrame }
            return a.hits < b.hits
        }
        let newLive: [LiveDetection] = bestTrack.map { t in
            let recent = t.observations.last
            // Velocity z posledních 2 observations (pixels per second). Použije
            // UI overlay pro extrapolaci pozice (Vision lag 50-80 ms + SwiftUI
            // render ~1 frame → ~100-150 ms behind actual car position).
            var vel = CGVector.zero
            var workVel = CGVector.zero
            if t.observations.count >= 2 {
                let a = t.observations[t.observations.count - 2]
                let b = t.observations[t.observations.count - 1]
                let dFrames = max(1, b.frameIdx - a.frameIdx)
                // Pipeline detectFps ≈ 10 pro fast-gate; fallback 10 pokud window empty.
                let detectFps = max(1.0, self.fps(window: self.fpsWindowDetect))
                let dt = Double(dFrames) / detectFps
                if dt > 0.001 {
                    // Jitter gate: OCR bbox má pixel-level noise ±3 px i pro
                    // stacionární plate → extrapolace by bobtnala. Pod 5 px/frame
                    // delta (= ~50 px/s při 10 fps) považujeme za noise, ne motion.
                    let dxS = b.bbox.midX - a.bbox.midX
                    let dyS = b.bbox.midY - a.bbox.midY
                    let sRawPerFrame = hypot(dxS, dyS)
                    if sRawPerFrame >= 5 {
                        vel = CGVector(dx: dxS / dt, dy: dyS / dt)
                    }
                    let dxW = b.workBox.midX - a.workBox.midX
                    let dyW = b.workBox.midY - a.workBox.midY
                    let wRawPerFrame = hypot(dxW, dyW)
                    if wRawPerFrame >= 5 {
                        workVel = CGVector(dx: dxW / dt, dy: dyW / dt)
                    }
                }
            }
            return [LiveDetection(
                bbox: t.lastBbox,
                workBox: t.lastWorkBox,
                workSize: t.lastWorkSize,
                plate: recent?.text ?? "",
                confidence: t.bestScore,
                sourceWidth: sourceSize.width,
                sourceHeight: sourceSize.height,
                ts: Date(),
                velocity: vel,
                workVelocity: workVel
            )]
        } ?? []
        // Žádná dead-zone — publish live, každý tick. Throttle ~10 Hz už dělá
        // detection rate pipeline (5–10 fps).
        state.liveDetectionsByCamera[cameraName] = newLive

        for track in finalized {
            commit(track: track, sourceSize: sourceSize)
        }
        if !finalized.isEmpty {
            commitsTotal += finalized.count
            state.pipelineStats.commitsTotal = commitsTotal
        }
    }

    private func commit(track: PlateTrack, sourceSize: CGSize) {
        guard let state else { return }
        guard let best = track.bestText() else { return }
        // Audit log — Tracker je single source of truth pro "commit-worthy",
        // Pipeline jen dedup + persist. Tento řádek dělá viditelné každé volání
        // commit() s parametry pro pozdější forensic replay (kdyby v budoucnu
        // něco silently dropovalo, vidíme přesně proč). Stderr (grep) +
        // Audit JSONL (jq / replay) — viz Persistence/Audit.swift.
        FileHandle.safeStderrWrite(
            "[Pipeline.commit \(cameraName)] plate=\(best.text) hits=\(track.hits) votes=\(best.votes) displayConf=\(String(format: "%.3f", best.meanConf)) region=\(best.region.rawValue) path=\(track.commitPath ?? "?")\n"
                .data(using: .utf8)!)
        var commitFields: [String: Any] = [
            "camera": cameraName, "track": track.id,
            "plate": best.text, "region": best.region.rawValue,
            "hits": track.hits, "votes": best.votes,
            "displayConf": Double(best.meanConf),
            "path": track.commitPath ?? "unknown"
        ]
        if let tone = track.toneMeta(matching: best.text) {
            commitFields["tone"] = tone.payload
        }
        Audit.event("pipeline_commit", commitFields)
        // Re-commit delay — user-nastavitelný v horním banneru (ZPOŽDĚNÍ %s).
        // Blokuje re-commit stejné SPZ (+ L1 fuzzy variant) dokud neuplyne delay
        // od posledního committu. PO uplynutí se plate commit znovu i když je
        // stále v záběru (přesný match user-mental model "re-detection interval").
        let now = Date()
        let recommitDelay = state.recommitDelaySec
        // Cleanup expired entries
        recentCommits.removeAll {
            now.timeIntervalSince($0.ts) > max(300, recommitDelay * 2)
        }
        // Safety cap pro vysoké traffic — array nikdy nepřesáhne 500 entries
        // (pre-existing recommitDelay window typicky drží <50, ale defense-in-depth):
        if recentCommits.count > 500 {
            recentCommits.removeFirst(recentCommits.count - 500)
        }

        // **Vrstva 5: delayed drop pro weak fast-single + prior fragment match.**
        // Detekuje garbage misread duplicate (např. 1AB2978 1.7s po 1AB2345 consensus).
        // Pre-check: kandidát musí být weak + short-lived + mít qualifying prior
        // fragment match. Pokud ano → hold 1.5s, pak drop.
        let isFastSingle = (track.commitPath ?? "") == "fast-single"
        let isWeakConf = best.meanConf < delayedDropLowConfThreshold
        let isShortLived = track.hits <= delayedDropMaxHits
                       && track.observations.count <= delayedDropMaxObservations
        if isFastSingle && isWeakConf && isShortLived {
            if let prior = latestQualifyingPrior(for: best.text,
                                                  candidateCamera: cameraName,
                                                  now: now) {
                let priorAgeMs = Int(now.timeIntervalSince(prior.ts) * 1000)
                pendingDropCandidates.append(PendingDropCandidate(
                    bestText: best.text,
                    bestConf: best.meanConf,
                    registeredAt: now,
                    dropAfter: now.addingTimeInterval(delayedDropHoldDuration),
                    cameraName: cameraName,
                    priorMatchPlate: prior.plate,
                    priorMatchConf: prior.conf,
                    priorMatchAgeMs: priorAgeMs
                ))
                Audit.event("pipeline_dedup_gate", [
                    "camera": cameraName,
                    "plate": best.text,
                    "action": "hold",
                    "reason": "possible-fragment-after-recent-commit",
                    "prior_plate": prior.plate,
                    "prior_conf": Double(prior.conf),
                    "candidate_conf": Double(best.meanConf),
                    "prior_age_ms": priorAgeMs,
                    "hold_ms": Int(delayedDropHoldDuration * 1000),
                ])
                return
            }
        }

        let cutoff = now.addingTimeInterval(-recommitDelay)
        for recent in recentCommits where recent.ts > cutoff {
            let recentText = recent.plate
            if recentText == best.text || isLevenshtein1(recentText, best.text) {
                Audit.event("pipeline_dedup_drop", [
                    "camera": cameraName, "plate": best.text,
                    "recent": recentText, "reason": "exact-or-L1",
                    "delaySec": Int(recommitDelay)
                ])
                return
            }
            // Substring guard: pokud je best.text prefix/suffix/substring existujícího
            // nedávného commitu (nebo naopak), jde o inconsistent OCR fragmentaci
            // stejné plate — skip aby DB nesbírala 4+ separate rows
            // (EL067BJ + ELO67 + 067BJ + BEL067BJ) za jeden fyzický průjezd.
            //
            // Pravidlo: kratší text je substring delšího, oba v cutoff window → skip commit.
            // Pokud nový text je DELŠÍ než recent (plate completion), existing shorter
            // commit zůstane ale nevadí — short version už v DB, long se nedostane duplicate.
            // Trade-off: ztrácíme info o delší version, ale frekvence rozhoduje RecentBuffer
            // (které už má substring merge + upgrade na delší).
            if best.text.count >= 3 && recentText.count >= 3 {
                if best.text.contains(recentText) || recentText.contains(best.text) {
                    Audit.event("pipeline_dedup_drop", [
                        "camera": cameraName, "plate": best.text,
                        "recent": recentText, "reason": "substring"
                    ])
                    return
                }
            }
            // **OCR-variance dedup:** edge-trim equality. Vision občas vrátí ze
            // stejného auta extra char na prefix/suffix v různých framech (např.
            // 5XY12345 + 15XY1234 za < 5 s). L-1 nestačí (Lev=2), substring
            // nestačí. Trim 1 char z each edge a porovnej core.
            if best.text.count >= 6 && recentText.count >= 6 {
                let coreA = stripEdges(best.text)
                let coreB = stripEdges(recentText)
                if coreA == coreB || coreA.contains(coreB) || coreB.contains(coreA) {
                    Audit.event("pipeline_dedup_drop", [
                        "camera": cameraName, "plate": best.text,
                        "recent": recentText, "reason": "edge-trim"
                    ])
                    return
                }
            }
            // **L-2 low-conf dedup:** Vision občas vrátí ze stejného auta L-2
            // misread (např. F→1+8→0 nebo 6→7+L→9 za < 1 s). L-1 dedup gate nestačí.
            // Threshold 0.7 — Vision-fused misread typicky drží 0.5-0.7; vyšší
            // bound = pravé low-conf candidates. Length min 5 (foreign plates 5 chars).
            if best.text.count >= 5 && recentText.count >= 5,
               best.meanConf < 0.7,
               isLevenshtein2(best.text, recentText) {
                Audit.event("pipeline_dedup_drop", [
                    "camera": cameraName, "plate": best.text,
                    "recent": recentText, "reason": "lev2-low-conf",
                    "displayConf": Double(best.meanConf)
                ])
                return
            }
            // **Vrstva 4: ambiguous-glyph dedup independent of conf.**
            // Pokud Vrstvy 1-3 nezachytí (timing race / committed track gate),
            // tady je poslední obrana. Každý mismatch musí být v ambiguous-glyph
            // matrix (S↔B, 8↔B, 0↔O, …) — žádný free pass pro náhodné L2
            // collisions mezi reálnými 2 auty.
            if best.text.count >= 5 && recentText.count >= 5 {
                let cmp = AmbiguousGlyphMatrix.compareWithAmbiguous(best.text, recentText)
                if cmp.editDistance >= 1, cmp.editDistance <= 2,
                   cmp.allMismatchesAmbiguous {
                    Audit.event("pipeline_dedup_drop", [
                        "camera": cameraName, "plate": best.text,
                        "recent": recentText, "reason": "ambiguous-glyph",
                        "displayConf": Double(best.meanConf),
                        "edit_distance": cmp.editDistance,
                    ])
                    return
                }
            }
        }
        recentCommits.append(RecentCommit(
            plate: best.text, ts: now,
            conf: best.meanConf, cameraName: cameraName
        ))
        evaluatePendingDrops()  // catch expired holds in real-time
        let bbox = track.bestBbox
        // workBox/workSize není potřeba pro snapshot extrakci (thumbnail = full
        // processed po detectionQuad crop). Ponechány v PlateTrack pro live overlay.
        let rotation: CGFloat = myCamera?.roi?.rotationRadians ?? 0
        let roi = myCamera?.roi
        // Snapshot = **tight plate crop z kalibrovaného pipelinu**. Rekonstrukce
        // ROI → rotate → perspective → detection crop (identická s PlateOCR),
        // pak extrakce plate-bboxu z workBoxu. Full-res (350 downscale vypnutý pro development).
        // track.bestCGImage je heap-backed snapshot z best-voting framu, nezabírá
        // pool slot. Fallback na lastPixelBuffer (aktuální frame z pool) jen když
        // track neměl příležitost snapshot vytvořit — např. hits=1 noise track,
        // nebo první commit ještě před dosažením `hits >= 2` gate.
        // Pull raw (pre-preprocess) workspace snapshot z trackeru — pokud nemáme,
        // fallback reconstruction níže ho taky vyrobí.
        // Lazy rendering: tracker drží CIImage, renderujeme CGImage až teď.
        let trackerRawCrop: NSImage? = autoreleasepool {
            guard let rawCI = track.bestRawCIImage else { return nil }
            track.bestRawCIImage = nil
            track.pendingBestRawCIImage = nil
            guard let cg = Self.sharedCIContext.createCGImage(rawCI, from: rawCI.extent) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        // Closure vrátí (processed, raw) — processed je to co Vision viděl
        // (post-preprocess), raw je to co kamera natočila (pre-preprocess, ale vždy
        // po všech geometric transforms včetně autoperspective).
        let cropPair: (crop: NSImage?, rawCrop: NSImage?) = autoreleasepool {
                () -> (NSImage?, NSImage?) in
            let bestCG = track.bestCGImage
            track.bestCGImage = nil
            track.pendingBestCGImage = nil

            // bestCGImage je už post-processed workspace (viz PlateOCRReading.workspaceImage —
            // post ROI crop, rotate, perspective, detectionQuad). NESMÍ se na něj
            // aplikovat geometric transforms znovu; source-frame ROI rect by se
            // nematchoval s pre-cropped workspace dimensions a vrátil empty crop.
            // Fast path: pokud máme bestCGImage, je to už finální workspace.
            if let bestCG = bestCG {
                // Fast path: tracker vrátil processed workspace (post-preprocess).
                // **Enhanced-crop-only snapshot:** uložit jen ten malý enhanced výřez
                // kolem plate (s adaptive tone + Lanczos 2× pokud height < 80 px +
                // unsharp), žádný workspace kontext. Snapshot tak ukáže přesně to,
                // co Vision pass 2 reálně četla. Fallback na bestCG (full workspace)
                // pokud je plate příliš malý pro crop.
                let plateBox = track.bestWorkBox
                let enhanced = PlateOCR.enhancedCropForSnapshot(
                    workspace: bestCG, plateBoxTL: plateBox, workSize: track.bestWorkSize
                ) ?? bestCG
                return (NSImage(cgImage: enhanced, size: NSSize(width: enhanced.width, height: enhanced.height)), nil)
            }

            // Fallback path: bestCG chybí (noise track s hits<2) → rekonstruujeme z
            // raw pixel buffer aplikací plné ROI → rotate → perspective → quad pipeline.
            guard let pb = lastPixelBuffer else { return (nil, nil) }
            let ci = CIImage(cvPixelBuffer: pb)
            let pbW = CGFloat(CVPixelBufferGetWidth(pb))
            let pbH = CGFloat(CVPixelBufferGetHeight(pb))

            // Krok 1: ROI crop + rotace (stejné jako v PlateOCR.recognize).
            var processed: CIImage
            if let r = roi, r.cgRect.width > 1, r.cgRect.height > 1 {
                let roiRect = r.cgRect.intersection(CGRect(x: 0, y: 0, width: pbW, height: pbH))
                guard !roiRect.isNull, roiRect.width > 1, roiRect.height > 1 else { return (nil, nil) }
                let ciRect = CGRect(x: roiRect.minX, y: pbH - roiRect.maxY,
                                    width: roiRect.width, height: roiRect.height)
                processed = ci.cropped(to: ciRect)
                    .transformed(by: CGAffineTransform(translationX: -ciRect.minX, y: -ciRect.minY))
                if abs(rotation) > 0.001 {
                    let cx = roiRect.width / 2, cy = roiRect.height / 2
                    let t = CGAffineTransform(translationX: -cx, y: -cy)
                        .concatenating(CGAffineTransform(rotationAngle: rotation))
                    processed = processed.transformed(by: t)
                    let ext = processed.extent
                    processed = processed.transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
                }
                // Krok 2: perspektivní korekce.
                if let pc = r.perspective, !pc.isIdentity {
                    if let corrected = PlateOCR.applyPerspective(processed,
                                                                 width: processed.extent.width,
                                                                 height: processed.extent.height,
                                                                 perspective: pc) {
                        processed = corrected
                    }
                }
                // Krok 3: detection quad bbox crop.
                if let dq = r.detectionQuad, dq.count == 4 {
                    let xs = dq.map { $0.x }, ys = dq.map { $0.y }
                    let nMinX = max(0, min(1, xs.min() ?? 0))
                    let nMaxX = max(0, min(1, xs.max() ?? 1))
                    let nMinY = max(0, min(1, ys.min() ?? 0))
                    let nMaxY = max(0, min(1, ys.max() ?? 1))
                    let isFull = nMinX < 0.01 && nMaxX > 0.99 && nMinY < 0.01 && nMaxY > 0.99
                    if !isFull, nMaxX > nMinX + 0.02, nMaxY > nMinY + 0.02 {
                        let pw = processed.extent.width, ph = processed.extent.height
                        let pxMinX = nMinX * pw
                        let pxMaxX = nMaxX * pw
                        let pxMinYBL = (1 - nMaxY) * ph
                        let pxMaxYBL = (1 - nMinY) * ph
                        let dr = CGRect(x: pxMinX, y: pxMinYBL,
                                        width: pxMaxX - pxMinX, height: pxMaxYBL - pxMinYBL)
                        processed = processed.cropped(to: dr)
                            .transformed(by: CGAffineTransform(translationX: -dr.minX, y: -dr.minY))
                    }
                }
            } else {
                processed = ci
            }

            // Vyrobíme dvě verze: raw (pre-preprocessForOCR) + processed (post).
            // Obě po autoperspective, aby snapshot byl 1:1 s tím co by Vision viděl.
            let rawCI = processed
            let processedCI = PlateOCR.applyOCRPreprocess(processed)
            guard let rawCG = Self.sharedCIContext.createCGImage(rawCI, from: rawCI.extent) else {
                return (nil, nil)
            }
            let processedCG = Self.sharedCIContext.createCGImage(processedCI, from: processedCI.extent) ?? rawCG
            let processedImg = NSImage(cgImage: processedCG, size: NSSize(width: processedCG.width, height: processedCG.height))
            let rawImg = NSImage(cgImage: rawCG, size: NSSize(width: rawCG.width, height: rawCG.height))
            return (processedImg, rawImg)
        }
        let crop: NSImage? = cropPair.crop
        let rawCrop: NSImage? = trackerRawCrop ?? cropPair.rawCrop

        // Physics-Informed Plate Stacking — multi-frame composite OCR.
        // Z track.stackFrames (posledních ≤4 conf-weighted snapshotů) vyrobíme
        // kanonický 600×130 composite a spustíme single Vision. Při dostatečné
        // confidence (>= tracker winner + margin) přepíšeme text/region/confidence
        // → tracker winner voting se stává primárním, composite je sanity check +
        // tie-breaker v marginal conditions.
        var finalText: String = best.text
        var finalConf: Float = best.meanConf
        var finalRegion: PlateRegion = best.region
        let customWordsForStack = KnownPlates.shared.entries.map { $0.plate } +
                                   state.recents.items.prefix(10).map { $0.plate }
        // Stacking vždy spustí a zaloguje porovnání tracker vote vs composite.
        // Override commit text pouze pokud composite má vyšší confidence (bez
        // marginu) a prošel normalizer/validátor. Ostatní commity dostanou jen
        // diagnostický [Stacking] log bez změny finalText.
        if let stacked = PlateOCR.ocrOnStackedComposite(frames: track.stackFrames,
                                                       customWords: customWordsForStack) {
            let (norm, valid, region) = CzNormalizer.process(stacked.text)
            let normDesc = valid && !norm.isEmpty ? norm : "INVALID(\(stacked.text))"
            // Override gate (2× cesty):
            //  1) **Strict** — composite confidence striktně > tracker winner.
            //     Tracker dostal "horší frame" v ranku, composite multi-frame
            //     vyhrál → trust composite. Žádné L-1 omezení.
            //  2) **Consensus relax** — pro hits ≥ 3 akceptujeme composite jako
            //     primary i s mírně nižší confidence (≥85 % winner conf), POKUD
            //     je composite L≤1 od tracker winner. Logika: 3+ shodných hlasů
            //     znamená text je konzistentně viděný; composite tady má smysl
            //     jen jako "stabilizovaná verze".
            let l1Compatible = norm == best.text || PlateTrack.isL1(norm, best.text)
            let strictOverride = valid && !norm.isEmpty && stacked.confidence > best.meanConf
            let consensusOverride = valid && !norm.isEmpty && track.hits >= 3
                && stacked.confidence >= best.meanConf * 0.85 && l1Compatible
            let willOverride = strictOverride || consensusOverride
            FileHandle.safeStderrWrite(
                "[Stacking] track=\(track.id) frames=\(track.stackFrames.count) vote=\(best.text)(\(String(format: "%.2f", best.meanConf))) composite=\(normDesc)(\(String(format: "%.2f", stacked.confidence)))\(willOverride ? " OVERRIDE" : "")\n"
                    .data(using: .utf8)!)
            Audit.event("stacking_composite", [
                "camera": cameraName, "track": track.id,
                "frames": track.stackFrames.count, "hits": track.hits,
                "vote": best.text, "voteConf": Double(best.meanConf),
                "composite": norm, "compositeConf": Double(stacked.confidence),
                "valid": valid, "override": willOverride,
                "overrideMode": willOverride ? (strictOverride ? "strict" : "consensus") : "none"
            ])
            if willOverride {
                let snapped = KnownPlates.shared.match(norm).map { _ in norm } ?? norm
                finalText = snapped
                finalConf = stacked.confidence
                finalRegion = region
            }
        } else {
            FileHandle.safeStderrWrite(
                "[Stacking] track=\(track.id) frames=\(track.stackFrames.count) composite=NIL (≤1 frame nebo empty result)\n"
                    .data(using: .utf8)!)
        }

        // Step 7 best-crop scoring — **log-only first week**, žádný commit-crop
        // override. Cíl: ověřit že compositeScore (sharpness × (1-glare) × area)
        // matchne lidský úsudek "lepší crop" na realných snapshotech. Po
        // validaci se score-driven crop choice promote v separate commitu.
        if track.stackFrames.count >= 2 {
            var scoredFrames: [(idx: Int, score: Float, sharp: Float, glare: Float, area: Float, conf: Float)] = []
            let workspaceArea = max(1.0, sourceSize.width * sourceSize.height)
            for (i, frame) in track.stackFrames.enumerated() {
                autoreleasepool {
                    let sharp = ImageMetrics.sharpness(frame.cgImage)
                    let glare = ImageMetrics.glareScore(frame.cgImage)
                    let frameArea = Float(frame.workBox.width * frame.workBox.height)
                    let workspaceSize = Float(frame.workSize.width * frame.workSize.height)
                    let areaNorm = min(1.0, frameArea / max(1, workspaceSize))
                    _ = workspaceArea  // currently unused, future: per-source-frame normalization
                    let score = ImageMetrics.compositeScore(sharpness: sharp, glare: glare, areaNorm: areaNorm)
                    scoredFrames.append((i, score, sharp, glare, areaNorm, frame.confidence))
                }
            }
            if let bestByScore = scoredFrames.max(by: { $0.score < $1.score }),
               let bestByConf = scoredFrames.max(by: { $0.conf < $1.conf }) {
                FileHandle.safeStderrWrite(
                    "[Stacking.score] track=\(track.id) stack=\(track.stackFrames.count) best-by-score=\(bestByScore.idx) (score=\(String(format: "%.2f", bestByScore.score)) sharp=\(String(format: "%.2f", bestByScore.sharp)) glare=\(String(format: "%.2f", bestByScore.glare)) area=\(String(format: "%.3f", bestByScore.area))) best-by-conf=\(bestByConf.idx) (conf=\(String(format: "%.2f", bestByConf.conf))) winner-used=conf\n"
                        .data(using: .utf8)!)
            }
        }

        // Foundation Models verification pro low-confidence commits — async
        // fire-and-forget. Verification výsledek loguje ale neovlivňuje tento
        // commit (sync byl by 1 s blokoval pipeline). Pokud LLM opraví plate,
        // bude použit v příštím commitu stejného tracku.
        if AppState.useFoundationModelsFlag.withLock({ $0 }),
           finalConf < 0.85,
           FoundationModelsVerifier.shared.isAvailable {
            let snapshotText = finalText
            let snapshotRegion = finalRegion.rawValue
            let snapshotConf = Double(finalConf)
            Task.detached {
                if let corrected = FoundationModelsVerifier.shared.verify(
                    plate: snapshotText, region: snapshotRegion, confidence: snapshotConf),
                   corrected != snapshotText {
                    FileHandle.safeStderrWrite(
                        "[FoundationModels] async correction: \(snapshotText) → \(corrected) (conf=\(String(format: "%.2f", snapshotConf)))\n"
                            .data(using: .utf8)!)
                }
            }
        }

        // Vehicle classification přes Apple Vision + CIAreaAverage. VehicleClassifier
        // dostává WIDER crop z raw pixel bufferu (3× větší box kolem plate bbox) —
        // workspace crop je tight kolem plate, car body nemusí být ve frame, sample
        // regiony by padaly na background / shadow.
        var vehicleType: String? = nil
        var vehicleColor: String? = nil
        if AppState.useVehicleClassificationFlag.withLock({ $0 }) {
            let wideCG: CGImage? = autoreleasepool {
                guard let pb = lastPixelBuffer else { return nil }
                let ci = CIImage(cvPixelBuffer: pb)
                let pbW = ci.extent.width, pbH = ci.extent.height
                // Expand plate bbox 4× horizontally, 3× vertically. Plate je
                // typicky v dolní 1/3 nárazníku, car body (kapota/grill/světla) je
                // NAD plate → asymmetric expansion upward. Clamp na frame bounds.
                // 3·ph (ne 6·ph) drží landscape aspect; 6·ph by při close-up plates
                // vyšel portrait → sampling regiony padly na horní partii = obloha.
                let pw = bbox.width, ph = bbox.height
                let cx = bbox.midX, cy = bbox.midY
                let widerW = min(pbW, pw * 4.0)
                let widerH = min(pbH, ph * 3.0)
                // Asymmetric: rozšíření nahoru (car body) víc než dolů (bumper/asfalt).
                // 70 % výšky expansion jde nahoru, 30 % dolů.
                let rawRect = CGRect(x: cx - widerW/2,
                                     y: cy - widerH * 0.7,
                                     width: widerW, height: widerH)
                                    .intersection(CGRect(x: 0, y: 0, width: pbW, height: pbH))
                guard !rawRect.isNull, rawRect.width > 100, rawRect.height > 60 else { return nil }
                // CIImage má BL origin, bbox je v TL source coords → flip y.
                let ciRect = CGRect(x: rawRect.minX, y: pbH - rawRect.maxY,
                                    width: rawRect.width, height: rawRect.height)
                let cropped = ci.cropped(to: ciRect)
                    .transformed(by: CGAffineTransform(translationX: -ciRect.minX, y: -ciRect.minY))
                return SharedCIContext.shared.createCGImage(cropped, from: cropped.extent)
            }
            if let cg = wideCG ?? crop?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let result = VehicleClassifier.shared.classify(image: cg)
                vehicleType = result.type
                vehicleColor = result.color
                FileHandle.safeStderrWrite(
                    "[PlatePipeline \(cameraName)] vehicle: type=\(result.type ?? "nil") color=\(result.color ?? "nil") typeConf=\(String(format: "%.2f", result.typeConfidence)) cropSize=\(cg.width)×\(cg.height)\(wideCG != nil ? " [WIDE]" : " [workspace fallback]")\n"
                        .data(using: .utf8)!)
            }
        }

        // **L-1 recent-history snap:** pokud `finalText` není v whitelistu,
        // ale stejná kamera viděla v posledních 30 min commit s L-1 fuzzy
        // match, snap na recent text. Recent commit už prošel validátorem,
        // takže fuzzy snap k němu je safer než k libovolnému textu.
        // Whitelist match má vždy higher priority.
        let committedText: String = {
            if KnownPlates.shared.match(finalText) != nil { return finalText }
            let cutoff = Date().addingTimeInterval(-30 * 60)
            for r in state.recents.items {
                guard r.cameraName == cameraName else { continue }
                guard r.timestamp > cutoff else { continue }
                guard r.plate != finalText else { continue }
                guard r.plate.count == finalText.count else { continue }
                if PlateTrack.isL1(r.plate, finalText) {
                    FileHandle.safeStderrWrite(
                        "[PlatePipeline \(cameraName)] L-1 recent-snap \(finalText) → \(r.plate) (matched commit id=\(r.id) \(Int(Date().timeIntervalSince(r.timestamp)))s ago)\n"
                            .data(using: .utf8)!)
                    return r.plate
                }
            }
            return finalText
        }()

        var rec = RecentDetection(
            id: state.recents.makeId(), timestamp: Date(),
            cameraName: cameraName,
            plate: committedText, region: finalRegion, confidence: finalConf,
            bbox: bbox, cropImage: crop
        )
        rec.vehicleType = vehicleType
        rec.vehicleColor = vehicleColor
        rec.snapshotPath = Store.shared.snapshotURL(for: rec).path
        state.recents.add(rec)

        // Triple-write persistence (SQLite WAL + JSONL + JPEG) + webhook.
        // Downstream (known match, parking session, webhook) používá `committedText`.
        let knownEntry = KnownPlates.shared.match(committedText)
        let isKnown = knownEntry != nil

        // Store je nonisolated — persist() heavy IO (HEIC encoding ~10-20 ms,
        // SQLite synchronous=FULL, JSONL append) běží v Task.detached na background
        // queue, neblokuje MainActor uprostřed průjezdu. Commit log + parking session
        // navazují až po dokončení persist (potřebují rowId pro audit korelaci).
        // **NSImage → CGImage konverze NA MainActor** před přechodem do Task.detached.
        // NSImage je AppKit typ s lazy backing store + main-thread expectations;
        // jeho `cgImage(forProposedRect:context:hints:)` na background může
        // crashnout / vrátit nil podle načítací cesty. CGImage je čistý
        // CoreGraphics value-type-compatible objekt safe pro thread crossing.
        let plateSafe = PlateText.canonicalize(rec.plate)
        let recCopy = rec
        let cropCG: CGImage? = crop?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let rawCropCG: CGImage? = rawCrop?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let finalTextCopy = committedText
        let cameraNameCopy = cameraName
        let stateRef = state
        Task.detached(priority: .utility) {
            let rowId = Store.shared.persist(rec: recCopy, isKnown: isKnown,
                                             cropCG: cropCG, rawCropCG: rawCropCG)
            FileHandle.safeStderrWrite(
                "[Commit] id=\(rowId) ts=\(Self.localTimestampString(from: recCopy.timestamp)) camera=\(recCopy.cameraName) plate=\(plateSafe) region=\(recCopy.region.rawValue) conf=\(String(format: "%.2f", recCopy.confidence)) known=\(isKnown)\n"
                    .data(using: .utf8)!)
            Audit.event("store_persist", [
                "id": rowId, "camera": recCopy.cameraName,
                "plate": plateSafe, "region": recCopy.region.rawValue,
                "confidence": Double(recCopy.confidence), "known": isKnown
            ])
            // Parking session — JEN pro whitelisted, navazuje na rowId persistence.
            if isKnown {
                if cameraNameCopy == "vjezd" {
                    Store.shared.openParkingSession(plate: finalTextCopy, at: recCopy.timestamp)
                } else if cameraNameCopy == "vyjezd" || cameraNameCopy == "výjezd" {
                    Store.shared.closeParkingSession(plate: finalTextCopy, at: recCopy.timestamp)
                }
            }
            // refreshStats AŽ PO persist (UI count odráží reálný DB stav,
            // ne stale pre-INSERT snapshot). Hop na MainActor protože
            // refreshStats mutuje @Published vars.
            await MainActor.run { stateRef.refreshStats() }
        }

        // Whitelisted plate → do allowedPasses bufferu (samostatná UI sekce).
        // Sync na MainActor — UI feed, žádný heavy IO.
        if isKnown {
            state.allowedPasses.add(rec)
        }

        // Gate open event — zelený banner „ZÁVORA OTEVŘENA" + webhook na relé.
        // markGateOpened() běží VŽDY (i bez webhookURL) — user potřebuje vizuální
        // feedback že se whitelist match stal, webhook je volitelný hardware side.
        // Fire/banner pro whitelist match na VJEZD (výjezd nepotřebuje otevření).
        // Pokud `webhookOnlyForKnown == false`, fire i bez whitelistu (user-choice).
        //
        // Re-trigger při stojícím autu: tracker odemkne committed track po
        // `recommitAfterSec` → další commit projde sem → banner + webhook znovu.
        // Uživatelem laděný "ZPOŽDĚNÍ" v horním banneru = `recommitDelaySec`.
        // Auto-fire pokud kamera má enabled Shelly device (vjezd / výjezd).
        // Výjezd disabled by default — user enable v Settings.
        let cameraHasShelly = state.shellyDevice(for: cameraName).enabled
        if cameraHasShelly && (!state.webhookOnlyForKnown || isKnown) {
            let intendedAction = intendedGateAction(for: knownEntry)
            let actualAction: GateAction = .openShort
            if intendedAction != actualAction {
                Audit.event("gate_action_shadow", [
                    "camera": cameraName,
                    "plate": committedText,
                    "track": track.id,
                    "would_action": intendedAction.auditTag,
                    "actual_action": actualAction.auditTag,
                    "isKnown": isKnown
                ])
            }
            if isKnown, knownEntry?.holdWhilePresent == true {
                startGateHoldShadow(plate: committedText, trackId: track.id)
            }
            Audit.event("barrier_open_attempt", [
                "camera": cameraName, "plate": committedText,
                "isKnown": isKnown,
                "intendedAction": intendedAction.auditTag,
                "actualAction": actualAction.auditTag,
                "holdWhilePresentShadow": knownEntry?.holdWhilePresent == true,
                "webhookURL": !state.webhookURL.isEmpty,
                "shellyBaseURL": !state.webhookShellyBaseURL.isEmpty,
                "webhookOnlyForKnown": state.webhookOnlyForKnown
            ])
            // Per-camera Shelly device — vjezd nebo výjezd. Pokud disabled
            // / no URL → no-relay path (banner only).
            let device = state.shellyDevice(for: cameraName)
            if !device.isUsable {
                state.markGateOpened(camera: cameraName)
            } else {
                // **Async fire:** banner zasvítí JEN po skutečném HTTP 2xx.
                // ALPR commit používá `.openShort` action (default 1 s pulse,
                // AGN2/AGN3 si zavře přes interní TCA). Per-plate `gateAction`
                // ve whitelistu by routilo `.openExtended` → 20 s drží (autobus).
                let snappedPlate = committedText
                let snappedCamera = cameraName
                let evId = "ALPR-\(rec.id)"
                let cfg = device.gateActionConfig()
                let action = actualAction
                let baseURL = device.baseURL
                let user = device.user
                let password = device.password
                Task { [weak state] in
                    let t0 = Date()
                    let result = await WebhookClient.shared.fireGateActionWithRetries(
                        action, baseURL: baseURL, user: user, password: password,
                        plate: snappedPlate, camera: snappedCamera,
                        config: cfg, eventId: evId)
                    let latencyMs = Int(Date().timeIntervalSince(t0) * 1000)
                    await MainActor.run {
                        state?.recordShellyResult(result, camera: snappedCamera, latencyMs: latencyMs)
                        if case .success = result {
                            let dur = state?.bannerDuration(for: action, camera: snappedCamera) ?? 5.0
                            state?.markGateOpened(camera: snappedCamera, duration: dur)
                        }
                    }
                }
            }
        }
    }

    private func intendedGateAction(for entry: KnownPlates.Entry?) -> GateAction {
        guard let raw = entry?.gateAction,
              GateAction(rawValue: raw) == .openExtended else {
            return .openShort
        }
        return .openExtended
    }

    private func startGateHoldShadow(plate: String, trackId: Int) {
        let cameraSnapshot = cameraName
        Audit.event("gate_hold_would_start", [
            "camera": cameraSnapshot,
            "plate": plate,
            "track": trackId,
            "mode": "shadow"
        ])
        Task { @MainActor [weak self] in
            let startedAt = Date()
            for beat in 1...60 {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let livePresent = self.state?.liveDetectionsByCamera[cameraSnapshot]?.contains { live in
                    PlateTrack.isL1(live.plate, plate)
                } ?? false
                let stillPresent = livePresent
                    || self.tracker.tracksMatching(text: plate, withinFrames: 20) > 0
                let age = Date().timeIntervalSince(startedAt)
                if stillPresent {
                    Audit.event("gate_hold_would_beat", [
                        "camera": cameraSnapshot,
                        "plate": plate,
                        "track": trackId,
                        "beat": beat,
                        "ageSec": Double(age),
                        "mode": "shadow"
                    ])
                } else {
                    Audit.event("gate_hold_would_stop", [
                        "camera": cameraSnapshot,
                        "plate": plate,
                        "track": trackId,
                        "reason": "track_lost",
                        "ageSec": Double(age),
                        "mode": "shadow"
                    ])
                    return
                }
            }
            Audit.event("gate_hold_would_force_stop", [
                "camera": cameraSnapshot,
                "plate": plate,
                "track": trackId,
                "reason": "safety_cap",
                "ageSec": 60,
                "mode": "shadow"
            ])
        }
    }

    private func fps(window: [Date]) -> Double {
        guard let first = window.first, let last = window.last,
              window.count >= 2 else { return 0 }
        let span = last.timeIntervalSince(first)
        return span > 0 ? Double(window.count - 1) / span : 0
    }

    // MARK: - Vrstva 5: delayed drop helpers

    /// Vyhledá NEJNOVĚJŠÍ qualifying prior commit pro delayed drop registration.
    /// `.lazy` zabrání alokaci mezilehlého pole; max projde celou recentCommits
    /// sekvenci, protože forenzně chceme nejnovější (ne první) match.
    fileprivate func latestQualifyingPrior(
        for candidateText: String,
        candidateCamera: String,
        now: Date
    ) -> RecentCommit? {
        recentCommits
            .lazy
            .filter { recent in
                guard recent.plate != candidateText else { return false }
                guard recent.cameraName == candidateCamera else { return false }
                let age = now.timeIntervalSince(recent.ts)
                return age >= 0 &&
                       age < self.delayedDropRecentWindow &&
                       recent.conf >= self.delayedDropHighConfThreshold &&
                       PlatePipeline.isLikelyFragmentMatch(candidateText, recent.plate)
            }
            .max { $0.ts < $1.ts }
    }

    /// Po 1.5s drop expired pending candidates. Žádný release path.
    fileprivate func evaluatePendingDrops() {
        let now = Date()
        var keep: [PendingDropCandidate] = []
        for c in pendingDropCandidates {
            guard now >= c.dropAfter else {
                keep.append(c)
                continue
            }
            Audit.event("pipeline_dedup_gate", [
                "camera": c.cameraName,
                "plate": c.bestText,
                "action": "drop",
                "reason": "stale-low-conf-fragment",
                "prior_plate": c.priorMatchPlate,
                "prior_conf": Double(c.priorMatchConf),
                "candidate_conf": Double(c.bestConf),
                "prior_age_ms": c.priorMatchAgeMs,
                "hold_ms": Int(c.dropAfter.timeIntervalSince(c.registeredAt) * 1000),
            ])
            // discarded — žádná persist do DB
        }
        pendingDropCandidates = keep
    }

    /// Fragment-match heuristika: L1 OR L2 OR ambiguous-glyph OR same-prefix-L3.
    /// Static — volá se z latestQualifyingPrior bez self capture.
    /// `nonisolated` aby šel volat z testů bez @MainActor wrap.
    nonisolated static func isLikelyFragmentMatch(_ a: String, _ b: String) -> Bool {
        if isLevenshtein1(a, b) || isLevenshtein2(a, b) { return true }
        let cmp = AmbiguousGlyphMatrix.compareWithAmbiguous(a, b)
        if cmp.editDistance >= 1, cmp.editDistance <= 2, cmp.allMismatchesAmbiguous {
            return true
        }
        // **Same-prefix-L3:**
        // - same length (eliminuje insertion/deletion)
        // - length >= 6 (vyloučí 5-char foreign plates s nahodným prefix collision)
        // - common prefix >= 3 (slabší L≥2 by mohl false-merge dvě reálná auta)
        // - levenshtein <= 3 podle existing helperu.
        //   Pozor: nejde o prostý počet rozdílných pozic.
        // Pro CZ plate `1AB2345` vs `1AB2978`: prefix `1AB` (≥3) + helper L≤3 → match.
        if a.count == b.count, a.count >= 6 {
            let prefixLen = zip(a, b).prefix(while: { $0 == $1 }).count
            if prefixLen >= 3 {
                let dist = levenshtein(a, b)
                if dist <= 3 { return true }
            }
        }
        return false
    }
}

/// Priorita regionů pro multi-candidate rescue — vyšší číslo = silnější match.
/// Free function (ne instance method) — closure v processingQueue ji volá bez self capture.
func regionScore(_ r: PlateRegion) -> Int {
    switch r {
    case .cz: return 5
    case .czElectric: return 4   // EL/EV format, specific CZ variant
    case .sk: return 3
    case .foreign: return 2
    case .czVanity: return 1
    case .unknown: return 0
    }
}

/// Fuzzy snap — pokud je `text` do Levenshtein-1 od nějaké known plate, vrátí
/// canonical text known plate. Jinak původní text.
///
/// Optimalizováno pro distance ≤ 1: same-length → Hamming ≤ 1 (jeden substituce);
/// length-diff 1 → single insertion/deletion. Distance ≥ 2 okamžitě odmítnuto.
/// Rychlejší než plný Levenshtein, hodí se pro per-frame pipeline.
func fuzzySnapToKnown(_ text: String, known: [String]) -> String {
    if known.contains(text) { return text }
    for k in known {
        if isLevenshtein1(text, k) { return k }
    }
    return text
}

/// Trim first/last char (často OCR phantom edge — extra "1" / leading bullet).
/// Pro core comparison v dedup logice. "5XY12345" → "SJ9141", "15XY1234" → "4SJ914".
/// Tato dvojice se pak porovná substring kontainmentem v dedup.
func stripEdges(_ s: String) -> String {
    guard s.count >= 4 else { return s }
    return String(s.dropFirst().dropLast())
}

func isLevenshtein1(_ a: String, _ b: String) -> Bool {
    let aChars = Array(a), bChars = Array(b)
    let la = aChars.count, lb = bChars.count
    let diff = abs(la - lb)
    if diff > 1 { return false }
    if la == lb {
        // Substitution ≤ 1 (0 = equal je taky valid "within Lev-1" — caller nemusí
        // pre-checkovat equality).
        var seenDiff = false
        for i in 0..<la {
            if aChars[i] != bChars[i] {
                if seenDiff { return false }
                seenDiff = true
            }
        }
        return true  // 0 nebo 1 substitution = within Lev-1
    }
    // One string is 1 shorter — check if inserting one char makes them equal.
    let (short, long) = la < lb ? (aChars, bChars) : (bChars, aChars)
    var i = 0, j = 0
    var skipped = false
    while i < short.count && j < long.count {
        if short[i] == long[j] {
            i += 1; j += 1
        } else {
            if skipped { return false }
            skipped = true
            j += 1  // skip one char in longer
        }
    }
    return true
}

/// Levenshtein distance ≤ 2 — používá se pro low-conf dedup gate v `commit()`.
/// Same-length only path optimalizovaný (substitutions count). Insertion/deletion
/// (length diff) také tolerován až do 2.
///
/// **Use case:** Vision občas vrátí ze stejného auta L-2 misread (např. F→1 +
/// 8→0 = 2 substitutions). L-1 dedup gate to nezachytí, low-conf gate to chytne.
func isLevenshtein2(_ a: String, _ b: String) -> Bool {
    let aChars = Array(a), bChars = Array(b)
    let la = aChars.count, lb = bChars.count
    let diff = abs(la - lb)
    if diff > 2 { return false }
    if la == lb {
        var diffs = 0
        for i in 0..<la where aChars[i] != bChars[i] {
            diffs += 1
            if diffs > 2 { return false }
        }
        return true
    }
    if la == 0 || lb == 0 {
        return max(la, lb) <= 2
    }
    // length diff 1 or 2 — full DP fallback (rare path, ~7-char strings = cheap).
    var prev = Array(0...lb)
    var cur = [Int](repeating: 0, count: lb + 1)
    for i in 1...la {
        cur[0] = i
        var rowMin = i
        for j in 1...lb {
            let cost = aChars[i-1] == bChars[j-1] ? 0 : 1
            cur[j] = min(prev[j] + 1, cur[j-1] + 1, prev[j-1] + cost)
            rowMin = min(rowMin, cur[j])
        }
        if rowMin > 2 { return false }  // early exit
        swap(&prev, &cur)
    }
    return prev[lb] <= 2
}

/// Sendable wrapper pro CVPixelBuffer — CF type je thread-safe (retain/release i
/// CVPixelBufferLockBaseAddress jsou atomic), ale CVBuffer není `Sendable` v Swift 6.
/// Obalujeme do class aby šel předat přes `processingQueue.async` closure.
final class PixelBufferBox: @unchecked Sendable {
    let pb: CVPixelBuffer
    init(_ pb: CVPixelBuffer) { self.pb = pb }
}

/// Plný Levenshtein O(n·m) — pro Vrstva 5 same-prefix-L3 check kde
/// `isLevenshtein1`/`isLevenshtein2` early-exit nestačí (potřebujeme přesnou
/// distanci pro porovnání s prahem 3).
func levenshtein(_ a: String, _ b: String) -> Int {
    let aChars = Array(a), bChars = Array(b)
    let m = aChars.count, n = bChars.count
    if m == 0 { return n }
    if n == 0 { return m }
    var prev = Array(0...n)
    var cur = [Int](repeating: 0, count: n + 1)
    for i in 1...m {
        cur[0] = i
        for j in 1...n {
            let cost = aChars[i-1] == bChars[j-1] ? 0 : 1
            cur[j] = min(prev[j] + 1, cur[j-1] + 1, prev[j-1] + cost)
        }
        (prev, cur) = (cur, prev)
    }
    return prev[n]
}

/// Jednoduchý atomic bool s try-set semantikou (CAS). Bez external deps.
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool = false
    /// Vrací `true` pokud byl flag 0→1 (uspěl v "lock"), `false` pokud už byl set.
    func trySet() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
    func reset() { lock.lock(); value = false; lock.unlock() }
}

struct LiveDetection: Equatable, Identifiable {
    let id = UUID()
    /// Axis-aligned enclosing bbox v source frame pixel coords — pro full-stream overlay
    /// (LiveOverlay nad ne-rotovaným videem).
    let bbox: CGRect
    /// Bbox v **rotated-crop pixel space** (top-left origin), zarovnaný s textem.
    /// Používá se pro RoiLiveOverlay: display-scale tento rect přímo, žádná další rotace.
    let workBox: CGRect
    /// Rozměry rotated cropu (axis-aligned bounding box po rotaci ROI). Musí sedět
    /// s `workBox` coord space.
    let workSize: CGSize
    let plate: String
    let confidence: Float
    let sourceWidth: CGFloat
    let sourceHeight: CGFloat
    let ts: Date
    /// Velocity vektor bbox middlepoint v source pixel/s. Umožňuje UI overlay
    /// extrapolovat aktuální pozici (Vision detekce + render lag ~100-150 ms).
    /// (0, 0) pokud jen 1 observation nebo nelze zjistit.
    var velocity: CGVector = .zero
    /// Velocity vektor v rotated-crop coords (workBox space) pro RoiLiveOverlay.
    var workVelocity: CGVector = .zero
}
