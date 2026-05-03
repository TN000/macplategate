import Foundation
import Darwin

/// Centralizovaný resource budget pro adaptive detection FPS throttling.
///
/// Sleduje **čtyři signály**:
/// - **Process CPU %** (delta `proc_pidinfo` mezi vzorky / wall time)
/// - **System CPU %** (`host_processor_info` ticks delta)
/// - **Thermal state** (`ProcessInfo.thermalState`)
/// - **OCR latency p95** (klouzavé okno 30 vzorků z PlatePipeline)
///
/// Klasifikuje stav do 3 modes (`normal` / `warm` / `constrained`) s **hysteresis**:
/// worse-direction transition vyžaduje 2 po sobě jdoucí samples (10 s),
/// better-direction 3 (15 s), a min dwell time 30 s mezi changes (zabraňuje
/// flickeringu pipeline restartu při pulsujícím load).
///
/// `effectiveDetectionFps` v AppState čte cached `currentMode` a aplikuje
/// multiplier (1.0 / 0.7 / 0.45) na auto/manual base FPS s clamp `max(2, …)`.
/// CameraManager periodicky volá `evaluate()` (5 s) a při změně mode dělá
/// pipeline-only restart (`pipe.start(fps:)` — NIKDY `svc.connect()`, jinak
/// by adaptive throttling spamovala RTSP DESCRIBE/SETUP/PLAY churn).
final class ResourceBudget: @unchecked Sendable {
    static let shared = ResourceBudget()

    enum BudgetMode: String, Sendable {
        case normal, warm, constrained
    }

    struct Snapshot: Sendable {
        var procCpuPercent: Double = 0     // 0–100% per all-cores total
        var systemCpuPercent: Double = 0   // 0–100% systém-wide aggregate
        var thermal: ProcessInfo.ThermalState = .nominal
        var ocrP95Ms: Double = 0
        var rssBytes: UInt64 = 0
        var timestamp: Date = Date()
        var mode: BudgetMode = .normal
        var dwellSec: Double = 0
        var activeCameras: Int = 0
    }

    private let lock = NSLock()
    private var snapshot = Snapshot()

    /// Per-camera OCR latency p95 ring buffer. Klíč = camera name.
    /// Zbývající cizí state je modifikován jen v evaluate() na MainActor caller side.
    private var ocrLatencySamples: [String: [Double]] = [:]
    private static let ocrSampleWindow: Int = 30

