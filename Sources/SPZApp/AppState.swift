import Foundation
import SwiftUI
import os
import CoreVideo
import CoreGraphics

@MainActor
final class AppState: ObservableObject {
    @Published var cameras: [CameraConfig]
    @Published var activeCameraName: String
    @Published var recents = RecentBuffer(capacity: 10)
    /// Samostatný buffer pouze pro whitelisted (známé) SPZ. Zapis sem triggeruje
    /// gate webhook pokud kamera je VJEZD.
    @Published var allowedPasses = RecentBuffer(capacity: 10)
    /// Per-camera live detections (keyed by cameraName). Per-camera dict je nutné,
    /// aby se bbox každé kamery renderoval ve vlastním ROI coord space.
    @Published var liveDetectionsByCamera: [String: [LiveDetection]] = [:]
    /// Any-camera view pro fullstream overlay + „NEVIDÍM SPZ" gating. True pokud
    /// jakákoliv kamera aktuálně detekuje.
    var hasAnyLiveDetection: Bool { liveDetectionsByCamera.values.contains { !$0.isEmpty } }
    @Published var pipelineStats = PipelineStats()
    /// Zmrazené screenshoty per camera — když je hodnota non-nil, kalibrační
    /// editory (ROI selector, perspective sheets, 8-DOF) místo živého streamu
    /// pracují nad tímto snímkem. Use case: uživatel si vyfotí scénu s autem
    /// u brány a může pak v klidu nastavit ROI/perspektivu bez dalšího průjezdu.
    /// In-memory only (CVPixelBuffer není serializovatelný), nepersistuje se.
    @Published var frozenFrames: [String: CVPixelBuffer] = [:]
    /// Cache CGImage za každý zmrazený snímek pro UI render (RoiSelectorOverlay
    /// fullStreamStage). Klíč = cameraName, hodnota = pre-rendered CGImage.
    @Published var frozenFrameCGImages: [String: CGImage] = [:]
    /// Source URL zmrazeného snímku (UI label "Statický snímek: <name>").
    @Published var frozenFrameURLs: [String: URL] = [:]

    /// Nastaví zmrazený snímek pro kameru — načte z disku, převede na
    /// CVPixelBuffer + CGImage cache. Vrací true při úspěchu.
    @discardableResult
    func setFrozenFrame(name: String, fromURL url: URL) -> Bool {
        guard let pb = FrozenFrame.loadPixelBuffer(from: url) else { return false }
        frozenFrames[name] = pb
        frozenFrameCGImages[name] = FrozenFrame.makeCGImage(from: pb)
        frozenFrameURLs[name] = url
        return true
    }

    /// Smaže zmrazený snímek — editory zase pracují nad živým streamem.
    func clearFrozenFrame(name: String) {
        frozenFrames.removeValue(forKey: name)
        frozenFrameCGImages.removeValue(forKey: name)
        frozenFrameURLs.removeValue(forKey: name)
    }
    /// Přihlášen = přístup k Settings, SEZNAM whitelist tabu, přidávání/mazání.
    /// Session-only (reset na false při startu appky). Auto-logout po
    /// `idleLogoutMinutes` minutách nečinnosti.
    @Published var isLoggedIn: Bool = false {
        didSet { if isLoggedIn { lastActivityTs = Date() } }
    }
    /// Timestamp poslední admin aktivity — password verify, Settings interakce.
    /// Používá se pro auto-logout check.
    var lastActivityTs: Date = Date()
    /// Po kolika minutách nečinnosti se user automaticky odhlásí. 10 min default.
    @Published var idleLogoutMinutes: Int = 10 { didSet { scheduleSave() } }
    private var authIdleTimer: Timer?

    func markAdminActivity() {
        if isLoggedIn { lastActivityTs = Date() }
    }

    // Settings persisted in App Support/SPZ/settings.json
    // didSet plánuje debounced save — žádný disk write per keystroke
    @Published var webhookURL: String = "" { didSet { scheduleSave() } }
    @Published var webhookOnlyForKnown: Bool = true { didSet { scheduleSave() } }
    /// Shelly Pro 1 base URL (např. `http://192.0.2.163`). Pokud non-empty,
    /// **Shelly vjezd** — base URL pro Shelly Pro 1, který otevírá vjezdovou
    /// závoru. Pokud prázdný, fallback na legacy `webhookURL` pro back-compat.
    @Published var webhookShellyBaseURL: String = "" { didSet { scheduleSave() } }
    /// Délka pulse pro `.openShort` v sekundách → Shelly toggle_after.
    @Published var webhookPulseShortSec: Double = 1.0 { didSet { scheduleSave() } }
    /// Délka pulse pro `.openExtended` (autobus) v sekundách.
    @Published var webhookPulseExtendedSec: Double = 20.0 { didSet { scheduleSave() } }
    /// Re-trigger interval pro `.openHoldBeat` keep-alive (auto stojí v záboru).
    @Published var webhookKeepAliveBeatSec: Double = 3.0 { didSet { scheduleSave() } }
    /// Vjezd master enable — když OFF, ALPR/UI/webUI nevolá fire (no-relay path).
    @Published var shellyVjezdEnabled: Bool = true { didSet { scheduleSave() } }
    /// Shelly auth — username (typicky `admin`, fixed na Pro Gen 2 firmware).
    @Published var shellyVjezdUser: String = "admin" { didSet { scheduleSave() } }
    /// Shelly auth — password. Plaintext v `settings.json` (perm 0600).
    /// URLSession ho injektuje do request přes URL userinfo + responde na 401
    /// challenge (Basic / Digest auto-detect).
    @Published var shellyVjezdPassword: String = "" { didSet { scheduleSave() } }

    /// **Shelly výjezd** — druhý relé device pro výjezdovou závoru. Default
    /// disabled (single-gate setup je standard); user enable v Settings.
    @Published var shellyVyjezdEnabled: Bool = false { didSet { scheduleSave() } }
    @Published var shellyVyjezdBaseURL: String = "" { didSet { scheduleSave() } }
    @Published var shellyVyjezdUser: String = "admin" { didSet { scheduleSave() } }
    @Published var shellyVyjezdPassword: String = "" { didSet { scheduleSave() } }
    @Published var shellyVyjezdPulseShortSec: Double = 1.0 { didSet { scheduleSave() } }
    @Published var shellyVyjezdPulseExtendedSec: Double = 20.0 { didSet { scheduleSave() } }
    @Published var shellyVyjezdKeepAliveBeatSec: Double = 3.0 { didSet { scheduleSave() } }

    /// Aktivní base URL pro Shelly RPC (vjezd). Back-compat property — pokud
    /// nový `shellyVjezdEnabled=false` nebo URL prázdný, vrátí legacy webhookURL.
    var gateBaseURL: String {
        if !webhookShellyBaseURL.isEmpty { return webhookShellyBaseURL }
        return webhookURL
    }

    /// Per-camera Shelly device info — used by ALPR commit, manual buttons,
    /// webUI, settings UI. `enabled && !baseURL.isEmpty` znamená device ready
    /// k volání. Auth fields jdou jako URL userinfo (URLSession 401 challenge).
    struct ShellyDeviceSnapshot {
        let enabled: Bool
        let baseURL: String
        let user: String
        let password: String
        let pulseShortSec: Double
        let pulseExtendedSec: Double
        let keepAliveBeatSec: Double

        var isUsable: Bool { enabled && !baseURL.isEmpty }

        func gateActionConfig() -> GateActionConfig {
            GateActionConfig(
                pulseShortSec: pulseShortSec,
                pulseExtendedSec: pulseExtendedSec,
                keepAliveBeatSec: keepAliveBeatSec
            )
        }
    }

    /// Vrátí snapshot Shelly konfigurace pro danou kameru. `camera` je `vjezd`
    /// nebo `vyjezd`/`výjezd`. Neznámá kamera → vjezd snapshot (back-compat).
    func shellyDevice(for camera: String) -> ShellyDeviceSnapshot {
        let isVyjezd = camera == "vyjezd" || camera == "výjezd"
        if isVyjezd {
            return ShellyDeviceSnapshot(
                enabled: shellyVyjezdEnabled,
                baseURL: shellyVyjezdBaseURL,
                user: shellyVyjezdUser,
                password: shellyVyjezdPassword,
                pulseShortSec: shellyVyjezdPulseShortSec,
                pulseExtendedSec: shellyVyjezdPulseExtendedSec,
                keepAliveBeatSec: shellyVyjezdKeepAliveBeatSec
            )
        }
        return ShellyDeviceSnapshot(
            enabled: shellyVjezdEnabled,
            baseURL: webhookShellyBaseURL,
            user: shellyVjezdUser,
            password: shellyVjezdPassword,
            pulseShortSec: webhookPulseShortSec,
            pulseExtendedSec: webhookPulseExtendedSec,
            keepAliveBeatSec: webhookKeepAliveBeatSec
        )
    }

    /// True pokud vjezd device má scenario-routed Shelly URL (aktivuje
    /// fireGateAction místo legacy fireOnce).
    var gateScenariosEnabled: Bool {
        !webhookShellyBaseURL.isEmpty
    }

