import Foundation

/// Detekce SPZ crash reportů (`~/Library/Logs/DiagnosticReports/SPZ-*.ips`)
/// při startupu a fire ribbon notifikace.
///
/// **Strategie:** macOS apple-internal crash reporter ukládá `.ips` (JSON)
/// soubory pro každý crash. Při startupu SPZ skenneme adresář, najdeme reporty
/// novější než N hodin (default 24h), parsneme `name + sourceFile + symbol`
/// z prvního crashed thread frame a pošleme single ribbon "Recent crash detected".
///
/// **Dedupe:** držíme `lastSeenCrashTimestamp` v UserDefaults — nezobrazíme
/// znovu crash co jsme už user-notifyovali.
@MainActor
enum CrashReporterRibbon {
    private static let defaultsKey = "spz.lastSeenCrashTimestamp"
    private static let scanWindowHours: Double = 24

    /// Volá se 1× při startupu (SPZApp.didFinishLaunching). Pokud najde nový
    /// crash report, fire ErrorNotifier.healthWarning ribbon.
    static func scanAtStartup() {
        let reports = recentReports()
        guard let mostRecent = reports.first else { return }

        let lastSeen = UserDefaults.standard.double(forKey: defaultsKey)
        let crashTs = mostRecent.timestamp.timeIntervalSince1970
        guard crashTs > lastSeen else { return }

        UserDefaults.standard.set(crashTs, forKey: defaultsKey)

        let summary = mostRecent.summary ?? "Unknown crash"
        let body = "Posledni crash @ \(formatTimestamp(mostRecent.timestamp)): \(summary)"
        ErrorNotifier.fire(.healthWarning,
                           title: "Detekovan nedavny crash",
                           body: body)
        FileHandle.safeStderrWrite(
            "[CrashReporterRibbon] \(body)\n".data(using: .utf8) ?? Data())
    }

    private struct CrashReport {
        let url: URL
        let timestamp: Date
        let summary: String?
    }

    private static func recentReports() -> [CrashReport] {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }
        let cutoff = Date().addingTimeInterval(-scanWindowHours * 3600)
        let prefix = "SPZ-"
        let suffix = ".ips"

        return entries.compactMap { url -> CrashReport? in
            let name = url.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
            let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date.distantPast
            guard modDate >= cutoff else { return nil }
            return CrashReport(url: url, timestamp: modDate,
                               summary: extractSummary(from: url))
        }.sorted { $0.timestamp > $1.timestamp }
    }

    /// `.ips` má JSON header (1. řádek metadata) + JSON body. Symbol z prvního
    /// crashed thread frame je nejlépe interpretovatelný řetězec pro ribbon.
    private static func extractSummary(from url: URL) -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // Body je 2.+ řádek (header je single-line JSON).
        let lines = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard lines.count == 2,
              let bodyData = String(lines[1]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return nil
        }
        if let exception = json["exception"] as? [String: Any],
           let type = exception["type"] as? String {
            return type
        }
        if let threads = json["threads"] as? [[String: Any]],
           let triggered = threads.first(where: { ($0["triggered"] as? Bool) == true }),
           let frames = triggered["frames"] as? [[String: Any]],
           let symbol = frames.first?["symbol"] as? String {
            return symbol
        }
        return nil
    }

    private static func formatTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }
}
