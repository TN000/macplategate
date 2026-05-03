import Foundation

/// Append-only JSONL audit log pro Pipeline / Tracker / persist events.
///
/// Účel: každý důležitý moment v plate-detection cestě (Tracker rozhodnutí o
/// commitu, Pipeline.commit volání, dedup drop, Store.persist výsledek, gate
/// open, atd.) zapsat jako strukturovaný JSON řádek do
/// `~/Library/Application Support/SPZ/audit.jsonl`. Důvod: stderr `spz.log` je
/// grep-friendly ale neparsable robustně — jq / SQLite-import přes JSONL umí
/// pivot tabulky, heatmapy missů, regression replay.
///
/// Formát řádky (každý řádek = jeden event):
///   `{"ts":"...","event":"pipeline_commit","camera":"vyjezd","plate":"3ZD9208","hits":1,"path":"fast-single","region":"CZ"}`
///
/// Soubor 0600, rotace při překročení 5 MB → `audit.jsonl.1`.
///
/// **Write-failure handling:** každý write error přidá event do `retryBuffer`
/// (cap 1000), fire `ErrorNotifier.auditLogUnavailable` ribbon, a další úspěšný
/// `event()` flushne buffer first. Při overflow se nejstarší dropnou + emituje
/// single `audit_buffer_overflow` interní event. Bez tohoto by silent IO failure
/// (disk full / perms drop / FS readonly) znamenal silent loss of audit events.
enum Audit {
    private static let writeLock = NSLock()
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current   // CEST = +02:00 (DST aware), pohled v lokálním čase
        return f
    }()

    /// Buffer pending eventů co zatím nešly zapsat (write fail). Drží `(timestamp,
    /// JSON line bytes)` aby ts zůstal authentický (ne posunutý čas retry).
    private static var retryBuffer: [Data] = []
    private static let retryBufferCap: Int = 1000
    /// 1-shot flag pro overflow event — pokud buffer přeteče opakovaně, emit
    /// `audit_buffer_overflow` jen jednou per session (zarezervujeme slot v bufferu
    /// pro samotný overflow event).
    private static var overflowEmitted: Bool = false
    /// 1-shot ribbon flag — fire ErrorNotifier jen 1× per error session, recovery
    /// (úspěšný write) ho resetuje.
    private static var ribbonActive: Bool = false

    private static var logURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = base.appendingPathComponent("SPZ", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir.appendingPathComponent("audit.jsonl")
    }

    /// Zapíše jeden event. Klíče `ts` a `event` jsou injekované, ostatní z `fields`.
    /// Jsonifies hodnoty defenzivně — nepodporované typy fallbacknou na string description.
    /// Při IO selhání zařadí event do `retryBuffer` a vystřelí ribbon.
    static func event(_ name: String, _ fields: [String: Any] = [:]) {
        writeLock.lock(); defer { writeLock.unlock() }
        var payload: [String: Any] = ["ts": isoFormatter.string(from: Date()), "event": name]
        for (k, v) in fields { payload[k] = sanitize(v) }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        var lineData = data
        lineData.append(0x0A)  // \n
        appendOrBuffer(lineData)
    }

    /// Vrátí kopii pending bufferu — pro tests + diagnostics. Hot path nepoužívá.
    static var pendingRetryBufferCount: Int {
        writeLock.lock(); defer { writeLock.unlock() }
        return retryBuffer.count
    }

    /// Pokus o append do souboru. Při fail: do retryBufferu + ribbon. Při success:
    /// flush případného retry bufferu a recovery ribbon.
    private static func appendOrBuffer(_ lineData: Data) {
        let url = logURL
        let fm = FileManager.default
        do {
            try ensureFileExists(url: url, fm: fm)
            try rotateIfTooLarge(url: url, fm: fm)
            try writeLine(lineData, to: url)
            // Úspěch — pokud byl buffer, flushni ho.
            if !retryBuffer.isEmpty {
                flushRetryBufferLocked(url: url)
            }
            if ribbonActive {
                ribbonActive = false
                // Reset dedupe tak, aby další výpadek user uviděl.
                Task { @MainActor in ErrorNotifier.clear(.auditLogUnavailable) }
            }
        } catch {
            bufferEvent(lineData, error: error)
        }
    }

    private static func bufferEvent(_ lineData: Data, error: Error) {
        if retryBuffer.count >= retryBufferCap {
            // Drop oldest. Emit single overflow event (samo se buffrne, ale je
            // markovaný flagom aby se neopakoval).
            retryBuffer.removeFirst()
            if !overflowEmitted {
                overflowEmitted = true
                if let overflow = makeOverflowMarker() {
                    retryBuffer.append(overflow)
                }
            }
        }
        retryBuffer.append(lineData)
        fireRibbonIfNeeded(error: error)
    }

    private static func makeOverflowMarker() -> Data? {
        let payload: [String: Any] = [
            "ts": isoFormatter.string(from: Date()),
            "event": "audit_buffer_overflow",
            "cap": retryBufferCap
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return nil
        }
        data.append(0x0A)
        return data
    }

    private static func fireRibbonIfNeeded(error: Error) {
        guard !ribbonActive else { return }
        ribbonActive = true
        let detail = "\(error.localizedDescription) — buffer=\(retryBuffer.count)/\(retryBufferCap)"
        Task { @MainActor in
            ErrorNotifier.fire(.auditLogUnavailable,
                               title: "Audit log nelze zapsat",
                               body: detail)
        }
        FileHandle.safeStderrWrite(
            "[Audit] write failed (\(detail)). Events buffered.\n".data(using: .utf8) ?? Data())
    }

    /// Flush volající MUSÍ držet `writeLock`. Pokusí se zapsat všechny buffrované
    /// eventy. Pokud znovu selže, ponechá zbylou frontu.
    private static func flushRetryBufferLocked(url: URL) {
        guard !retryBuffer.isEmpty else { return }
        let snapshot = retryBuffer
        retryBuffer.removeAll(keepingCapacity: true)
        var failedFromIndex: Int?
        for (idx, line) in snapshot.enumerated() {
            do {
                try writeLine(line, to: url)
            } catch {
                failedFromIndex = idx
                break
            }
        }
        if let from = failedFromIndex {
            // Nepodařené i následující zařadit zpět na začátek bufferu.
            retryBuffer.insert(contentsOf: snapshot[from...], at: 0)
            // Trim cap pokud nutné.
            while retryBuffer.count > retryBufferCap {
                retryBuffer.removeFirst()
            }
            return
        }
        FileHandle.safeStderrWrite(
            "[Audit] retry buffer flushed (\(snapshot.count) events).\n".data(using: .utf8) ?? Data())
        overflowEmitted = false
    }

    private static func ensureFileExists(url: URL, fm: FileManager) throws {
        if fm.fileExists(atPath: url.path) { return }
        let ok = fm.createFile(atPath: url.path, contents: nil,
                               attributes: [.posixPermissions: 0o600])
        if !ok {
            throw AuditError.cannotCreateFile(url)
        }
    }

    private static func rotateIfTooLarge(url: URL, fm: FileManager) throws {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > 5_000_000 else { return }
        let archive = url.deletingLastPathComponent()
            .appendingPathComponent("audit.jsonl.1")
        try? fm.removeItem(at: archive)
        try fm.moveItem(at: url, to: archive)
        let ok = fm.createFile(atPath: url.path, contents: nil,
                               attributes: [.posixPermissions: 0o600])
        if !ok {
            throw AuditError.cannotCreateFile(url)
        }
    }

    private static func writeLine(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// JSONSerialization akceptuje String/Number/Bool/Array/Dict/NSNull. Ostatní
    /// (např. Float, Int8, custom enum) převedeme přes description aby zápis
    /// neselhal a event se neztratil.
    private static func sanitize(_ v: Any) -> Any {
        switch v {
        case let s as String: return s
        case let b as Bool: return b
        case let i as Int: return i
        case let i as Int32: return Int(i)
        case let i as Int64: return Int(i)
        case let d as Double: return d.isFinite ? d : "\(d)"
        case let f as Float: return Float(f).isFinite ? Double(f) : "\(f)"
        case let arr as [Any]: return arr.map { sanitize($0) }
        case let dict as [String: Any]: return dict.mapValues { sanitize($0) }
        default: return String(describing: v)
        }
    }

    static var logPath: URL { logURL }

    enum AuditError: Error, LocalizedError {
        case cannotCreateFile(URL)
        var errorDescription: String? {
            switch self {
            case .cannotCreateFile(let url):
                return "Cannot create audit log file at \(url.path)"
            }
        }
    }
}

#if DEBUG
/// Test-only hooks pro StoreSQLiteSafetyTests-style regression coverage.
extension Audit {
    static func _resetForTests() {
        writeLock.lock(); defer { writeLock.unlock() }
        retryBuffer.removeAll()
        overflowEmitted = false
        ribbonActive = false
    }

    /// Force-write JSONL line to a custom URL — used by tests to simulate
    /// write failure (set URL to a non-writable path).
    static func _writeLineForTest(_ line: Data, to url: URL) throws {
        try writeLine(line, to: url)
    }
}
#endif
