import Foundation

/// User-curated „mark wrong" override pro snapshot replay engine.
/// Replay porovnává OCR predicted vs DB plate (committed text). Pokud
/// uživatel ví že DB plate byl chybně přečtený („0ZC0779" měl být „7MN8901"),
/// označí přes UI → append do JSONL → replay engine pak používá `truePlate`
/// místo DB textu jako effective ground truth pro tu konkrétní položku.
struct ReplayOverride: Codable, Equatable {
    let snapshotPath: String
    let truePlate: String
    let markedAt: Date
}

/// Centralizovaný atomic store pro `replay-overrides.jsonl`. Žádný direct
/// file write z UI — všechny zápisy přes tento helper kvůli:
/// - serial dispatch (atomic vs concurrent SwiftUI handlery),
/// - chmod 0600 (PII privacy),
/// - normalization snapshot path (absolute / relative / basename / `.raw.heic` strip),
/// - dedupe při loadu (poslední override per path je effective, starší overlay-ed).
enum ReplayOverrideStore {

    private static let queue = DispatchQueue(label: "spz.replay.overrides", qos: .utility)

    /// Default JSONL path — `~/Library/Application Support/SPZ/replay-overrides.jsonl`.
    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("SPZ", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir.appendingPathComponent("replay-overrides.jsonl")
    }

    /// Append override jako JSON řádek. Serial queue zajistí atomic mezi
    /// concurrent volání. Souboru nastaví chmod 0600 při prvním zápisu.
    /// Path se normalizuje (absolute standardized) PŘED zápisem.
    static func append(_ override: ReplayOverride, to url: URL = defaultURL) {
        let normalized = ReplayOverride(
            snapshotPath: normalizePath(override.snapshotPath),
            truePlate: override.truePlate.uppercased(),
            markedAt: override.markedAt
        )
        queue.async {
            writeLine(normalized, to: url)
        }
    }

    /// Synchronní variant — pro tests + CLI scenarios kde caller drží control flow.
    static func appendSync(_ override: ReplayOverride, to url: URL = defaultURL) {
        let normalized = ReplayOverride(
            snapshotPath: normalizePath(override.snapshotPath),
            truePlate: override.truePlate.uppercased(),
            markedAt: override.markedAt
        )
        queue.sync {
            writeLine(normalized, to: url)
        }
    }

    /// Načte všechny overrides + dedupe (poslední per path vyhrává).
    /// Vrací keyed dict pro O(1) lookup. Tolerantní matching v `effectiveOverride(for:)`.
    static func loadEffective(from url: URL = defaultURL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let str = String(data: data, encoding: .utf8) else { return [:] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var result: [String: String] = [:]
        // Iterate radky → pozdější přepíše dřívější. Same path multiple writes:
        // poslední je effective (dedupe by overwrite).
        for line in str.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let entry = try? dec.decode(ReplayOverride.self, from: lineData) else {
                continue
            }
            result[entry.snapshotPath] = entry.truePlate
        }
        return result
    }

    /// Tolerantní lookup: zkusí standardized absolute, lastPathComponent,
    /// případně bez `.raw.heic` suffixu (raw sidecar vs preprocessed snapshot).
    /// Používá v SnapshotReplay engine kde DB `snapshot_path` může být
    /// uložen v různých formátech přes čas.
    static func effectiveOverride(for snapshotPath: String,
                                  in overrides: [String: String]) -> String? {
        // 1) Try as-is (standardized absolute)
        let std = normalizePath(snapshotPath)
        if let hit = overrides[std] { return hit }
        // 2) Try lastPathComponent
        let basename = (std as NSString).lastPathComponent
        for (key, value) in overrides where (key as NSString).lastPathComponent == basename {
            return value
        }
        // 3) Try without .raw.heic suffix (raw sidecar → preprocessed snapshot pair)
        let stripped = basename.replacingOccurrences(of: ".raw.heic", with: ".heic")
        if stripped != basename {
            for (key, value) in overrides where (key as NSString).lastPathComponent == stripped {
                return value
            }
        }
        return nil
    }

    // MARK: - Internal

    /// Standardize path → absolute, resolved symlinks. Empty/relative inputs
    /// jsou vráceny as-is (caller je matchne přes lastPathComponent fallback).
    static func normalizePath(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        let url = URL(fileURLWithPath: path)
        return url.standardizedFileURL.path
    }

    private static func writeLine(_ override: ReplayOverride, to url: URL) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let json = try? enc.encode(override),
              var line = String(data: json, encoding: .utf8) else { return }
        line += "\n"
        guard let lineData = line.data(using: .utf8) else { return }

        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            // První zápis — vytvořit s chmod 0600 (PII: contains plate corrections).
            fm.createFile(atPath: url.path, contents: nil,
                          attributes: [.posixPermissions: 0o600])
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: lineData)
        }
    }
}
