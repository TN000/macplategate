import SwiftUI
import AppKit

// Entrypoint je `main.swift`, aby CLI dispatch (replay-snapshots) nemusel nikdy
// inicializovat `AppState` / SwiftUI / WebServer / camera connections. Při launch
// z .app bundle musí `main.swift` zavolat `SPZApp.main()`.
struct SPZApp: App {
    @StateObject private var state = AppState()
    @StateObject private var cameras = CameraManager()
    @StateObject private var health = HealthMonitor()
    @NSApplicationDelegateAdaptor(SPZAppDelegate.self) private var appDelegate

    /// Side-effect-only property — vyhodnocen jednou při instantiaci `SPZApp`
    /// PŘED tím než SwiftUI body začne, přesměruje stderr na persistentní
    /// rotating log v App Support tak aby problémy hned po rebootu (kdy ještě
    /// nepoběží Console nebo `log show`) šly dohledat z disku.
    static let stderrRedirect: Void = {
        let dir = AppPaths.baseDir
        let logURL = dir.appendingPathComponent("spz.log")
        rotateLogIfNeeded(at: logURL)
        // freopen na "a" = append; bez buffering na stderr (setvbuf line-buffered)
        freopen(logURL.path, "a", stderr)
        setvbuf(stderr, nil, _IOLBF, 0)
        // Log obsahuje plate commit records (PII). Konzistentně s ostatními
        // PII soubory (known.json, whitelist-audit.log, detections.db) = 0600.
        // freopen s default umask dal 0644 world-readable; fchmod to opravuje.
        _ = fchmod(fileno(stderr), 0o600)
        let ts = ISO8601DateFormatter().string(from: Date())
        FileHandle.safeStderrWrite("\n=== MacPlateGate launch @ \(ts) ===\n".data(using: .utf8)!)
    }()

    static func rotateLogIfNeeded(at logURL: URL) {
        let fm = FileManager.default
        // 10 MB threshold — under active devLogging menší treshold rotuje příliš
        // často a mažou se relevantní recent history při investigation.
        guard let attrs = try? fm.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? Int, size > 10_000_000 else { return }
        let prev = logURL.deletingLastPathComponent().appendingPathComponent("spz.log.1")
        _ = try? fm.removeItem(at: prev)
        _ = try? fm.moveItem(at: logURL, to: prev)
        // freopen na stejnou cestu — stderr FD zůstane platný a dostane nový soubor.
        freopen(logURL.path, "a", stderr)
        _ = fchmod(fileno(stderr), 0o600)  // PII — konzistentní s initial open
    }

    init() {
        _ = SPZApp.stderrRedirect
        SPZApp.startLogRotationTimer()
    }

    /// Periodický check velikosti logu — bez tohoto běžící aplikace (dny uptime)
    /// naroste log do desítek MB. Check každých 5 min s minimal overhead (1 stat call).
    /// Timer uložen ve static var, aby šel invalidate (test/teardown) a aby se
    /// nezduplikoval při re-init SPZApp (SwiftUI preview může re-instantiovat).
    @MainActor private static var logRotationTimer: Timer?
    @MainActor private static func startLogRotationTimer() {
        logRotationTimer?.invalidate()
        logRotationTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            let logURL = AppPaths.baseDir.appendingPathComponent("spz.log")
            SPZApp.rotateLogIfNeeded(at: logURL)
        }
    }

    var body: some Scene {
        WindowGroup("MacPlateGate") {
            ContentView()
                .environmentObject(state)
                .environmentObject(cameras)
                .environmentObject(health)
                .onAppear {
                    // HealthMonitor se binduje tady — state i cameras už jsou
                    // instancované a (během ContentView init) cameras.bind(state)
                    // se už zavolal z StreamView.onAppear. Dvojitý bind je OK (idempotent).
                    health.bind(state: state, cameras: cameras)
                    // Fáze 6 Unseen-plate alerter lifecycle start.
                    if state.unseenPlateAlertsEnabled {
                        UnseenPlateAlerter.shared.thresholdDays = state.unseenPlateAlertDays
                        UnseenPlateAlerter.shared.start()
                    }
                }
                .onChange(of: state.unseenPlateAlertsEnabled) { _, enabled in
                    if enabled {
                        UnseenPlateAlerter.shared.thresholdDays = state.unseenPlateAlertDays
                        UnseenPlateAlerter.shared.start()
                    } else {
                        UnseenPlateAlerter.shared.stop()
                    }
                }
                .onChange(of: state.unseenPlateAlertDays) { _, days in
                    UnseenPlateAlerter.shared.thresholdDays = days
                }
                .frame(minWidth: 1100, minHeight: 700)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// AppDelegate — graceful shutdown (SIGTERM/SIGINT), WAL checkpoint, release portů.
/// Native pipeline (RTSPClient + VTDecompressionSession) nemá žádné external
/// child procesy — na rozdíl od předchozí ffmpeg varianty tedy není co orphan-kill.
final class SPZAppDelegate: NSObject, NSApplicationDelegate {
    private static var sigtermSource: DispatchSourceSignal?
    private static var sigintSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // DispatchSource místo C signal(3) — signal handler běží v async-signal context
        // kde Store / WebServer / dispatch work items jsou UB. DispatchSource handlery
        // běží na regular queue, takže MainActor hop je safe.
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let termSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSrc.setEventHandler {
            // DispatchSource handler má queue=.main → běžíme na main thread,
            // assumeIsolated je bezpečné (crashes jen pokud by se dostalo
            // na ne-main thread, což při .main queue nemůže).
            MainActor.assumeIsolated { SPZAppDelegate.cleanShutdown() }
            exit(0)
        }
        termSrc.resume()
        Self.sigtermSource = termSrc

        let intSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        intSrc.setEventHandler {
            MainActor.assumeIsolated { SPZAppDelegate.cleanShutdown() }
            exit(0)
        }
        intSrc.resume()
        Self.sigintSource = intSrc

        // Scan crash reports a fire ribbon pokud nejnovější crash je novější
        // než last seen. Best-effort, nekritická cesta.
        CrashReporterRibbon.scanAtStartup()

        // Cleanup: smaž sessions pro SPZ co nejsou v whitelistu (migrace po
        // zavedení whitelist-only parking pravidla).
        KnownPlates.shared.purgeOrphanSessions()

        // Idle warmup PlateSREngine je DISABLED — ONNX + CoreML EP eskaluje RSS
        // na 50+ GB při production traffic. Bez warmup ORT session se nikdy
        // nenačte (PlateSREngine.shared volání jdou jen když master flag ON,
        // a ten je defaultně OFF).
    }

    func applicationWillTerminate(_ notification: Notification) {
        SPZAppDelegate.cleanShutdown()
    }

    /// Jednotný shutdown path — volá se z applicationWillTerminate i ze
    /// SIGTERM/SIGINT DispatchSource handlerů. Signal handlery jinak skipovaly
    /// WAL checkpoint a WebServer.stop, což na `launchctl` shutdown Mac mini
    /// mohlo nechat corrupted DB wal a nedorelease port. Každý bod je
    /// idempotent a samostatně safe.
    @MainActor
    static func cleanShutdown() {
        // Pořadí: nejdřív zastavit HealthMonitor timer (aby neběžel update()
        // proti rozbitým subsystémům), pak checkpoint/cancel/stop.
        HealthMonitor.shared?.stopMonitoring()
        Store.shared.periodicCheckpoint()
        WebhookClient.shared.cancelAll()
        WebServer.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
