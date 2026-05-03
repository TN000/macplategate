import Foundation

/// Alert rule pro známé SPZ co nebyly viděny > N dní (Fáze 6 QoL).
///
/// Use case: firma má whitelist regulérních zákazníků. Pokud některý 30 dní
/// neprojel, pravděpodobně přestal chodit / odstěhoval se / incident. Admin
/// chce vědět → webhook fire + log.
///
/// **Trigger:** spouští se 1× denně (user-configurable hour) přes Task.sleep
/// loop. Check: pro každou known plate, query detections MAX(ts) → pokud
/// `Date().timeIntervalSince(lastSeen) > threshold`, emit alert.
///
/// **Dedup:** alert pro stejnou plate max jednou za 7 dní (aby user nespamoval).
/// Stav uložený v UserDefaults pod key `unseen_alert_last_fired_<plate>`.
///
/// **Flag:** opt-in `AppState.unseenPlateAlertsEnabled`.
final class UnseenPlateAlerter: @unchecked Sendable {
    static let shared = UnseenPlateAlerter()

    /// Threshold v dnech — SPZ nesmí být viděná déle než N dní.
    var thresholdDays: Int = 30
    /// Jak často spouštět scan. Default 1× za 24h.
    var scanIntervalSec: TimeInterval = 86400
    /// Dedup window per plate — stejný plate může fire max jednou za N dní.
    var dedupeWindowDays: Int = 7

    private var scanTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard

    @MainActor
    func start() {
        guard scanTask == nil else { return }
        let intervalNs = UInt64(self.scanIntervalSec * 1_000_000_000)
        scanTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                _ = await MainActor.run { self.runScan() }
                try? await Task.sleep(nanoseconds: intervalNs)
            }
        }
        FileHandle.safeStderrWrite(
            "[UnseenAlerter] started (threshold \(thresholdDays)d, scan every \(Int(scanIntervalSec))s)\n"
                .data(using: .utf8)!)
    }

    func stop() {
        scanTask?.cancel()
        scanTask = nil
    }

    /// Manual scan invocation (Settings button). Vrátí seznam platen co triggerovalo alert.
    @MainActor
    @discardableResult
    func runScan() -> [UnseenAlert] {
        // KnownPlates.entries is @Published on MainActor; direct read works here
        // protože jsme volaní z Task.detached bez actor isolation concerns
        // (KnownPlates je ObservableObject a entries.append/remove chodí přes
        // main thread, ale read-only snapshot uptedatuje stejným lockingem co
        // SwiftUI redraws — acceptable pro daily scan.
        let known = KnownPlates.shared.entries.map { $0.plate }
        guard !known.isEmpty else { return [] }

        let thresholdSec = Double(thresholdDays) * 86400
        let dedupeSec = Double(dedupeWindowDays) * 86400
        var fired: [UnseenAlert] = []

        for plate in known {
            // Query MAX(ts) for this plate
            let lastTsIso = Store.shared.querySingleString(
                sql: "SELECT MAX(ts) FROM detections WHERE plate = ?",
                params: [plate]
            )
            let iso = ISO8601DateFormatter()
            let lastSeen: Date? = lastTsIso.flatMap { iso.date(from: $0) }
            let age = lastSeen.map { Date().timeIntervalSince($0) } ?? Double.infinity

            guard age > thresholdSec else { continue }

            // Dedup — did we already fire for this plate recently?
            let key = "unseen_alert_fired_\(plate)"
            let lastFired = defaults.double(forKey: key)
            let secSinceLastFire = Date().timeIntervalSince1970 - lastFired
            if lastFired > 0 && secSinceLastFire < dedupeSec { continue }

            let alert = UnseenAlert(
                plate: plate,
                lastSeen: lastSeen,
                ageDays: Int(age / 86400)
            )
            fired.append(alert)
            defaults.set(Date().timeIntervalSince1970, forKey: key)

            // Log
            FileHandle.safeStderrWrite(
                "[UnseenAlerter] FIRE plate=\(plate) lastSeen=\(lastSeen.map { iso.string(from: $0) } ?? "never") ageDays=\(alert.ageDays)\n"
                    .data(using: .utf8)!)
        }

        return fired
    }
}

struct UnseenAlert: Sendable, Hashable {
    let plate: String
    let lastSeen: Date?
    let ageDays: Int
}
