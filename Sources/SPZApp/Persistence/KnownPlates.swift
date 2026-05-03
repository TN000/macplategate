import Foundation

/// Whitelist známých SPZ. Persistuje v ~/Library/Application Support/SPZ/known.json.
@MainActor
final class KnownPlates: ObservableObject {
    static let shared = KnownPlates()

    @Published private(set) var entries: [Entry] = []

    struct Entry: Codable, Identifiable, Hashable {
        let plate: String     // normalized form, e.g. "5T2 1234"
        let label: String     // "Honza Škoda"
        let added: Date
        /// Optional expiration date. nil = permanent (trvalý whitelist).
        /// Non-nil = denní vjezd / časově omezený průjezd, po tomto datu
        /// `match()` entry ignoruje a `pruneExpired()` ho fyzicky smaže.
        var expiresAt: Date? = nil
        /// Shadow-mode gate intent. Production ALPR still fires openShort until
        /// hardware + audit validation promotes this field to real action.
        var gateAction: String = GateAction.openShort.rawValue
        /// Shadow-mode flag for future auto hold-open while this car is present.
        var holdWhilePresent: Bool = false
        var id: String { plate }

        init(plate: String, label: String, added: Date,
             expiresAt: Date? = nil,
             gateAction: String = GateAction.openShort.rawValue,
             holdWhilePresent: Bool = false) {
            self.plate = plate
            self.label = label
            self.added = added
            self.expiresAt = expiresAt
            self.gateAction = Self.normalizedGateAction(gateAction)
            self.holdWhilePresent = holdWhilePresent
        }

        private enum CodingKeys: String, CodingKey {
            case plate, label, added, expiresAt, gateAction, holdWhilePresent
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            plate = try c.decode(String.self, forKey: .plate)
            label = try c.decode(String.self, forKey: .label)
            added = try c.decode(Date.self, forKey: .added)
            expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
            gateAction = Self.normalizedGateAction(
                try c.decodeIfPresent(String.self, forKey: .gateAction)
                    ?? GateAction.openShort.rawValue
            )
            holdWhilePresent = try c.decodeIfPresent(Bool.self, forKey: .holdWhilePresent) ?? false
        }

        private static func normalizedGateAction(_ raw: String) -> String {
            GateAction(rawValue: raw) == .openExtended
                ? GateAction.openExtended.rawValue
                : GateAction.openShort.rawValue
        }
    }

    private static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("SPZ", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir.appendingPathComponent("known.json")
    }