    /// Per-sample state pro CPU delta computation.
    private var prevProcCpuTotal: UInt64 = 0  // ns (user + system)
    private var prevSystemCpuTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) = (0, 0, 0, 0)
    private var prevSampleWall: Date = .distantPast

    /// Hysteresis state — počítá consecutive samples co triggerují worse/better mode.
    private var pendingMode: BudgetMode = .normal
    private var pendingCount: Int = 0
    private var lastModeChangeAt: Date = .distantPast

    // MARK: - Public API

    /// Aktuální cached mode — čte `effectiveDetectionFps` v AppState. Lock-free read
    /// (atomic via NSLock) je acceptable — mode se mění max 1× za 30 s.
    var currentMode: BudgetMode {
        lock.lock(); defer { lock.unlock() }
        return snapshot.mode
    }

    func currentSnapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    /// Klient (PlatePipeline.handleResults) zaznamenává OCR inference latency
    /// per frame per camera. Buffer keep last 30, p95 derives in `evaluate()`.
    func recordOcrLatency(_ ms: Double, for camera: String) {
        lock.lock(); defer { lock.unlock() }
        var samples = ocrLatencySamples[camera, default: []]
        samples.append(ms)
        if samples.count > Self.ocrSampleWindow {
            samples.removeFirst(samples.count - Self.ocrSampleWindow)
        }
        ocrLatencySamples[camera] = samples
    }

    func setActiveCameras(_ count: Int) {
        lock.lock()
        snapshot.activeCameras = count
        lock.unlock()
    }

    /// Re-evaluate mode based on current samples. Vrátí (newMode, changed: true
    /// pokud došlo k transition po hysteresis gate). Volá CameraManager Timer 5 s.
    ///
    /// **Single lock cycle:** sample funkce (`sampleProcCpu`, `sampleSystemCpu`,
    /// `sampleRSS`) jsou lock-free — modifikují per-instance state ale ne
    /// shared snapshot. OCR p95 musí read shared `ocrLatencySamples` dict tak
    /// proto computeOcrP95LockHeld běží POD evaluate's lock (rebrání nutnosti
    /// 2 separate lock cyklů, eliminuje window pro race mezi nimi).
    @discardableResult
    func evaluate() -> (mode: BudgetMode, changed: Bool) {
        let procCpu = sampleProcCpu()
        let sysCpu = sampleSystemCpu()
        let thermal = ProcessInfo.processInfo.thermalState
        let rss = sampleRSS()

        lock.lock()
        defer { lock.unlock() }

        let p95 = computeOcrP95LockHeld()
        let candidate = classifyMode(procCpu: procCpu, sysCpu: sysCpu,
                                      thermal: thermal, ocrP95Ms: p95)
        let now = Date()
        let prevMode = snapshot.mode
        let dwellSinceChange = now.timeIntervalSince(lastModeChangeAt)
        snapshot.procCpuPercent = procCpu
        snapshot.systemCpuPercent = sysCpu
        snapshot.thermal = thermal
        snapshot.ocrP95Ms = p95
        snapshot.rssBytes = rss
        snapshot.timestamp = now
        snapshot.dwellSec = dwellSinceChange

        // Hysteresis gate.
        if candidate == prevMode {
            // Stable — reset pending counter.
            pendingMode = prevMode
            pendingCount = 0
            return (prevMode, false)
        }

        // Worse-direction = downgrade (e.g., normal → warm). Need 2 consecutive samples.
        // Better-direction = upgrade. Need 3.
        let isWorse = isWorse(candidate, than: prevMode)
        let requiredCount = isWorse ? 2 : 3

        if pendingMode == candidate {
            pendingCount += 1
        } else {
            pendingMode = candidate
            pendingCount = 1
        }

        // Min dwell time 30 s mezi changes.
        if dwellSinceChange < 30 {
            return (prevMode, false)
        }
        if pendingCount < requiredCount {
            return (prevMode, false)
        }
        // Promote to new mode.
        snapshot.mode = candidate
        lastModeChangeAt = now
        snapshot.dwellSec = 0
        pendingMode = candidate
        pendingCount = 0
        FileHandle.safeStderrWrite(
            "[ResourceBudget] mode \(prevMode.rawValue) → \(candidate.rawValue) proc=\(Int(procCpu))% sys=\(Int(sysCpu))% thermal=.\(thermalRawValue(thermal)) ocrP95=\(Int(p95))ms\n"
                .data(using: .utf8)!)
        return (candidate, true)
    }

    // MARK: - Classification

    private func classifyMode(procCpu: Double, sysCpu: Double,
                              thermal: ProcessInfo.ThermalState,
                              ocrP95Ms: Double) -> BudgetMode {
        // Worst signal wins.
        if procCpu >= 85 || sysCpu >= 90 || thermal == .serious || thermal == .critical || ocrP95Ms >= 150 {
            return .constrained
        }
        if procCpu >= 60 || sysCpu >= 70 || thermal == .fair || ocrP95Ms >= 100 {
            return .warm
        }
        return .normal
    }

    private func isWorse(_ a: BudgetMode, than b: BudgetMode) -> Bool {
        let order: [BudgetMode: Int] = [.normal: 0, .warm: 1, .constrained: 2]
        return (order[a] ?? 0) > (order[b] ?? 0)
    }

    private func thermalRawValue(_ t: ProcessInfo.ThermalState) -> String {
        switch t {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Multipliers

    /// Multiplier od mode → násobí base FPS v `AppState.effectiveDetectionFps`.
    static func multiplier(for mode: BudgetMode) -> Double {
        switch mode {
        case .normal: return 1.0
        case .warm: return 0.7
        case .constrained: return 0.45
        }
    }

    // MARK: - Sampling

    /// Proces CPU % delta mezi vzorky. macOS reporting convention:
    /// 100 % = jedno plně vytížené jádro, M4 může jít nad 100 % při více
    /// paralelních threadech. Rev 6 thresholdy `60/85` jsou záměrně v této
    /// per-process sum škále, ne normalizované přes počet core.
    private func sampleProcCpu() -> Double {
        var taskInfo = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let result = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &taskInfo, size)
        guard result == size else { return 0 }
        let totalNs = taskInfo.pti_total_user + taskInfo.pti_total_system
        let now = Date()

        if prevSampleWall == .distantPast {
            prevProcCpuTotal = totalNs
            prevSampleWall = now
            return 0  // first sample, no delta
        }
        let deltaNs = totalNs > prevProcCpuTotal ? Double(totalNs - prevProcCpuTotal) : 0
        let wallSec = now.timeIntervalSince(prevSampleWall)
        prevProcCpuTotal = totalNs
        prevSampleWall = now
        guard wallSec > 0.001 else { return 0 }

        // pti_total is sum across all threads in nanoseconds.
        let percentPerCore = (deltaNs / 1_000_000_000.0) / wallSec * 100.0
        return max(0.0, percentPerCore)
    }

    /// System-wide CPU % via `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`.
    /// Aggregates per-core ticks → user+system / total mezi sample intervaly.
    private func sampleSystemCpu() -> Double {
        var cpuCount: natural_t = 0
        var cpuLoadInfo: processor_info_array_t? = nil
        var cpuLoadInfoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(),
                                      PROCESSOR_CPU_LOAD_INFO,
                                      &cpuCount,
                                      &cpuLoadInfo,
                                      &cpuLoadInfoCount)
        guard kr == KERN_SUCCESS, let info = cpuLoadInfo else { return 0 }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: info),
                          vm_size_t(cpuLoadInfoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }

        var totalUser: UInt32 = 0, totalSystem: UInt32 = 0, totalIdle: UInt32 = 0, totalNice: UInt32 = 0
        for i in 0..<Int(cpuCount) {
            let base = i * Int(CPU_STATE_MAX)
            totalUser   &+= UInt32(bitPattern: info[base + Int(CPU_STATE_USER)])
            totalSystem &+= UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)])
            totalIdle   &+= UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)])
            totalNice   &+= UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
        }

        let prev = prevSystemCpuTicks
        prevSystemCpuTicks = (totalUser, totalSystem, totalIdle, totalNice)

        // First sample — no delta, return 0.
        if prev.user == 0 && prev.system == 0 && prev.idle == 0 {
            return 0
        }
        let dUser = Int64(totalUser) - Int64(prev.user)
        let dSys = Int64(totalSystem) - Int64(prev.system)
        let dIdle = Int64(totalIdle) - Int64(prev.idle)
        let dNice = Int64(totalNice) - Int64(prev.nice)
        let busy = max(0, dUser + dSys + dNice)
        let total = busy + max(0, dIdle)
        guard total > 0 else { return 0 }
        return Double(busy) / Double(total) * 100.0
    }

    private func sampleRSS() -> UInt64 {
        var taskInfo = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return taskInfo.resident_size
    }

    /// Compute p95 OCR latency napříč všemi kamerami. Caller MUSÍ HOLDOVAT lock —
    /// název bez `Locked` suffix protože ten suffix v Apple/Cocoa konvenci
    /// znamená "func acquires lock" (matoucí). Tahle funkce reads sdílený state
    /// PŘEDPOKLÁDÁ že caller už drží lock.
    private func computeOcrP95LockHeld() -> Double {
        var all: [Double] = []
        for samples in ocrLatencySamples.values { all.append(contentsOf: samples) }
        guard !all.isEmpty else { return 0 }
        all.sort()
        let idx = min(all.count - 1, Int(Double(all.count) * 0.95))
        return all[idx]
    }
}