    /// Snapshot vjezd config pro back-compat call sites. Nový kód volá
    /// `shellyDevice(for:).gateActionConfig()`.
    func gateActionConfigSnapshot() -> GateActionConfig {
        shellyDevice(for: "vjezd").gateActionConfig()
    }

    // Capture rate control (informational; native pipeline dekóduje všechny
    // framy, které kamera pošle — slouží jen jako hint pro UI FPS displej).
    @Published var captureRateAuto: Bool = true { didSet { scheduleSave() } }
    @Published var captureFpsManual: Double = 10.0 { didSet { scheduleSave() } }
    // Detection rate control (PlatePipeline poll FPS)
    @Published var detectionRateAuto: Bool = true { didSet { scheduleSave() } }
    @Published var detectionFpsManual: Double = 10.0 { didSet { scheduleSave() } }
    /// Povolit **značky na přání** (8 znaků). OFF default — false positives v busy scéně.
    @Published var allowVanityPlates: Bool = false { didSet { scheduleSave() } }
    /// Povolit **cizí značky** (DE/AT/PL/…): formát "AB-CD 1234", min 5 alfanum + digit.
    /// Default ON — běžně užitečné pro CZ hranice, false-positive risk nižší než u vanity
    /// protože vyžaduje letter prefix + separator + digit uvnitř.
    @Published var allowForeignPlates: Bool = true { didSet { scheduleSave() } }
    /// Min. výška Vision observation jako zlomek výšky rotated cropu — pod touto
    /// hranicí se detekce zahodí (filtruje drobné texty na pozadí, cedulky, okna).
    /// 0.05 default (≈ plate znak 55 px při cropu ~1100 px). Range 0.02–0.25.
    @Published var ocrMinObsHeightFraction: Double = 0.05 { didSet { scheduleSave() } }
    /// Sekundy absence (mimo záběr) vyžadované pro opakovanou detekci stejné SPZ.
    /// Brání spam-commitu plate držené v záběru. Range 3–300 s.
    @Published var recommitDelaySec: Double = 15.0 { didSet { scheduleSave() } }

    // MARK: - Noční pauza (gate closed window)
    /// Časová pauza detekce — během window OCR / tracker / commit pipeline úplně
    /// vypnutá (RTSP stream + preview ale běží dál pro vizuální monitoring).
    /// Use case: brána se mechanicky uzavře (modrá vjezd brána zavřená 23:00–05:00),
    /// nemá smysl detekovat / fire webhook ani plnit DB false positive shadows.
    @Published var nightPauseEnabled: Bool = false { didSet { scheduleSave() } }
    /// Hodina začátku pauzy (0–23). Default 23 = od 23:00.
    @Published var nightPauseStartHour: Int = 23 { didSet { scheduleSave() } }
    /// Hodina konce pauzy (0–23). Default 5 = do 05:00.
    /// Pokud `start > end`, window přechází přes půlnoc (23:00 → 05:00).
    @Published var nightPauseEndHour: Int = 5 { didSet { scheduleSave() } }

    /// True pokud aktuální čas (`now`) spadá do nightPause window. Hodinová
    /// granularita — wraparound přes půlnoc support (23 → 5 znamená 23:00–04:59).
    func isInNightPause(at now: Date = Date()) -> Bool {
        guard nightPauseEnabled else { return false }
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        let s = max(0, min(23, nightPauseStartHour))
        let e = max(0, min(23, nightPauseEndHour))
        if s == e { return false }  // window 0 hodin = vypnuto
        if s < e {
            // Same-day window (např. 9 → 17): pause během [s, e).
            return hour >= s && hour < e
        }
        // Wraparound přes půlnoc (např. 23 → 5): pause je [s, 24) ∪ [0, e).
        return hour >= s || hour < e
    }
    /// Vision recognition mode. `false` = `.accurate` (~7 fps per camera, vyšší accuracy),
    /// `true` = `.fast` (~14 fps, ~10% nižší accuracy na stylizovaných/tilted platách).
    /// Apple Vision framework má interní globální serial queue pro VNRequests, takže
    /// concurrent dispatch na app straně neumožňuje překročit per-mode ceiling;
    /// jediná cesta k vyššímu fps je volba rychlejšího modelu.
    @Published var ocrFastMode: Bool = false { didSet { scheduleSave() } }
    /// Dual-pass OCR — spustí paralelně VNRecognizeTextRequest revision3 + revision2
    /// na každém framu. Dvě různé verze Apple textového modelu chytnou různé
    /// edge cases (rev2 lepší na styling font, rev3 na noisy pozadí). Accuracy
    /// +2–4 % na marginal plates, ANE load ~2× (využije víc HW kapacity).
    /// Default vypnuto; jen pro .accurate mode (fast režim je lightweight).
    @Published var ocrDualPassEnabled: Bool = false { didSet { scheduleSave() } }
    /// Tight enhanced retry čte plate-local výřez kolem pass-1 lokace. Default ON:
    /// pass 1 lokalizuje, pass 2 má vyšší váhu jako skutečný reader.
    @Published var enhancedRetryEnabled: Bool = true { didSet { scheduleSave() } }
    @Published var enhancedRetryThreshold: Double = 0.95 { didSet { scheduleSave() } }
    @Published var enhancedVoteWeight: Double = 1.75 { didSet { scheduleSave() } }
    @Published var baseVoteWeightWhenEnhancedOverlap: Double = 0.5 { didSet { scheduleSave() } }
    @Published var enhancedRetryMaxBoxes: Int = 2 { didSet { scheduleSave() } }
    @Published var useSecondaryEngine: Bool = false {
        didSet {
            let newValue = useSecondaryEngine
            AppState.useSecondaryEngineFlag.withLock { $0 = newValue }
            scheduleSave()
        }
    }
    @Published var crossValidatedVoteWeight: Double = 2.0 { didSet { scheduleSave() } }
    nonisolated static let useSecondaryEngineFlag = OSAllocatedUnfairLock<Bool>(initialState: false)
    /// Fused Metal kernel pro rotate + perspective + quad crop + NV12→BGRA conversion
    /// v jednom GPU compute dispatch. Default OFF — Core Image chain je primary path
    /// (proven, Metal-backed internally). Kernel je ~0.5 ms/frame save při 15 fps ×
    /// 2 kamery = ~15 ms/s CPU save. Zapnutí je experimental — pokud výstup vypadá
    /// špatně (color shift, wrong orient), vypnout. Implementace:
    /// `Vision/PlateTransformKernel.swift` + `Resources/PlateTransform.metal`.
    @Published var useMetalKernel: Bool = false {
        didSet {
            let newValue = useMetalKernel
            AppState.useMetalKernelFlag.withLock { $0 = newValue }
            scheduleSave()
        }
    }
    /// Apple Intelligence on-device LLM verification low-confidence plates (macOS 26+).
    /// `FoundationModelsVerifier.shared.verify(...)` se zavolá v PlatePipeline.commit()
    /// pokud confidence < 0.85. Inference ~200–500 ms na ANE, default OFF kvůli latency.
    @Published var useFoundationModelsVerification: Bool = false {
        didSet {
            let newValue = useFoundationModelsVerification
            AppState.useFoundationModelsFlag.withLock { $0 = newValue }
            scheduleSave()
        }
    }
    nonisolated static let useFoundationModelsFlag = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Fáze 2.1: VNDetectRectanglesRequest pre-filter. Před zařazením Vision text
    /// observation do tracker voting ověří, zda její bbox spadá do plate-shape
    /// rectangle (aspect 2.5–7:1). Filtruje false positives z okolních nápisů
    /// (VCHOD, FASE). Opt-in, default OFF.
    @Published var useRectanglePrefilter: Bool = false {
        didSet {
            let newValue = useRectanglePrefilter
            AppState.useRectanglePrefilterFlag.withLock { $0 = newValue }
            scheduleSave()
        }
    }
    nonisolated static let useRectanglePrefilterFlag = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Fáze 2.4 pivot: Apple Vision VNClassifyImage vehicle type detection + CIAreaAverage
    /// color extraction. Enrichuje RecentDetection s vehicle_type + vehicle_color při commit.
    /// Firmware-independent náhrada za VIGI Smart Event (blocked na C250).
    /// ~10ms per commit overhead na ANE. Default OFF.
    @Published var useVehicleClassification: Bool = false {
        didSet {
            let newValue = useVehicleClassification
            AppState.useVehicleClassificationFlag.withLock { $0 = newValue }
            scheduleSave()
        }
    }
    nonisolated static let useVehicleClassificationFlag = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Fáze D: Auto-perspective přes VNDetectRectangles. Per-frame detekuje plate
    /// quadrangle, aplikuje CIPerspectiveCorrection s detekovanými 4 rohy → rectified
    /// plate crop bez manuální kalibrace. Replaces user-drawn perspective když ON.
    /// Default OFF dokud user nevyzkouší — fallback je existing user quad.
    @Published var useAutoPerspective: Bool = false {
        didSet {
            let newValue = useAutoPerspective
            AppState.useAutoPerspectiveFlag.withLock { $0 = newValue }
            scheduleSave()
        }
    }
    nonisolated static let useAutoPerspectiveFlag = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// **Plate super-resolution (Swin2SR ONNX)** — master kill-switch.
    /// **DISABLED:** ONNX runtime + CoreML EP combination eskaluje RSS na 50+ GB při
    /// production traffic (per-shape compile cache + arena leak). Plan B (AWB +
    /// Lanczos 3-lobe) je default snapshot enhancement — žádný SR.
    @Published var usePlateSuperResolution: Bool = false {
        didSet {
            let newValue = usePlateSuperResolution
            AppState.usePlateSuperResolutionFlag.withLock { $0 = newValue }
            if !newValue { PlateSRCache.shared.clear() }
            scheduleSave()
        }
    }
    nonisolated static let usePlateSuperResolutionFlag = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Internal: snapshot path SR. Master toggle override-uje.
    /// DISABLED — viz `usePlateSuperResolution`.
    @Published var usePlateSuperResolutionForSnapshots: Bool = false {
        didSet {
            let newValue = usePlateSuperResolutionForSnapshots
            AppState.usePlateSRForSnapshotsFlag.withLock { $0 = newValue }
            scheduleSave()
        }
    }
    nonisolated static let usePlateSRForSnapshotsFlag = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Internal: OCR shadow mode (log-only, NIKDY accept).
    /// DISABLED — viz `usePlateSuperResolution`.
    @Published var usePlateSuperResolutionForOCRShadow: Bool = false {
        didSet {
            let newValue = usePlateSuperResolutionForOCRShadow
            AppState.usePlateSRForOCRShadowFlag.withLock { $0 = newValue }
            scheduleSave()
        }
    }
    nonisolated static let usePlateSRForOCRShadowFlag = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Internal: live OCR candidate branch (Fáze B2). **Default OFF** dokud shadow
    /// metrics neukážou benefit — viz `~/.claude/plans/poradne-to-cele-promysli-joyful-biscuit.md`.
    @Published var usePlateSuperResolutionForOCR: Bool = false {
        didSet {
            let newValue = usePlateSuperResolutionForOCR
            AppState.usePlateSRForOCRFlag.withLock { $0 = newValue }
            scheduleSave()
        }
    }
    nonisolated static let usePlateSRForOCRFlag = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// OCR shadow sample rate — deterministic per (cameraID, trackID, cropFingerprint).
    /// 0.25 = 25% commit calls inkludované v shadow set.
    @Published var plateSuperResolutionOCRShadowSampleRate: Double = 0.25 {
        didSet {
            let newValue = plateSuperResolutionOCRShadowSampleRate
            AppState.plateSRShadowRateFlag.withLock { $0 = newValue }
            scheduleSave()
        }
    }
    nonisolated static let plateSRShadowRateFlag = OSAllocatedUnfairLock<Double>(initialState: 0.25)

