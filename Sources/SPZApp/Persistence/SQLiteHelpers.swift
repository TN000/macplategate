import Foundation
import SQLite3

/// SQLite C API safe column accessors — extracted ze Store.swift jako součást
/// big-refactor split (krok #10 audit roadmap). Sdílené utility pro každý
/// SQLite-backed kód v projektu.
///
/// **Crash-safe pattern:** sqlite3_column_text vrací `UnsafePointer<UInt8>?`
/// — null pro SQL NULL, buffer pro hodnotu. Force-unwrap přes `String(cString:)`
/// padá SIGTRAP. Tyto wrappery vrací nil na NULL.

func columnText(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
    stmt?.textOrNil(idx)
}

func columnInt(_ stmt: OpaquePointer?, _ idx: Int32) -> Int? {
    stmt?.intOrNil(idx)
}

func columnDouble(_ stmt: OpaquePointer?, _ idx: Int32) -> Double? {
    stmt?.doubleOrNil(idx)
}

extension OpaquePointer {
    func textOrNil(_ idx: Int32) -> String? {
        guard sqlite3_column_type(self, idx) != SQLITE_NULL,
              let cstr = sqlite3_column_text(self, idx) else { return nil }
        return String(cString: cstr)
    }

    func intOrNil(_ idx: Int32) -> Int? {
        guard sqlite3_column_type(self, idx) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(self, idx))
    }

    func doubleOrNil(_ idx: Int32) -> Double? {
        guard sqlite3_column_type(self, idx) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(self, idx)
    }
}

/// SQLite bind helper — `SQLITE_TRANSIENT` říká SQLite že má udělat vlastní
/// kopii bytu (žádné lifecycle ownership na callerovi).
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thread-safe ISO8601 formatter wrapper. `ISO8601DateFormatter` není Sendable,
/// SPZ commit path běží paralelně (Task.detached pro persist), tj. přímý
/// `nonisolated(unsafe)` formatter byl race. NSLock zajistí serializaci
/// kolem `string(from:)` / `date(from:)` callů.
final class LockedISO8601DateFormatter: @unchecked Sendable {
    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: date)
    }

    func date(from string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return formatter.date(from: string)
    }
}
