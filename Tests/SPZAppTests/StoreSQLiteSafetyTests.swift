import SQLite3
import Testing
@testable import SPZApp

@Suite("Store SQLite safety")
struct StoreSQLiteSafetyTests {
    enum SQLiteTestError: Error {
        case openFailed
        case execFailed(String)
        case prepareFailed
        case noRow
    }

    @Test func safeColumnHelpersReturnNilForNull() throws {
        let (db, stmt) = try makeStatement(sql: "SELECT NULL, 42, 1.25")
        defer {
            sqlite3_finalize(stmt)
            sqlite3_close(db)
        }

        #expect(stmt.textOrNil(0) == nil)
        #expect(stmt.intOrNil(0) == nil)
        #expect(stmt.doubleOrNil(0) == nil)
        #expect(columnText(stmt, 0) == nil)
        #expect(columnInt(stmt, 1) == 42)
        #expect(columnDouble(stmt, 2) == 1.25)
    }

    @Test func nullableSessionEntryDecodeDoesNotTrap() throws {
        let (db, stmt) = try makeStatement(sql: "SELECT NULL")
        defer {
            sqlite3_finalize(stmt)
            sqlite3_close(db)
        }

        let decoded = stmt.textOrNil(0).flatMap { Store.sharedISO8601.date(from: $0) }
        #expect(decoded == nil)
    }

    private func makeStatement(sql: String) throws -> (OpaquePointer, OpaquePointer) {
        var db: OpaquePointer?
        guard sqlite3_open(":memory:", &db) == SQLITE_OK, let db else {
            throw SQLiteTestError.openFailed
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              let stmt else {
            sqlite3_close(db)
            throw SQLiteTestError.prepareFailed
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            sqlite3_finalize(stmt)
            sqlite3_close(db)
            throw SQLiteTestError.noRow
        }
        return (db, stmt)
    }
}