    /// Post-SR unsharp cap — Swin2SR může být dost ostrý sám o sobě, halo risk po
    /// dalším sharpen. Default OFF, enable jen pokud A/B confirms benefit.
    @Published var usePlateSRPostSharpening: Bool = false {
        didSet {
            let newValue = usePlateSRPostSharpening
            AppState.usePlateSRPostSharpenFlag.withLock { $0 = newValue }
            scheduleSave()
        }
    }
    nonisolated static let usePlateSRPostSharpenFlag = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Dev logging — verbose per-frame trace celého detection flow pro debugging.
    /// Logs: pollTick + OCR brightness + auto-perspective + observations + normalizer
    /// pass + tracker updates + commit decisions. VYPNOUT v produkci (log IO ~20 MB/h).
    @Published var devLogging: Bool = false {
        didSet {
            let newValue = devLogging
            AppState.devLoggingFlag.withLock { $0 = newValue }
            scheduleSave()
        }
    }
    nonisolated static let devLoggingFlag = OSAllocatedUnfairLock<Bool>(initialState: false)
    /// Nonisolated pro volání z background threads (Vision callback, tracker update atd.).
    nonisolated static func devLog(_ msg: @autoclosure () -> String) {
        guard devLoggingFlag.withLock({ $0 }) else { return }
        FileHandle.safeStderrWrite("[DEV] \(msg())\n".data(using: .utf8)!)
    }

    /// Fáze 6: Unseen-plate alerter — daily scan jestli některá known plate nebyla
    /// spatřena déle než N dní → log (+ future: webhook/notification). Default OFF.
    @Published var unseenPlateAlertsEnabled: Bool = false { didSet { scheduleSave() } }
    /// Threshold v dnech. Default 30 (měsíční neaktivita → alert).
    @Published var unseenPlateAlertDays: Int = 30 { didSet { scheduleSave() } }
    /// Nonisolated snapshot `useMetalKernel` — čtený z OCR workerů bez dotyku
    /// na @MainActor. Updatovaný z didSet vlastníka (AppState instance).
    nonisolated static let useMetalKernelFlag = OSAllocatedUnfairLock<Bool>(initialState: false)

    // ===== Tracker advanced params =====
    /// IoU threshold pro match existujícího tracku. < → snadnější změna pozice mezi framy
    /// (rychlý pohyb), > → stabilnější ale citlivější na okamžitý IoU-miss. Range 0.1–0.7.
    @Published var trackerIouThreshold: Double = 0.3 { didSet { scheduleSave() } }
    /// Max počet framů bez detekce, než je track prohlášen za lost (cca /detectFps = s).
    @Published var trackerMaxLostFrames: Int = 10 { didSet { scheduleSave() } }
    /// Min framů vidět plate než commit. Malá = krátké průjezdy; vyšší = robustnost.
    @Published var trackerMinHitsToCommit: Int = 2 { didSet { scheduleSave() } }
    /// Počet framů, po kterém se commit vynutí (track stále v záběru).
    @Published var trackerForceCommitAfterHits: Int = 6 { didSet { scheduleSave() } }
    /// Min počet shodných hlasů pro vítězný text v multi-frame voting.
    @Published var trackerMinWinnerVotes: Int = 3 { didSet { scheduleSave() } }
    /// Podíl všech hlasů, který musí vítěz mít (0.0–1.0). Výš = přísnější consensus.
    @Published var trackerMinWinnerVoteShare: Double = 0.65 { didSet { scheduleSave() } }
    /// Minimální šířka plate bbox jako zlomek workspace width pro commit.
    /// 0 = disabled (commit anytime), 0.08 = plate ≥ 8 % workspace width (car closer).
    /// User-tunable pro "auto musi byt blíže" gate — chrání před snapshotem kdy
    /// je auto ještě daleko a plate je málo detailní.
    @Published var trackerMinPlateWidthFraction: Double = 0.09 { didSet { scheduleSave() } }
    /// Safety multiplier: pokud track.hits ≥ forceCommit × tohle, commit i při
    /// malé plate (LOST path pořád garantuje snapshot). 0 = disable safety (pouze
    /// LOST commits při malé plate).
    @Published var trackerMinPlateWidthSafetyMult: Double = 3.0 { didSet { scheduleSave() } }

    // ===== Úložiště retention =====
    /// Kolik dní uchovávat snapshots JPEG. 0 = nekonečno.
    @Published var snapshotRetentionDays: Int = 30 { didSet { scheduleSave() } }
    /// Max počet snapshots (FIFO ořez starých). 0 = nekonečno.
    @Published var snapshotRetentionMaxCount: Int = 5000 { didSet { scheduleSave() } }

    // ===== Webhook =====
    /// Počet retry při selhání webhooku. 0 = fire-and-forget, žádný retry.
    @Published var webhookRetryCount: Int = 3 { didSet { scheduleSave() } }
    /// Timeout HTTP requestu v ms. Range 500–10000.
    @Published var webhookTimeoutMs: Int = 2000 { didSet { scheduleSave() } }

    // ===== Webové UI (remote control z prohlížeče na LAN) =====
    /// Zapne embedded HTTPS server (port `webUIPort`). Self-signed TLS cert
    /// generovaný při prvním startu. Basic Auth `admin` + user-defined silné heslo.
    @Published var webUIEnabled: Bool = false { didSet {
        scheduleSave()
        if webUIEnabled {
            WebServer.shared.bind(state: self)
            WebServer.shared.start(port: UInt16(webUIPort))
        } else { WebServer.shared.stop() }
    } }
    @Published var webUIPort: Int = 22224 { didSet {
        scheduleSave()
        if webUIEnabled {
            WebServer.shared.bind(state: self)
            WebServer.shared.start(port: UInt16(webUIPort))
        }
    } }
    /// Heslo pro Basic Auth webUI. Prázdný default → `WebServer.start()` blokuje
    /// start dokud user nenastaví heslo přes Settings → Síť. Existing installs
    /// s legacy hodnotou v settings.json načtou hodnotu (backward compat).
    @Published var webUIPassword: String = "" { didSet { scheduleSave() } }
    /// Rate limit na failed auth attempts — po 5 špatných pokusech IP na 5 min
    /// ban. Brání brute-force přes firemní LAN. Default on.
    @Published var webUIRateLimitEnabled: Bool = true { didSet { scheduleSave() } }
    /// IP whitelist (CIDR ranges, comma-separated, např. "192.168.0.0/24, 10.0.0.0/8").
    /// Prázdné = všechny zdrojové IP povolené (legacy behavior). Pokud vyplněné,
    /// pouze IP match-ující některý CIDR dostanou odpověď; ostatní 403.
    @Published var webUIAllowedCIDRs: String = "" { didSet { scheduleSave() } }

