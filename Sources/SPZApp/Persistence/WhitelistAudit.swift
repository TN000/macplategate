import Foundation

/// Append-only audit log pro všechny mutace whitelistu — add / update / delete /
/// CSV import / auto-expire. Účel: šéf se v budoucnu zeptá „kdo přidal tuhle SPZ
/// a kdy?" → `~/Library/Application Support/SPZ/whitelist-audit.log` má odpověď.
///
/// Formát řádky:
///   `2026-04-21T18:45:12Z\tADD\t4GH5678\tPPL\tsource=webUI\texpiry=2026-04-22T00:00:00Z`
///
/// Columns jsou tab-separated → grep-friendly. Soubor 0600, rotace manuální
/// (audit log by neměl růst do extrémů — typicky <1 MB/rok per plate-churn).
enum WhitelistAudit {
    /// Zdroj mutace — odlišuje UI klik vs CSV import vs remote webUI vs auto-purge.
    enum Source: String {
        case ui        // Settings → Known Plates form
        case webUI     // POST /api/add-daily
        case csv       // SettingsView → importCSV button
        case autoPurge // AppState maintenance timer → KnownPlates.pruneExpired()
        case api       // placeholder pro budoucí REST API
    }

    enum Action: String {
        case add = "ADD"
        case update = "UPDATE"
        case delete = "DELETE"
        case autoDelete = "AUTO_DELETE"  // expiry vypršela
        case csvImport = "CSV_IMPORT"    // summary řádka pro bulk CSV
    }

    private static var logURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("SPZ", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir.appendingPathComponent("whitelist-audit.log")
    }

    /// Thread-safe append — serializuje zápisy mezi potenciálními volajícími
    /// (KnownPlates z MainActor, ale WebServer.addDailyAction hopuje přes Task
    /// @MainActor → zde to není problém, nicméně lock je defensive).
    private static let writeLock = NSLock()

    /// Zapíše jeden záznam. Timestamp je UTC ISO-8601. Ignoruje chyby zápisu
    /// (nesmí blokovat whitelist mutaci; audit je best-effort, ne kritická cesta).
    static func log(_ action: Action, plate: String, label: String = "",
                    source: Source = .ui, expiresAt: Date? = nil, extra: String = "") {
        writeLock.lock(); defer { writeLock.unlock() }
        let iso = ISO8601DateFormatter()
        let ts = iso.string(from: Date())
        let expiryStr = expiresAt.map { iso.string(from: $0) } ?? ""
        // Escape tabs / newlines v user-controlled fields — defensive proti
        // injection co by rozbil parsing.
        func clean(_ s: String) -> String {
            s.replacingOccurrences(of: "\t", with: " ")
             .replacingOccurrences(of: "\n", with: " ")
             .replacingOccurrences(of: "\r", with: " ")
        }
        let line = "\(ts)\t\(action.rawValue)\t\(clean(plate))\t\(clean(label))\tsource=\(source.rawValue)\texpiry=\(expiryStr)\(extra.isEmpty ? "" : "\t\(extra)")\n"
        guard let data = line.data(using: .utf8) else { return }

        let url = logURL
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            // Vytvořit soubor + chmod 0600 před prvním zápisem (obsahuje SPZ = PII).
            fm.createFile(atPath: url.path, contents: nil,
                          attributes: [.posixPermissions: 0o600])
        } else {
            // Rotate při překročení 2 MB → whitelist-audit.log.1. Chrání proti
            // unbounded growth při CSV bulk imports + auto-expire churn na
            // dlouhém deploymentu. Staré .log.1 se overwrite nový rotací.
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int, size > 2_000_000 {
                let archive = url.deletingLastPathComponent()
                    .appendingPathComponent("whitelist-audit.log.1")
                _ = try? fm.removeItem(at: archive)
                _ = try? fm.moveItem(at: url, to: archive)
                fm.createFile(atPath: url.path, contents: nil,
                              attributes: [.posixPermissions: 0o600])
            }
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    /// Cestu vrátí pro UI (SettingsView může zobrazit "Audit log zde…" link).
    static var logPath: URL { logURL }
}
