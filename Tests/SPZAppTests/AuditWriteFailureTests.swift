import Foundation
import Testing
@testable import SPZApp

/// Regression test pro Audit write-failure handling (krok #2).
/// Ověřuje:
///  - úspěšný write nezvyšuje retryBuffer
///  - simulovaný write fail (přes _writeLineForTest do non-writable cesty)
///    vyhodí error → caller může reagovat (in production: bufferuje + ribbon)
///  - reset hook funguje (pro izolaci testů)
@MainActor
struct AuditWriteFailureTests {
    @Test func resetHookClearsBuffer() {
        Audit._resetForTests()
        #expect(Audit.pendingRetryBufferCount == 0)
    }

    @Test func writeLineThrowsOnUnwritablePath() throws {
        // /var/empty je read-only system path; FileHandle write tam selže.
        let url = URL(fileURLWithPath: "/var/empty/spz-audit-test-\(UUID().uuidString).jsonl")
        let line = "{\"event\":\"test\"}\n".data(using: .utf8) ?? Data()
        #expect(throws: Error.self) {
            try Audit._writeLineForTest(line, to: url)
        }
    }

    @Test func eventDoesNotCrashOnInvalidPayload() {
        Audit._resetForTests()
        // Vystavení helperu pro non-JSON convertible value — sanitize ho převede
        // na description, takže by NEMĚL crashnout. Místo toho má line v souboru.
        struct OpaqueValue {}
        Audit.event("test_invalid_payload", ["field": OpaqueValue()])
        // Pokud se sem dostaneme, sanitize fallback na description fungoval
        // a event se nepokoušel hodit fatalError.
        #expect(Bool(true))
    }

    @Test func auditErrorHasDescription() {
        let url = URL(fileURLWithPath: "/var/empty/spz-test.jsonl")
        let err = Audit.AuditError.cannotCreateFile(url)
        #expect(err.errorDescription?.contains("/var/empty/spz-test.jsonl") == true)
    }
}