    private let url: URL

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        if let arr = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = arr
        }
    }

    private func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(entries) {
            try? SecureFile.writeAtomic(data, to: url)
        }
    }

    func add(plate: String, label: String, expiresAt: Date? = nil,
             auditSource: WhitelistAudit.Source = .ui) {
        // Strip VŠECH whitespace → no-space canonical. Pipeline/tracker/recents
        // používají canonical bez mezer ("4GH5678"), match by selhal pokud
        // uživatel zadá s mezerou ("5T2 1234").
        let norm = plate.uppercased()
            .components(separatedBy: .whitespacesAndNewlines).joined()
        guard !norm.isEmpty else { return }
        // Pokud už existuje, jen aktualizuj expiresAt (např. user přidá denní
        // vjezd pro SPZ, která tam už je jako trvalá — prodluž ji, ne duplikuj).
        if let idx = entries.firstIndex(where: { $0.plate == norm }) {
            if let newExp = expiresAt {
                let old = entries[idx]
                // Permanentní (expiresAt=nil) má přednost před časově omezeným.
                if old.expiresAt != nil {
                    entries[idx] = Entry(plate: old.plate, label: label.isEmpty ? old.label : label,
                                         added: old.added, expiresAt: newExp,
                                         gateAction: old.gateAction,
                                         holdWhilePresent: old.holdWhilePresent)
                    save()
                    WhitelistAudit.log(.update, plate: norm,
                                       label: label.isEmpty ? old.label : label,
                                       source: auditSource, expiresAt: newExp)
                }
            }
            return
        }
        entries.append(Entry(plate: norm, label: label, added: Date(), expiresAt: expiresAt))
        save()
        WhitelistAudit.log(.add, plate: norm, label: label,
                           source: auditSource, expiresAt: expiresAt)
    }

    func updateGateOptions(plate: String, gateAction: String? = nil, holdWhilePresent: Bool? = nil) {
        let norm = plate.uppercased()
            .components(separatedBy: .whitespacesAndNewlines).joined()
        guard let idx = entries.firstIndex(where: { $0.plate == norm }) else { return }
        let old = entries[idx]
        entries[idx] = Entry(
            plate: old.plate,
            label: old.label,
            added: old.added,
            expiresAt: old.expiresAt,
            gateAction: gateAction ?? old.gateAction,
            holdWhilePresent: holdWhilePresent ?? old.holdWhilePresent
        )
        save()
        WhitelistAudit.log(.update, plate: norm, label: old.label, source: .ui,
                           expiresAt: old.expiresAt,
                           extra: "gateAction=\(entries[idx].gateAction) holdWhilePresent=\(entries[idx].holdWhilePresent)")
    }

    func remove(plate: String, auditSource: WhitelistAudit.Source = .ui) {
        let before = entries.count
        let removed = entries.first(where: { $0.plate == plate })
        entries.removeAll { $0.plate == plate }
        guard before != entries.count else { return }  // plate nebyla v seznamu
        save()
        WhitelistAudit.log(.delete, plate: plate,
                           label: removed?.label ?? "", source: auditSource)
        // Zahoď všechny parkovací sessions pro tuto SPZ (whitelist-only pravidlo).
        let purged = Store.shared.purgeSessions(plate: plate)
        FileHandle.safeStderrWrite(
            "[KnownPlates] removed plate=\(plate), purged \(purged) parking session(s)\n"
                .data(using: .utf8)!)
    }

    /// Smaže všechny orphan sessions (pro SPZ, které už nejsou v whitelistu).
    /// Voláno při startu aplikace — cleanup po změně pravidla „parking pouze
    /// whitelisted".
    func purgeOrphanSessions() {
        Store.shared.purgeSessionsNotIn(plates: entries.map { $0.plate })
    }

    /// CSV export — formát `plate,label,added_iso8601,expires_iso8601`.
    /// Header řádek včetně. Hodnoty escapované dle RFC 4180.
    func exportCSV(to url: URL) throws {
        func esc(_ s: String) -> String {
            if s.contains(",") || s.contains("\"") || s.contains("\n") {
                return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return s
        }
        let iso = ISO8601DateFormatter()
        var csv = "plate,label,added,expires,gate_action,hold_while_present\n"
        for e in entries {
            let expiresStr = e.expiresAt.map { iso.string(from: $0) } ?? ""
            csv += "\(esc(e.plate)),\(esc(e.label)),\(iso.string(from: e.added)),\(expiresStr),\(e.gateAction),\(e.holdWhilePresent)\n"
        }
        try csv.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    /// CSV import — tolerantní: přeskočí prázdné/malformed řádky. Existující
    /// SPZ se přepíše (label + expiresAt). Vrací (added, updated, skipped).
    @discardableResult
    func importCSV(from url: URL) throws -> (added: Int, updated: Int, skipped: Int) {
        let raw = try String(contentsOf: url, encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let iso = ISO8601DateFormatter()
        var added = 0, updated = 0, skipped = 0
        for (i, rawLine) in lines.enumerated() {
            if i == 0 && rawLine.lowercased().contains("plate") { continue }  // skip header
            let cols = parseCSVLine(rawLine)
            guard let plateRaw = cols.first, !plateRaw.isEmpty else { skipped += 1; continue }
            let plate = plateRaw.uppercased()
                .components(separatedBy: .whitespacesAndNewlines).joined()
            let label = cols.count > 1 ? cols[1] : plate
            let expiresAt: Date? = cols.count > 3 && !cols[3].isEmpty ? iso.date(from: cols[3]) : nil
            let importedGateAction = cols.count > 4 && !cols[4].isEmpty ? cols[4] : nil
            let importedHoldWhilePresent: Bool? = cols.count > 5
                ? ["1", "true", "yes", "ano"].contains(cols[5].trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                : nil
            if let idx = entries.firstIndex(where: { $0.plate == plate }) {
                let old = entries[idx]
                entries[idx] = Entry(plate: plate, label: label,
                                     added: old.added, expiresAt: expiresAt,
                                     gateAction: importedGateAction ?? old.gateAction,
                                     holdWhilePresent: importedHoldWhilePresent ?? old.holdWhilePresent)
                updated += 1
            } else {
                entries.append(Entry(plate: plate, label: label, added: Date(), expiresAt: expiresAt,
                                     gateAction: importedGateAction ?? GateAction.openShort.rawValue,
                                     holdWhilePresent: importedHoldWhilePresent ?? false))
                added += 1
            }
        }
        save()
        // Summary řádka místo per-entry logů — CSV import bývá bulk (desítky SPZ)
        // a zahlcoval by audit log. Detail per plate je v případě potřeby v CSV.
        WhitelistAudit.log(.csvImport, plate: "-", label: "-", source: .csv,
                           extra: "file=\(url.lastPathComponent) added=\(added) updated=\(updated) skipped=\(skipped)")
        return (added, updated, skipped)
    }

    /// RFC 4180 parser — minimal, podporuje quoted fields s zdvojenými uvozovkami.
    private func parseCSVLine(_ line: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inQuotes = false
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if c == "\"" {
                if inQuotes, line.index(after: i) < line.endIndex, line[line.index(after: i)] == "\"" {
                    cur.append("\"")
                    i = line.index(i, offsetBy: 2)
                    continue
                }
                inQuotes.toggle()
            } else if c == "," && !inQuotes {
                out.append(cur); cur = ""
            } else {
                cur.append(c)
            }
            i = line.index(after: i)
        }
        out.append(cur)
        return out
    }

    /// Levenshtein-1 tolerance (analýza recommend) — povolí jeden char rozdíl.
    /// Expired entries (expiresAt v minulosti) jsou ignorované.
    func match(_ plate: String) -> Entry? {
        let p = plate.uppercased()
        let now = Date()
        let active = entries.filter { $0.expiresAt == nil || $0.expiresAt! > now }
        if let exact = active.first(where: { $0.plate == p }) { return exact }
        for e in active {
            if levenshtein(e.plate, p) <= 1 { return e }
        }
        return nil
    }

    /// Smaže všechny entries s expiresAt v minulosti. Voláno periodicky
    /// (AppState maintenance timer) + při startu.
    func pruneExpired() {
        let now = Date()
        // Zachytit smazané entries pro audit (po removeAll už nejsou dostupné).
        let expired = entries.filter { entry in
            guard let exp = entry.expiresAt else { return false }
            return exp <= now
        }
        guard !expired.isEmpty else { return }
        entries.removeAll { entry in
            guard let exp = entry.expiresAt else { return false }
            return exp <= now
        }
        save()
        for entry in expired {
            WhitelistAudit.log(.autoDelete, plate: entry.plate,
                               label: entry.label, source: .autoPurge,
                               expiresAt: entry.expiresAt)
        }
    }

    private func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a), bChars = Array(b)
        let m = aChars.count, n = bChars.count
        if m == 0 { return n }; if n == 0 { return m }
        var prev = Array(0...n), cur = [Int](repeating: 0, count: n + 1)
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
}
