import Foundation

/// Centralizované firing notifikací pro kritické provozní chyby — camera
/// disconnect, webhook selhání, SQLite write error, RTSP unreachable delší čas.
///
/// **Dedupe**: každý typ alertu má svůj sliding-window guard — pokud se stav
/// nezměnil, dalších N sekund nepostujeme. Bez tohoto by 60 sekundový výpadek
/// kamery generoval 60 notifikací.
///
/// **Silence po auto-recovery**: při camera-back / webhook-success se
/// dedupe state resetuje, takže příští výpadek user uvidí.
@MainActor
enum ErrorNotifier {
    /// Kategorizace — per-kategorie dedupe state.
    enum Kind: String {
        case cameraDown         // camera disconnect >60s
        case webhookFailure     // 3× sequential HTTP fail po retry
        case sqliteError        // DB write error
        case rtspUnreachable    // RTSP reconnect loop >5min
        case healthWarning      // souhrnný warning z HealthMonitor (disk, WAL)
        case webUIInsecurePassword  // webUI start refused — empty/default password
        case auditLogUnavailable    // Audit JSONL write fail (disk full, perms)
    }

    /// Last-posted per-kind timestamp — zabraňuje spamu.
    /// 300 s (5 min) re-alert okno = user dostane reminder kdyby zmeškal první.
    private static var lastPostTs: [Kind: Date] = [:]
    private static let rePostAfter: TimeInterval = 300

    /// Fire notifikaci pokud tato kind-stav kombinace nebyla fired v posledních
    /// `rePostAfter` sekundách. Thread: MainActor (NotificationHelper také).
    ///
    /// Dedupe timestamp se stamp-uje AŽ po potvrzené doručení notifikace do
    /// UserNotifications — bez tohoto by při prvním launche před user auth
    /// grant stampl timestamp i pro undelivered posty a dalších 5 min by
    /// se nic nezobrazilo. `postAsync` vrací Bool success.
    static func fire(_ kind: Kind, title: String, body: String) {
        let now = Date()
        if let last = lastPostTs[kind], now.timeIntervalSince(last) < rePostAfter {
            return
        }
        FileHandle.safeStderrWrite(
            "[ErrorNotifier] \(kind.rawValue): \(title) — \(body)\n".data(using: .utf8)!)
        Task { @MainActor in
            let delivered = await NotificationHelper.postAsync(title: title, body: body)
            if delivered {
                lastPostTs[kind] = now
            }
        }
    }

    /// Reset dedupe state pro danou kategorii — voláme při úspěšné recovery
    /// (camera reconnect, webhook success, DB write success). Bez tohoto
    /// by user po krátkém blikání (<5 min) o další výpadek nedostal alert.
    static func clear(_ kind: Kind) {
        lastPostTs.removeValue(forKey: kind)
    }
}
