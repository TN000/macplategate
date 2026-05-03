import Foundation
import SwiftUI
import Darwin

/// Centralizované vyhodnocení provozního stavu aplikace — agregace per-subsystem
/// signálů do souhrnného zelená/žlutá/červená badge v header baru.
///
/// Refresh každé 2 s přes Timer. Subsystémy:
///   - Cameras — všechny enabled cameras musí mít frame <5 s starý
///   - Webhook — webhookURL empty → n/a (user bez relé), jinak last HTTP status 2xx
///   - DB — lastPersistTs <24 h staré (nebo žádný commit → warning, ne error)
///   - WAL — velikost <50 MB
///   - Disk — volumeAvailableCapacity >5 GB
///   - WebUI — webUIEnabled → isListening true
@MainActor
final class HealthMonitor: ObservableObject {
    enum Level: Int, Comparable {
        case ok = 0       // zeleno
        case warning = 1  // žluto
        case error = 2    // červeno
        static func < (l: Level, r: Level) -> Bool { l.rawValue < r.rawValue }
    }

    struct Check {
        let name: String
        let level: Level
        let detail: String
    }

    @Published private(set) var overall: Level = .ok
    @Published private(set) var checks: [Check] = []
    @Published private(set) var lastUpdate: Date = Date()

    private var timer: Timer?
    private weak var state: AppState?
    private weak var cameras: CameraManager?

    /// Čítač update() volání pro sampling RSS každých 30 cycles (~60 s při 2 s cadence).
    private var updateTick: Int = 0
    /// Baseline RSS zachycený při 3. vzorku (~3 min uptime) — umožňuje vypočítat
    /// delta růst z ustáleného stavu po Vision/Metal warmup.
    private var rssBaselineMB: Double? = nil
    private var rssSampleCount: Int = 0
    private let startTime: Date = Date()

    /// Weak registr pro cleanShutdown hook — SPZAppDelegate nemá přímý
    /// pointer na @StateObject z SwiftUI scenu, musí ho najít přes registr.
    static weak var shared: HealthMonitor?

    func bind(state: AppState, cameras: CameraManager) {
        self.state = state
        self.cameras = cameras
        Self.shared = self
        start()
    }