    // ===== Idle režim (úspora CPU / baterie) =====
    /// Když zapnutý, app po `idleAfterSec` bez detekce spadne na 1 fps
    /// OCR polling. Native decoder běží nezávisle (všechny framy do pool).
    /// Jakmile Vision cokoliv detekuje, okamžitě se vrátí na plnou rychlost.
    @Published var idleModeEnabled: Bool = false { didSet { scheduleSave() } }
    /// Po kolika sekundách bez detekce se přepne do idle režimu.
    @Published var idleAfterSec: Double = 2.0 { didSet { scheduleSave() } }
    /// Cílová OCR fps během úsporného režimu. Default 1 fps. Range 0.5–5 fps.
    /// Pro 1 fps = poll interval 1 s mezi OCR ticky když je scéna idle (no motion + no burst).
    /// Hodnota se respektuje **jen** pokud `idleModeEnabled == true`.
    @Published var idleDetectionFps: Double = 1.0 { didSet { scheduleSave() } }
    /// Per-camera timestamp poslední Vision aktivity (jakékoliv readings, nejen
    /// commit). CameraManager čte pro rozhodování o idle mode.
    @Published var lastVisionActivityTs: [String: Date] = [:]

    func markVisionActivity(for cameraName: String) {
        lastVisionActivityTs[cameraName] = Date()
    }

    // ===== Manuální průjezdy =====
    /// Max počet uložených manuálních průjezdů (fullscreen fotky). FIFO prune.
    @Published var manualPassesMaxCount: Int = 200 { didSet { scheduleSave() } }
    /// Platnost denního vjezdu přidaného z ManualControlBaru (v hodinách).
    /// Po této době se entry z whitelistu automaticky smaže.
    @Published var dailyPassExpiryHours: Int = 24 { didSet { scheduleSave() } }
    /// Lifetime counter kolikrát bylo přidáno denní oprávnění (přes
    /// AddDailyPassSheet). Inkrementuje se při každém add — i pokud SPZ
    /// už v whitelistu byla (protože je to stále akt přidělení oprávnění).
    @Published var dailyPassesAddedTotal: Int = 0 { didSet { scheduleSave() } }
    private var saveTimer: Timer?
    /// WAL checkpoint + snapshots prune timer — 5 min cadence.
    /// Bez tohoto SQLite WAL rostl donekonečna (checkpoint() v Store byl nepoužitý).
    private var maintenanceTimer: Timer?

    // Stats — od startu i celkové (z DB)
    @Published var totalToday: Int = 0
    @Published var totalAll: Int = 0

    /// **Vjezd gate state** — banner timestamp + duration + last Shelly response
    /// summary. Per-camera (vyjezd siblings níže).
    @Published var gateOpenEventAt: Date? = nil
    @Published var gateOpenDurationSec: TimeInterval = 5.0
    @Published var lastShellySummary: String = ""
    @Published var lastShellyOK: Bool = false
    @Published var lastShellyAt: Date? = nil

    /// **Výjezd gate state** — duplicitní pro druhý Shelly device.
    @Published var gateOpenEventAtVyjezd: Date? = nil
    @Published var gateOpenDurationSecVyjezd: TimeInterval = 5.0
    @Published var lastShellySummaryVyjezd: String = ""
    @Published var lastShellyOKVyjezd: Bool = false
    @Published var lastShellyAtVyjezd: Date? = nil

    /// Voláno ze všech míst, kde se fire() webhooku provede (auto commit
    /// v pipeline, manuální OTEVŘÍT button, test fire v Settings, webUI).
    /// `camera` určí, do kterých polí se uloží stav (vjezd / vyjezd).
    /// `duration` = banner timeline (sync s real gate-open timerem).
    func markGateOpened(camera: String = "vjezd", duration: TimeInterval = 5.0) {
        let isVyjezd = camera == "vyjezd" || camera == "výjezd"
        if isVyjezd {
            gateOpenEventAtVyjezd = Date()
            gateOpenDurationSecVyjezd = duration
        } else {
            gateOpenEventAt = Date()
            gateOpenDurationSec = duration
        }
    }

    /// Banner okamžitě zhasnout — volá se po `.closeRelease` / hold stop.
    func markGateClosed(camera: String = "vjezd") {
        let isVyjezd = camera == "vyjezd" || camera == "výjezd"
        if isVyjezd { gateOpenEventAtVyjezd = nil }
        else { gateOpenEventAt = nil }
    }

    /// Stručné encode `WebhookResult` na human-readable string pro UI display.
    /// `camera` určí cílové pole (vjezd / vyjezd).
    func recordShellyResult(_ result: WebhookResult, camera: String = "vjezd",
                            latencyMs: Int? = nil) {
        let summary = Self.shellySummary(result, latencyMs: latencyMs)
        let ok: Bool = { if case .success = result { return true } else { return false } }()
        let isVyjezd = camera == "vyjezd" || camera == "výjezd"
        if isVyjezd {
            lastShellyAtVyjezd = Date()
            lastShellyOKVyjezd = ok
            lastShellySummaryVyjezd = summary
        } else {
            lastShellyAt = Date()
            lastShellyOK = ok
            lastShellySummary = summary
        }
    }

    nonisolated static func shellySummary(_ result: WebhookResult,
                                           latencyMs: Int?) -> String {
        switch result {
        case .success(let status):
            if let l = latencyMs { return "\(status) · \(l) ms" }
            return "\(status) OK"
        case .httpError(let s): return "HTTP \(s)"
        case .rejectedBySSRF: return "SSRF blokováno"
        case .rateLimited: return "rate-limit"
        case .networkError: return "síť · timeout"
        case .redirectBlocked: return "redirect blok."
        }
    }

    /// Banner duration podle gate action a kamery — používá per-camera Shelly
    /// pulse settings. Hold = 24 h horizon (markGateClosed je release path).
    func bannerDuration(for action: GateAction, camera: String = "vjezd") -> TimeInterval {
        let dev = shellyDevice(for: camera)
        switch action {
        case .openShort: return dev.pulseShortSec
        case .openExtended: return dev.pulseExtendedSec
        case .openHoldStart, .openHoldBeat: return 86_400
        case .closeRelease: return 0
        }
    }

    private static func appSupportSPZ() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("SPZ", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }

    private let configURL: URL = {
        AppState.appSupportSPZ().appendingPathComponent("cameras.json")
    }()

    private let settingsURL: URL = {
        AppState.appSupportSPZ().appendingPathComponent("settings.json")
    }()

    init() {
        // Seed admin password při prvním startu.
        _ = Auth.shared
        let loaded = AppState.loadFromDisk(at: configURL) ?? AppState.defaultCameras()
        self.cameras = loaded
        self.activeCameraName = loaded.first?.name ?? "vyjezd"
        loadSettings()
        // Načti posledních 10 commit rows z SQLite → sekce Průjezdy nebude prázdná
        // po restartu appky. DB je single source of truth.
        let recentRows = Store.shared.queryDetections(limit: 10)
        recents.seed(recentRows)
        // AllowedPasses — jen známá auta (whitelist match).
        let allowedRows = recentRows.filter { KnownPlates.shared.match($0.plate) != nil }
        allowedPasses.seed(allowedRows)
        refreshStats()
        startMaintenanceTimer()
    }

    deinit {
        // Bez explicitního invalidate mohl orphan Timer (authIdleTimer,
        // saveTimer, camerasSaveTimer, maintenanceTimer) fire do closures
        // které držely `[weak self]` — bez crashe, ale zbytečná práce.
        // SwiftUI @StateObject může AppState reinit v preview / hot-reload.
        authIdleTimer?.invalidate()
        maintenanceTimer?.invalidate()
        saveTimer?.invalidate()
        camerasSaveTimer?.invalidate()
    }

    /// Spouští periodickou údržbu DB + snapshots každých 5 min.
    private func startMaintenanceTimer() {
        maintenanceTimer?.invalidate()
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard self != nil else { return }
            Task { @MainActor in
                Store.shared.periodicCheckpoint()
                Store.shared.pruneSnapshotsNow()
                Store.shared.pruneManualPassesNow()
                // Expirované denní vjezdy fyzicky smazat z whitelistu.
                KnownPlates.shared.pruneExpired()
            }
        }
        Store.shared.pruneSnapshotsNow()
        Store.shared.pruneManualPassesNow()
        KnownPlates.shared.pruneExpired()