    private func start() {
        timer?.invalidate()
        // 2 s cadence. Timer přímo na MainActor — všechny reads jsou MainActor-safe
        // (services.isEmpty, AppState.webhookURL, Store.shared.walSizeBytes).
        let t = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.update() }
        }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
        update()  // initial
    }

    deinit { timer?.invalidate() }

    /// Explicitní teardown pro `cleanShutdown` cestu. @StateObject držený
    /// SwiftUI scenou nedeallocuje dřív než app exit, ale Timer fires z main
    /// run loopu může proběhnout BĚHEM cleanShutdown (mezi Store.checkpoint
    /// a WebServer.stop). Tím by `update()` přistupovalo k subystémům v
    /// rozbitém stavu. Jednorázový invalidate před tear-down = safe.
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    /// Spočítá aktuální stav ze všech subsystémů. Všechny reads jsou levné
    /// (žádný I/O kromě FileManager.attributesOfItem pro WAL a volume lookup).
    private func update() {
        var list: [Check] = []
        guard let state = state, let cameras = cameras else {
            overall = .error
            checks = [Check(name: "Init", level: .error, detail: "Monitor nenabindován")]
            return
        }

        // --- Cameras ---
        let enabledCams = state.cameras.filter { $0.enabled }
        if enabledCams.isEmpty {
            list.append(Check(name: "Kamery", level: .warning, detail: "Žádná kamera aktivní"))
        } else {
            var maxAge: TimeInterval = 0
            var worstLabel = ""
            for cam in enabledCams {
                let age = cameras.services[cam.name]?.lastFrameAge() ?? 999
                if age > maxAge { maxAge = age; worstLabel = cam.label }
            }
            if maxAge < 5 {
                list.append(Check(name: "Kamery", level: .ok,
                                  detail: "Všechny streamy aktivní (nejstarší frame \(String(format: "%.1f", maxAge)) s)"))
            } else if maxAge < 30 {
                list.append(Check(name: "Kamery", level: .warning,
                                  detail: "\(worstLabel): poslední frame před \(Int(maxAge)) s"))
            } else {
                list.append(Check(name: "Kamery", level: .error,
                                  detail: "\(worstLabel): stream odpojen (\(Int(maxAge)) s bez framu)"))
            }
        }

        // --- Webhook ---
        // `gateBaseURL` pokrývá oba režimy: nový scenario routing
        // (webhookShellyBaseURL) i legacy raw template (webhookURL).
        // Health říká "Nenakonfigurován" jen pokud admin nemá ani jeden.
        if state.gateBaseURL.isEmpty {
            list.append(Check(name: "Webhook", level: .ok, detail: "Nenakonfigurován (volitelné)"))
        } else if let lf = WebhookClient.shared.lastFired {
            if (200..<300).contains(lf.status) {
                list.append(Check(name: "Webhook", level: .ok,
                                  detail: "Poslední fire OK (HTTP \(lf.status))"))
            } else {
                list.append(Check(name: "Webhook", level: .error,
                                  detail: "Poslední fire selhal (HTTP \(lf.status))"))
            }
        } else {
            list.append(Check(name: "Webhook", level: .warning, detail: "Nakonfigurován, nefired"))
        }

        // --- DB / SQLite ---
        if let ts = Store.shared.lastPersistTs {
            let age = Date().timeIntervalSince(ts)
            if age < 86400 {
                list.append(Check(name: "Databáze",
                                  level: .ok,
                                  detail: "Poslední zápis před \(formatAge(age))"))
            } else {
                list.append(Check(name: "Databáze",
                                  level: .warning,
                                  detail: "Poslední zápis před \(formatAge(age))"))
            }
        } else {
            list.append(Check(name: "Databáze", level: .ok, detail: "Čekám na první commit"))
        }

        // --- WAL size ---
        let walBytes = Store.shared.walSizeBytes()
        let walMB = Double(walBytes) / 1_048_576
        if walMB < 50 {
            list.append(Check(name: "WAL", level: .ok,
                              detail: String(format: "%.1f MB", walMB)))
        } else if walMB < 200 {
            list.append(Check(name: "WAL", level: .warning,
                              detail: String(format: "%.1f MB (>50 MB, checkpoint zpožděný)", walMB)))
        } else {
            list.append(Check(name: "WAL", level: .error,
                              detail: String(format: "%.1f MB (>200 MB, DB nepíše)", walMB)))
        }

        // --- Disk free ---
        if let free = volumeFreeGB() {
            if free > 5 {
                list.append(Check(name: "Disk", level: .ok,
                                  detail: String(format: "%.1f GB volné", free)))
            } else if free > 1 {
                list.append(Check(name: "Disk", level: .warning,
                                  detail: String(format: "%.1f GB volné (<5 GB)", free)))
            } else {
                list.append(Check(name: "Disk", level: .error,
                                  detail: String(format: "%.1f GB volné (kritické)", free)))
            }
        }

        // --- Web UI ---
        if state.webUIEnabled {
            if WebServer.shared.isListening {
                list.append(Check(name: "Web UI", level: .ok,
                                  detail: "https://…:\(state.webUIPort)/ aktivní"))
            } else {
                list.append(Check(name: "Web UI", level: .error,
                                  detail: "Zapnuto ale neposlouchá (port \(state.webUIPort) zablokovaný?)"))
            }
        } else {
            list.append(Check(name: "Web UI", level: .ok, detail: "Vypnuto"))
        }

        checks = list
        overall = list.map { $0.level }.max() ?? .ok
        lastUpdate = Date()

        // Periodic RSS log (každé ~60 s) — umožňuje observovat memory trend
        // v devlogu bez Instruments.
        // Baseline bereme až na 3. sample (~90 s uptime) — první dva vzorky zachytí
        // ještě neustálený post-init stav (Vision/Metal warmup alokace).
        updateTick &+= 1
        if updateTick % 30 == 0, let rssMB = Self.currentRSSMB() {
            rssSampleCount += 1
            if rssSampleCount == 3 { rssBaselineMB = rssMB }
            let deltaStr: String
            if let baseline = rssBaselineMB {
                let d = rssMB - baseline
                deltaStr = String(format: "%+.0f", d)
            } else {
                deltaStr = "n/a"
            }
            let uptimeMin = Date().timeIntervalSince(startTime) / 60.0
            FileHandle.safeStderrWrite(
                "[HealthMonitor] rss=\(String(format: "%.0f", rssMB))MB delta=\(deltaStr)MB uptime=\(String(format: "%.1f", uptimeMin))min\n"
                    .data(using: .utf8)!)
        }
    }

    /// Resident set size přes mach task_info — `phys_footprint` je true RSS na
    /// macOS (excluding shared memory over-counting z `resident_size`).
    private static func currentRSSMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576
    }

    private func formatAge(_ sec: TimeInterval) -> String {
        if sec < 60 { return "\(Int(sec)) s" }
        if sec < 3600 { return "\(Int(sec / 60)) min" }
        if sec < 86400 { return "\(Int(sec / 3600)) h" }
        return "\(Int(sec / 86400)) d"
    }

    /// Volné místo na disku v GB (volume obsahující home dir).
    private func volumeFreeGB() -> Double? {
        let url = FileManager.default.homeDirectoryForCurrentUser
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let bytes = values?.volumeAvailableCapacityForImportantUsage else { return nil }
        return Double(bytes) / 1_073_741_824
    }
}