        // Auto-logout watcher — každých 30 s kontroluje jestli lastActivityTs
        // leží víc než `idleLogoutMinutes` zpět; pokud ano a user je přihlášen,
        // logout. Session stateless design znamená, že jediné co zmizí je
        // `isLoggedIn` flag → UI se automaticky skryje.
        authIdleTimer?.invalidate()
        authIdleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isLoggedIn else { return }
                let idleSec = Date().timeIntervalSince(self.lastActivityTs)
                if idleSec > Double(self.idleLogoutMinutes) * 60 {
                    self.isLoggedIn = false
                    FileHandle.safeStderrWrite(
                        "[Auth] auto-logout after \(Int(idleSec))s idle\n".data(using: .utf8)!)
                }
            }
        }
    }

    func refreshStats() {
        totalToday = Store.shared.countToday()
        totalAll = Store.shared.countAll()
    }

    /// Používáme `decodeIfPresent` místo synthesized Codable — takže když přidáme nové
    /// klíče, starší settings.json (bez nich) NERUINUJE load. Bez tohoto se celá decode
    /// spadla a všechny flagy se zresetovaly na defaulty (přišli jsme o uživatelovo
    /// `allowVanityPlates: true` když jsme přidali `allowForeignPlates`).
    private struct AppSettings: Codable {
        var webhookURL: String = ""
        var webhookOnlyForKnown: Bool = true
        var webhookShellyBaseURL: String = ""
        var webhookPulseShortSec: Double = 1.0
        var webhookPulseExtendedSec: Double = 20.0
        var webhookKeepAliveBeatSec: Double = 3.0
        // Vjezd Shelly auth + master enable
        var shellyVjezdEnabled: Bool = true
        var shellyVjezdUser: String = "admin"
        var shellyVjezdPassword: String = ""
        // Vyjezd Shelly — second device, default disabled
        var shellyVyjezdEnabled: Bool = false
        var shellyVyjezdBaseURL: String = ""
        var shellyVyjezdUser: String = "admin"
        var shellyVyjezdPassword: String = ""
        var shellyVyjezdPulseShortSec: Double = 1.0
        var shellyVyjezdPulseExtendedSec: Double = 20.0
        var shellyVyjezdKeepAliveBeatSec: Double = 3.0
        var captureRateAuto: Bool = true
        var captureFpsManual: Double = 10.0
        var detectionRateAuto: Bool = true
        var detectionFpsManual: Double = 10.0
        var allowVanityPlates: Bool = false
        var allowForeignPlates: Bool = true
        var ocrMinObsHeightFraction: Double = 0.05
        var recommitDelaySec: Double = 15.0
        var nightPauseEnabled: Bool = false
        var nightPauseStartHour: Int = 23
        var nightPauseEndHour: Int = 5
        var ocrFastMode: Bool = false
        var ocrDualPassEnabled: Bool = false
        var enhancedRetryEnabled: Bool = true
        var enhancedRetryThreshold: Double = 0.95
        var enhancedVoteWeight: Double = 1.75
        var baseVoteWeightWhenEnhancedOverlap: Double = 0.5
        var enhancedRetryMaxBoxes: Int = 2
        var useSecondaryEngine: Bool = false
        var crossValidatedVoteWeight: Double = 2.0
        var trackerIouThreshold: Double = 0.3
        var trackerMaxLostFrames: Int = 10
        var trackerMinHitsToCommit: Int = 2
        var trackerForceCommitAfterHits: Int = 6
        var trackerMinWinnerVotes: Int = 3
        var trackerMinWinnerVoteShare: Double = 0.65
        var trackerMinPlateWidthFraction: Double = 0.09
        var trackerMinPlateWidthSafetyMult: Double = 3.0
        var snapshotRetentionDays: Int = 30
        var snapshotRetentionMaxCount: Int = 5000
        var webhookRetryCount: Int = 3
        var webhookTimeoutMs: Int = 2000
        var manualPassesMaxCount: Int = 200
        var dailyPassExpiryHours: Int = 24
        var dailyPassesAddedTotal: Int = 0
        var idleModeEnabled: Bool = false
        var idleAfterSec: Double = 2.0
        var idleDetectionFps: Double = 1.0
        var webUIEnabled: Bool = false
        var webUIPort: Int = 22224
        var webUIPassword: String = ""
        var webUIRateLimitEnabled: Bool = true
        var webUIAllowedCIDRs: String = ""
        // Opt-in performance / experimental features. All default OFF.
        var useMetalKernel: Bool = false
        var useFoundationModelsVerification: Bool = false
        var useRectanglePrefilter: Bool = false
        var useVehicleClassification: Bool = false
        var useAutoPerspective: Bool = false
        // Plate super-resolution (Swin2SR ONNX) — master + 3 internal + sample rate + post-sharpen
        var usePlateSuperResolution: Bool = true
        var usePlateSuperResolutionForSnapshots: Bool = true
        var usePlateSuperResolutionForOCRShadow: Bool = true
        var usePlateSuperResolutionForOCR: Bool = false
        var plateSuperResolutionOCRShadowSampleRate: Double = 0.25
        var usePlateSRPostSharpening: Bool = false
        var devLogging: Bool = false
        // Fáze 6 alert rules
        var unseenPlateAlertsEnabled: Bool = false
        var unseenPlateAlertDays: Int = 30

        init(webhookURL: String = "", webhookOnlyForKnown: Bool = true,
             captureRateAuto: Bool = true, captureFpsManual: Double = 10.0,
             detectionRateAuto: Bool = true, detectionFpsManual: Double = 10.0,
             allowVanityPlates: Bool = false, allowForeignPlates: Bool = true,
             ocrMinObsHeightFraction: Double = 0.05,
             recommitDelaySec: Double = 15.0,
             ocrFastMode: Bool = false,
             ocrDualPassEnabled: Bool = false,
             trackerIouThreshold: Double = 0.3,
             trackerMaxLostFrames: Int = 10,
             trackerMinHitsToCommit: Int = 2,
             trackerForceCommitAfterHits: Int = 6,
             trackerMinWinnerVotes: Int = 3,
             trackerMinWinnerVoteShare: Double = 0.65,
             trackerMinPlateWidthFraction: Double = 0.09,
             trackerMinPlateWidthSafetyMult: Double = 3.0,
             snapshotRetentionDays: Int = 30,
             snapshotRetentionMaxCount: Int = 5000,
             webhookRetryCount: Int = 3,
             webhookTimeoutMs: Int = 2000,
             manualPassesMaxCount: Int = 200,
             dailyPassExpiryHours: Int = 24,
             dailyPassesAddedTotal: Int = 0,
             idleModeEnabled: Bool = false,
             idleAfterSec: Double = 2.0,
             webUIEnabled: Bool = false,
             webUIPort: Int = 22224,
             webUIPassword: String = "",
             webUIRateLimitEnabled: Bool = true,
             webUIAllowedCIDRs: String = "") {
            self.webhookURL = webhookURL
            self.webhookOnlyForKnown = webhookOnlyForKnown
            self.captureRateAuto = captureRateAuto
            self.captureFpsManual = captureFpsManual
            self.detectionRateAuto = detectionRateAuto
            self.detectionFpsManual = detectionFpsManual
            self.allowVanityPlates = allowVanityPlates
            self.allowForeignPlates = allowForeignPlates
            self.ocrMinObsHeightFraction = ocrMinObsHeightFraction
            self.recommitDelaySec = recommitDelaySec
            self.ocrFastMode = ocrFastMode
            self.ocrDualPassEnabled = ocrDualPassEnabled
            self.trackerIouThreshold = trackerIouThreshold
            self.trackerMaxLostFrames = trackerMaxLostFrames
            self.trackerMinHitsToCommit = trackerMinHitsToCommit
            self.trackerForceCommitAfterHits = trackerForceCommitAfterHits
            self.trackerMinWinnerVotes = trackerMinWinnerVotes
            self.trackerMinWinnerVoteShare = trackerMinWinnerVoteShare
            self.trackerMinPlateWidthFraction = trackerMinPlateWidthFraction
            self.trackerMinPlateWidthSafetyMult = trackerMinPlateWidthSafetyMult
            self.snapshotRetentionDays = snapshotRetentionDays
            self.snapshotRetentionMaxCount = snapshotRetentionMaxCount
            self.webhookRetryCount = webhookRetryCount
            self.webhookTimeoutMs = webhookTimeoutMs
            self.manualPassesMaxCount = manualPassesMaxCount
            self.dailyPassExpiryHours = dailyPassExpiryHours
            self.dailyPassesAddedTotal = dailyPassesAddedTotal
            self.idleModeEnabled = idleModeEnabled
            self.idleAfterSec = idleAfterSec
            self.webUIEnabled = webUIEnabled
            self.webUIPort = webUIPort
            self.webUIPassword = webUIPassword
            self.webUIRateLimitEnabled = webUIRateLimitEnabled
            self.webUIAllowedCIDRs = webUIAllowedCIDRs
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init()
            // try? s decodeIfPresent (T?) flatifies double-optional → v je T (non-optional).
            // Pokud klíč chybí nebo typ nesedí, try? vrátí nil a if-let to přeskočí.
            if let v = try? c.decodeIfPresent(String.self, forKey: .webhookURL) { webhookURL = v }
            if let v = try? c.decodeIfPresent(Bool.self, forKey: .webhookOnlyForKnown) { webhookOnlyForKnown = v }
            if let v = try? c.decodeIfPresent(String.self, forKey: .webhookShellyBaseURL) { webhookShellyBaseURL = v }
            if let v = try? c.decodeIfPresent(Double.self, forKey: .webhookPulseShortSec) { webhookPulseShortSec = v }
            if let v = try? c.decodeIfPresent(Double.self, forKey: .webhookPulseExtendedSec) { webhookPulseExtendedSec = v }
            if let v = try? c.decodeIfPresent(Double.self, forKey: .webhookKeepAliveBeatSec) { webhookKeepAliveBeatSec = v }
            // Vjezd Shelly auth + master enable
            if let v = try? c.decodeIfPresent(Bool.self, forKey: .shellyVjezdEnabled) { shellyVjezdEnabled = v }
            if let v = try? c.decodeIfPresent(String.self, forKey: .shellyVjezdUser) { shellyVjezdUser = v }
            if let v = try? c.decodeIfPresent(String.self, forKey: .shellyVjezdPassword) { shellyVjezdPassword = v }
            // Vyjezd Shelly — second device
            if let v = try? c.decodeIfPresent(Bool.self, forKey: .shellyVyjezdEnabled) { shellyVyjezdEnabled = v }
            if let v = try? c.decodeIfPresent(String.self, forKey: .shellyVyjezdBaseURL) { shellyVyjezdBaseURL = v }
            if let v = try? c.decodeIfPresent(String.self, forKey: .shellyVyjezdUser) { shellyVyjezdUser = v }
            if let v = try? c.decodeIfPresent(String.self, forKey: .shellyVyjezdPassword) { shellyVyjezdPassword = v }
            if let v = try? c.decodeIfPresent(Double.self, forKey: .shellyVyjezdPulseShortSec) { shellyVyjezdPulseShortSec = v }
            if let v = try? c.decodeIfPresent(Double.self, forKey: .shellyVyjezdPulseExtendedSec) { shellyVyjezdPulseExtendedSec = v }
            if let v = try? c.decodeIfPresent(Double.self, forKey: .shellyVyjezdKeepAliveBeatSec) { shellyVyjezdKeepAliveBeatSec = v }
            if let v = try? c.decodeIfPresent(Bool.self, forKey: .captureRateAuto) { captureRateAuto = v }
            if let v = try? c.decodeIfPresent(Double.self, forKey: .captureFpsManual) { captureFpsManual = v }
            if let v = try? c.decodeIfPresent(Bool.self, forKey: .detectionRateAuto) { detectionRateAuto = v }
            if let v = try? c.decodeIfPresent(Double.self, forKey: .detectionFpsManual) { detectionFpsManual = v }
            if let v = try? c.decodeIfPresent(Bool.self, forKey: .allowVanityPlates) { allowVanityPlates = v }
            if let v = try? c.decodeIfPresent(Bool.self, forKey: .allowForeignPlates) { allowForeignPlates = v }
            if let v = try? c.decodeIfPresent(Double.self, forKey: .ocrMinObsHeightFraction) { ocrMinObsHeightFraction = v }
            if let v = try? c.decodeIfPresent(Double.self, forKey: .recommitDelaySec) { recommitDelaySec = v }
            if let v = try? c.decodeIfPresent(Bool.self, forKey: .nightPauseEnabled) { nightPauseEnabled = v }
            if let v = try? c.decodeIfPresent(Int.self, forKey: .nightPauseStartHour) { nightPauseStartHour = v }
            if let v = try? c.decodeIfPresent(Int.self, forKey: .nightPauseEndHour) { nightPauseEndHour = v }
            if let v = try? c.decodeIfPresent(Bool.self, forKey: .ocrFastMode) { ocrFastMode = v }
            if let v = try? c.decodeIfPresent(Bool.self, forKey: .ocrDualPassEnabled) { ocrDualPassEnabled = v }
            if let v = try? c.decodeIfPresent(Bool.self, forKey: .enhancedRetryEnabled) { enhancedRetryEnabled = v }
            if let v = try? c.decodeIfPresent(Double.self, forKey: .enhancedRetryThreshold) { enhancedRetryThreshold = v }
            if let v = try? c.decodeIfPresent(Double.self, forKey: .enhancedVoteWeight) { enhancedVoteWeight = v }
            if let v = try? c.decodeIfPresent(Double.self, forKey: .baseVoteWeightWhenEnhancedOverlap) { baseVoteWeightWhenEnhancedOverlap = v }
            if let v = try? c.decodeIfPresent(Int.self, forKey: .enhancedRetryMaxBoxes) { enhancedRetryMaxBoxes = v }
            if let v = try? c.decodeIfPresent(Bool.self, forKey: .useSecondaryEngine) { useSecondaryEngine = v }
            if let v = try? c.decodeIfPresent(Double.self, forKey: .crossValidatedVoteWeight) { crossValidatedVoteWeight = v }
            if let v = try? c.decodeIfPresent(Double.self, forKey: .trackerIouThreshold) { trackerIouThreshold = v }
            if let v = try? c.decodeIfPresent(Int.self, forKey: .trackerMaxLostFrames) { trackerMaxLostFrames = v }
            if let v = try? c.decodeIfPresent(Int.self, forKey: .trackerMinHitsToCommit) { trackerMinHitsToCommit = v }
            if let v = try? c.decodeIfPresent(Int.self, forKey: .trackerForceCommitAfterHits) { trackerForceCommitAfterHits = v }
            if let v = try? c.decodeIfPresent(Int.self, forKey: .trackerMinWinnerVotes) { trackerMinWinnerVotes = v }
            if let v = try? c.decodeIfPresent(Double.self, forKey: .trackerMinWinnerVoteShare) { trackerMinWinnerVoteShare = v }
            if let v = try? c.decodeIfPresent(Double.self, forKey: .trackerMinPlateWidthFraction) {
                // Migrace: starý default 0.12 → nový 0.09. User-customované hodnoty
                // (!= 0.12) zůstávají beze změny.
                trackerMinPlateWidthFraction = (abs(v - 0.12) < 1e-6) ? 0.09 : v
            }
            if let v = try? c.decodeIfPresent(Double.self, forKey: .trackerMinPlateWidthSafetyMult) { trackerMinPlateWidthSafetyMult = v }
            if let v = try? c.decodeIfPresent(Int.self, forKey: .snapshotRetentionDays) { snapshotRetentionDays = v }
            if let v = try? c.decodeIfPresent(Int.self, forKey: .snapshotRetentionMaxCount) { snapshotRetentionMaxCount = v }
            if let v = try? c.decodeIfPresent(Int.self, forKey: .webhookRetryCount) { webhookRetryCount = v }
            if let v = try? c.decodeIfPresent(Int.self, forKey: .webhookTimeoutMs) { webhookTimeoutMs = v }
            if let v = try? c.decodeIfPresent(Int.self, forKey: .manualPassesMaxCount) { manualPassesMaxCount = v }
            if let v = try? c.decodeIfPresent(Int.self, forKey: .dailyPassExpiryHours) { dailyPassExpiryHours = v }
            if let v = try? c.decodeIfPresent(Int.self, forKey: .dailyPassesAddedTotal) { dailyPassesAddedTotal = v }
            if let v = try? c.decodeIfPresent(Bool.self, forKey: .idleModeEnabled) { idleModeEnabled = v }
            if let v = try? c.decodeIfPresent(Double.self, forKey: .idleAfterSec) { idleAfterSec = v }
            if let v = try? c.decodeIfPresent(Double.self, forKey: .idleDetectionFps) { idleDetectionFps = v }
            if let v = try? c.decodeIfPresent(Bool.self, forKey: .webUIEnabled) { webUIEnabled = v }
            if let v = try? c.decodeIfPresent(Int.self, forKey: .webUIPort) { webUIPort = v }
            if let v = try? c.decodeIfPresent(String.self, forKey: .webUIPassword) { webUIPassword = v }
            if let v = try? c.decodeIfPresent(Bool.self, forKey: .webUIRateLimitEnabled) { webUIRateLimitEnabled = v }
            if let v = try? c.decodeIfPresent(String.self, forKey: .webUIAllowedCIDRs) { webUIAllowedCIDRs = v }
            // Opt-in features — custom init(from:) musí explicitně decode-ovat
            // každý key, jinak synthesized defaults zůstanou.
            if let v = try? c.decodeIfPresent(Bool.self, forKey: .useMetalKernel) { useMetalKernel = v }
            if let v = try? c.decodeIfPresent(Bool.self, forKey: .useFoundationModelsVerification) { useFoundationModelsVerification = v }
            // Rect-prefilter force off: VNDetectRectangles na user-cameras vrací
            // random rects (windows, signs) bez plate area, rejectovalo real plates.
            // User může v Settings UI re-enablovat pokud experimentálně chce.
            if let v = try? c.decodeIfPresent(Bool.self, forKey: .useRectanglePrefilter) {
                useRectanglePrefilter = (v == true) ? false : v  // migration: silence
            }
            if let v = try? c.decodeIfPresent(Bool.self, forKey: .useVehicleClassification) { useVehicleClassification = v }
            if let v = try? c.decodeIfPresent(Bool.self, forKey: .useAutoPerspective) { useAutoPerspective = v }
            if let v = try? c.decodeIfPresent(Bool.self, forKey: .usePlateSuperResolution) { usePlateSuperResolution = v }
            if let v = try? c.decodeIfPresent(Bool.self, forKey: .usePlateSuperResolutionForSnapshots) { usePlateSuperResolutionForSnapshots = v }
            if let v = try? c.decodeIfPresent(Bool.self, forKey: .usePlateSuperResolutionForOCRShadow) { usePlateSuperResolutionForOCRShadow = v }
            if let v = try? c.decodeIfPresent(Bool.self, forKey: .usePlateSuperResolutionForOCR) { usePlateSuperResolutionForOCR = v }
            if let v = try? c.decodeIfPresent(Double.self, forKey: .plateSuperResolutionOCRShadowSampleRate) { plateSuperResolutionOCRShadowSampleRate = v }
            if let v = try? c.decodeIfPresent(Bool.self, forKey: .usePlateSRPostSharpening) { usePlateSRPostSharpening = v }
            if let v = try? c.decodeIfPresent(Bool.self, forKey: .devLogging) { devLogging = v }
            if let v = try? c.decodeIfPresent(Bool.self, forKey: .unseenPlateAlertsEnabled) { unseenPlateAlertsEnabled = v }
            if let v = try? c.decodeIfPresent(Int.self, forKey: .unseenPlateAlertDays) { unseenPlateAlertDays = v }
        }

        enum CodingKeys: String, CodingKey {
            case webhookURL, webhookOnlyForKnown, captureRateAuto, captureFpsManual
            case webhookShellyBaseURL, webhookPulseShortSec, webhookPulseExtendedSec
            case webhookKeepAliveBeatSec
            case shellyVjezdEnabled, shellyVjezdUser, shellyVjezdPassword
            case shellyVyjezdEnabled, shellyVyjezdBaseURL, shellyVyjezdUser, shellyVyjezdPassword
            case shellyVyjezdPulseShortSec, shellyVyjezdPulseExtendedSec, shellyVyjezdKeepAliveBeatSec
            case detectionRateAuto, detectionFpsManual, allowVanityPlates, allowForeignPlates
            case ocrMinObsHeightFraction, recommitDelaySec, ocrFastMode, ocrDualPassEnabled
            case enhancedRetryEnabled, enhancedRetryThreshold, enhancedVoteWeight
            case baseVoteWeightWhenEnhancedOverlap, enhancedRetryMaxBoxes
            case useSecondaryEngine, crossValidatedVoteWeight
            case nightPauseEnabled, nightPauseStartHour, nightPauseEndHour
            case trackerIouThreshold, trackerMaxLostFrames, trackerMinHitsToCommit
            case trackerForceCommitAfterHits, trackerMinWinnerVotes, trackerMinWinnerVoteShare
            case trackerMinPlateWidthFraction, trackerMinPlateWidthSafetyMult
            case snapshotRetentionDays, snapshotRetentionMaxCount
            case webhookRetryCount, webhookTimeoutMs
            case manualPassesMaxCount, dailyPassExpiryHours, dailyPassesAddedTotal
            case idleModeEnabled, idleAfterSec, idleDetectionFps
            case webUIEnabled, webUIPort, webUIPassword, webUIRateLimitEnabled, webUIAllowedCIDRs
            // Opt-in feature flags musí být v enum aby Codable decoded z JSON.
            // Bez toho JSONDecoder vrací default false i když settings.json má true.
            case useMetalKernel, useFoundationModelsVerification, useRectanglePrefilter
            case useVehicleClassification, useAutoPerspective, devLogging
            case unseenPlateAlertsEnabled, unseenPlateAlertDays
            // Plate super-resolution (Swin2SR ONNX)
            case usePlateSuperResolution, usePlateSuperResolutionForSnapshots
            case usePlateSuperResolutionForOCRShadow, usePlateSuperResolutionForOCR
            case plateSuperResolutionOCRShadowSampleRate, usePlateSRPostSharpening
        }
    }

    private func loadSettings() {
        guard let data = try? Data(contentsOf: settingsURL) else { return }
        guard let s = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            FileHandle.safeStderrWrite("[AppState] settings decode failed — keeping defaults\n".data(using: .utf8)!)
            return
        }
        webhookURL = s.webhookURL
        webhookOnlyForKnown = s.webhookOnlyForKnown
        webhookShellyBaseURL = s.webhookShellyBaseURL
        webhookPulseShortSec = s.webhookPulseShortSec
        webhookPulseExtendedSec = s.webhookPulseExtendedSec
        webhookKeepAliveBeatSec = s.webhookKeepAliveBeatSec
        shellyVjezdEnabled = s.shellyVjezdEnabled
        shellyVjezdUser = s.shellyVjezdUser
        shellyVjezdPassword = s.shellyVjezdPassword
        shellyVyjezdEnabled = s.shellyVyjezdEnabled
        shellyVyjezdBaseURL = s.shellyVyjezdBaseURL
        shellyVyjezdUser = s.shellyVyjezdUser
        shellyVyjezdPassword = s.shellyVyjezdPassword
        shellyVyjezdPulseShortSec = s.shellyVyjezdPulseShortSec
        shellyVyjezdPulseExtendedSec = s.shellyVyjezdPulseExtendedSec
        shellyVyjezdKeepAliveBeatSec = s.shellyVyjezdKeepAliveBeatSec
        captureRateAuto = s.captureRateAuto
        captureFpsManual = s.captureFpsManual
        detectionRateAuto = s.detectionRateAuto
        detectionFpsManual = s.detectionFpsManual
        allowVanityPlates = s.allowVanityPlates
        allowForeignPlates = s.allowForeignPlates
        ocrMinObsHeightFraction = s.ocrMinObsHeightFraction
        recommitDelaySec = s.recommitDelaySec
        nightPauseEnabled = s.nightPauseEnabled
        nightPauseStartHour = s.nightPauseStartHour
        nightPauseEndHour = s.nightPauseEndHour
        ocrFastMode = s.ocrFastMode
        ocrDualPassEnabled = s.ocrDualPassEnabled
        enhancedRetryEnabled = s.enhancedRetryEnabled
        enhancedRetryThreshold = s.enhancedRetryThreshold
        enhancedVoteWeight = s.enhancedVoteWeight
        baseVoteWeightWhenEnhancedOverlap = s.baseVoteWeightWhenEnhancedOverlap
        enhancedRetryMaxBoxes = s.enhancedRetryMaxBoxes
        useSecondaryEngine = s.useSecondaryEngine
        crossValidatedVoteWeight = s.crossValidatedVoteWeight
        trackerIouThreshold = s.trackerIouThreshold
        trackerMaxLostFrames = s.trackerMaxLostFrames
        trackerMinHitsToCommit = s.trackerMinHitsToCommit
        trackerForceCommitAfterHits = s.trackerForceCommitAfterHits
        trackerMinWinnerVotes = s.trackerMinWinnerVotes
        trackerMinWinnerVoteShare = s.trackerMinWinnerVoteShare
        trackerMinPlateWidthFraction = s.trackerMinPlateWidthFraction
        trackerMinPlateWidthSafetyMult = s.trackerMinPlateWidthSafetyMult
        snapshotRetentionDays = s.snapshotRetentionDays
        snapshotRetentionMaxCount = s.snapshotRetentionMaxCount
        webhookRetryCount = s.webhookRetryCount
        webhookTimeoutMs = s.webhookTimeoutMs
        manualPassesMaxCount = s.manualPassesMaxCount
        dailyPassExpiryHours = s.dailyPassExpiryHours
        dailyPassesAddedTotal = s.dailyPassesAddedTotal
        idleModeEnabled = s.idleModeEnabled
        idleAfterSec = s.idleAfterSec
        idleDetectionFps = s.idleDetectionFps
        // Pořadí: port PRVNÍ (didSet nic nedělá dokud enabled=false), pak enabled.
        // Při enabled=true → didSet zavolá bind+start s aktuálním portem. Jedno volání.
        webUIPort = s.webUIPort
        webUIPassword = s.webUIPassword
        webUIRateLimitEnabled = s.webUIRateLimitEnabled
        webUIAllowedCIDRs = s.webUIAllowedCIDRs
        webUIEnabled = s.webUIEnabled
        FileHandle.safeStderrWrite("[AppState.load] RAW decoded s.devLogging=\(s.devLogging) s.useAutoPerspective=\(s.useAutoPerspective) s.useVehicleClassification=\(s.useVehicleClassification)\n".data(using: .utf8)!)
        useMetalKernel = s.useMetalKernel
        useFoundationModelsVerification = s.useFoundationModelsVerification
        useRectanglePrefilter = s.useRectanglePrefilter
        useVehicleClassification = s.useVehicleClassification
        useAutoPerspective = s.useAutoPerspective
        // SR flags force-OFF na load even if settings.json had true. ONNX + CoreML
        // EP eskaluje RSS na 50+ GB → unstable. Re-enable jen po fix root cause +
        // manual user toggle (UI master switch).
        usePlateSuperResolution = false
        usePlateSuperResolutionForSnapshots = false
        usePlateSuperResolutionForOCRShadow = false
        usePlateSuperResolutionForOCR = false
        plateSuperResolutionOCRShadowSampleRate = s.plateSuperResolutionOCRShadowSampleRate
        usePlateSRPostSharpening = s.usePlateSRPostSharpening
        devLogging = s.devLogging
        unseenPlateAlertsEnabled = s.unseenPlateAlertsEnabled
        unseenPlateAlertDays = s.unseenPlateAlertDays
        FileHandle.safeStderrWrite("[AppState] settings loaded: vanity=\(allowVanityPlates) foreign=\(allowForeignPlates) devLog=\(devLogging) autoPersp=\(useAutoPerspective) vehicleClass=\(useVehicleClassification)\n".data(using: .utf8)!)
    }

    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.saveSettings() }
        }
    }

    private func saveSettings() {
        var s = AppSettings(
            webhookURL: webhookURL, webhookOnlyForKnown: webhookOnlyForKnown,
            captureRateAuto: captureRateAuto, captureFpsManual: captureFpsManual,
            detectionRateAuto: detectionRateAuto, detectionFpsManual: detectionFpsManual,
            allowVanityPlates: allowVanityPlates,
            allowForeignPlates: allowForeignPlates,
            ocrMinObsHeightFraction: ocrMinObsHeightFraction,
            recommitDelaySec: recommitDelaySec,
            ocrFastMode: ocrFastMode,
            ocrDualPassEnabled: ocrDualPassEnabled,
            trackerIouThreshold: trackerIouThreshold,
            trackerMaxLostFrames: trackerMaxLostFrames,
            trackerMinHitsToCommit: trackerMinHitsToCommit,
            trackerForceCommitAfterHits: trackerForceCommitAfterHits,
            trackerMinWinnerVotes: trackerMinWinnerVotes,
            trackerMinWinnerVoteShare: trackerMinWinnerVoteShare,
            trackerMinPlateWidthFraction: trackerMinPlateWidthFraction,
            trackerMinPlateWidthSafetyMult: trackerMinPlateWidthSafetyMult,
            snapshotRetentionDays: snapshotRetentionDays,
            snapshotRetentionMaxCount: snapshotRetentionMaxCount,
            webhookRetryCount: webhookRetryCount,
            webhookTimeoutMs: webhookTimeoutMs,
            manualPassesMaxCount: manualPassesMaxCount,
            dailyPassExpiryHours: dailyPassExpiryHours,
            dailyPassesAddedTotal: dailyPassesAddedTotal,
            idleModeEnabled: idleModeEnabled,
            idleAfterSec: idleAfterSec,
            webUIEnabled: webUIEnabled,
            webUIPort: webUIPort,
            webUIPassword: webUIPassword,
            webUIRateLimitEnabled: webUIRateLimitEnabled,
            webUIAllowedCIDRs: webUIAllowedCIDRs
        )
        // Opt-in flags (přímé přiřazení — init bez nich by znamenal 9 dalších parametrů).
        s.useMetalKernel = useMetalKernel
        s.useFoundationModelsVerification = useFoundationModelsVerification
        s.useRectanglePrefilter = useRectanglePrefilter
        s.useVehicleClassification = useVehicleClassification
        s.useAutoPerspective = useAutoPerspective
        s.usePlateSuperResolution = usePlateSuperResolution
        s.usePlateSuperResolutionForSnapshots = usePlateSuperResolutionForSnapshots
        s.usePlateSuperResolutionForOCRShadow = usePlateSuperResolutionForOCRShadow
        s.usePlateSuperResolutionForOCR = usePlateSuperResolutionForOCR
        s.plateSuperResolutionOCRShadowSampleRate = plateSuperResolutionOCRShadowSampleRate
        s.usePlateSRPostSharpening = usePlateSRPostSharpening
        s.enhancedRetryEnabled = enhancedRetryEnabled
        s.enhancedRetryThreshold = enhancedRetryThreshold
        s.enhancedVoteWeight = enhancedVoteWeight
        s.baseVoteWeightWhenEnhancedOverlap = baseVoteWeightWhenEnhancedOverlap
        s.enhancedRetryMaxBoxes = enhancedRetryMaxBoxes
        s.useSecondaryEngine = useSecondaryEngine
        s.webhookShellyBaseURL = webhookShellyBaseURL
        s.webhookPulseShortSec = webhookPulseShortSec
        s.webhookPulseExtendedSec = webhookPulseExtendedSec
        s.webhookKeepAliveBeatSec = webhookKeepAliveBeatSec
        s.shellyVjezdEnabled = shellyVjezdEnabled
        s.shellyVjezdUser = shellyVjezdUser
        s.shellyVjezdPassword = shellyVjezdPassword
        s.shellyVyjezdEnabled = shellyVyjezdEnabled
        s.shellyVyjezdBaseURL = shellyVyjezdBaseURL
        s.shellyVyjezdUser = shellyVyjezdUser
        s.shellyVyjezdPassword = shellyVyjezdPassword
        s.shellyVyjezdPulseShortSec = shellyVyjezdPulseShortSec
        s.shellyVyjezdPulseExtendedSec = shellyVyjezdPulseExtendedSec
        s.shellyVyjezdKeepAliveBeatSec = shellyVyjezdKeepAliveBeatSec
        s.crossValidatedVoteWeight = crossValidatedVoteWeight
        s.devLogging = devLogging
        s.unseenPlateAlertsEnabled = unseenPlateAlertsEnabled
        s.unseenPlateAlertDays = unseenPlateAlertDays
        s.nightPauseEnabled = nightPauseEnabled
        s.nightPauseStartHour = nightPauseStartHour
        s.nightPauseEndHour = nightPauseEndHour
        s.idleDetectionFps = idleDetectionFps
        if let data = try? JSONEncoder().encode(s) {
            try? SecureFile.writeAtomic(data, to: settingsURL)
        }
    }

    /// Informační capture FPS hint — native pipeline dekóduje všechny framy
    /// ze streamu, tato hodnota jen informuje PlatePipeline a UI.
    /// - Manual: vždy uživatelovo manual setting.
    /// - Auto: použij stream nominal FPS pokud je známý, jinak nil.
    func captureFpsSetting(streamNominalFps: Double = 0) -> Double? {
        if captureRateAuto {
            return streamNominalFps > 0 ? streamNominalFps : nil
        }
        return max(1.0, captureFpsManual)
    }

    /// Detection FPS pro PlatePipeline poll timer.
    /// Auto = preferuj **nominal stream FPS** (z RTSPClient/SDP — deterministický);
    /// fallback na měřený capture EMA; final fallback 10.
    /// Manual = fixed slider value (uživatelovo nastavení respektováno hned od bootu).
    ///
    /// Adaptive multiplier z `ResourceBudget.shared.currentMode` — base FPS násobený
    /// 1.0 / 0.7 / 0.45 podle CPU + thermal + OCR latency. Floor 2 fps even constrained
    /// — pod tím by tracker missoval rychlá auta.
    func effectiveDetectionFps(streamNominalFps: Double, measuredCaptureFps: Double) -> Double {
        let base: Double
        if detectionRateAuto {
            if streamNominalFps > 0 { base = streamNominalFps }
            else if measuredCaptureFps > 0 { base = measuredCaptureFps }
            else { base = 10.0 }
        } else {
            base = max(0.5, detectionFpsManual)
        }
        let mult = ResourceBudget.multiplier(for: ResourceBudget.shared.currentMode)
        return max(2.0, min(base, base * mult))
    }

    var activeCamera: CameraConfig? {
        cameras.first(where: { $0.name == activeCameraName })
    }

    // Camera ROI setters (updateCamera, setRoi*, setCameraMinObs) extracted to AppState+CameraSetters.swift.
    private var camerasSaveTimer: Timer?

    /// Cameras save — debounce 200 ms srazí I/O na 1× per ROI drag.
    /// Internal access kvůli `AppState+CameraSetters.swift` extension callerům.
    func save() {
        camerasSaveTimer?.invalidate()
        camerasSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.saveCamerasImmediately() }
        }
    }

    private func saveCamerasImmediately() {
        do {
            let data = try JSONEncoder().encode(cameras)
            try SecureFile.writeAtomic(data, to: configURL)
        } catch {
            FileHandle.safeStderrWrite(
                "[AppState] save failed: \(error)\n".data(using: .utf8)!)
        }
    }

    private static func loadFromDisk(at url: URL) -> [CameraConfig]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([CameraConfig].self, from: data)
    }

    /// Default cameras — 2 fyzické VIGI C250 (vjezd 192.0.2.161, výjezd 192.0.2.162).
    /// Native pipeline (RTSPClient + VTDecompressionSession) se připojuje přímo,
    /// žádný go2rtc / ffmpeg uprostřed. Override přes env vars pro alternativní
    /// adresy nebo dev testing. Reálné heslo nikdy nedržíme v source; user ho
    /// uloží přes Settings do `cameras.json` s právy 0600.
    private static func defaultCameras() -> [CameraConfig] {
        let vjezdURL  = ProcessInfo.processInfo.environment["SPZ_RTSP_VJEZD"]
            ?? "rtsp://admin:CHANGE_ME@192.0.2.161:554/stream1"
        let vyjezdURL = ProcessInfo.processInfo.environment["SPZ_RTSP_VYJEZD"]
            ?? "rtsp://admin:CHANGE_ME@192.0.2.162:554/stream1"
        return [
            CameraConfig(name: "vjezd",  label: "Vjezd",  rtspURL: vjezdURL,  detectFps: 10.0, roi: nil, enabled: true),
            CameraConfig(name: "vyjezd", label: "Výjezd", rtspURL: vyjezdURL, detectFps: 10.0, roi: nil, enabled: true),
        ]
    }

    func appendDetection(_ rec: RecentDetection) {
        recents.add(rec)
    }
}

struct PipelineStats: Equatable {
    var captureFps: Double = 0
    var detectFps: Double = 0
    var ocrLatencyMs: Double = 0
    var commitsTotal: Int = 0
}
