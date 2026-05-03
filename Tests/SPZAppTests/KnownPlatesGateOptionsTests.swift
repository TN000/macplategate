import Foundation
import Testing
@testable import SPZApp

@Suite("KnownPlates gate options")
struct KnownPlatesGateOptionsTests {
    @Test func decodeLegacyEntryDefaultsToSafeGateOptions() throws {
        let json = """
        {
          "plate": "2ZB5794",
          "label": "Test",
          "added": "2026-05-01T07:00:00Z"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(KnownPlates.Entry.self, from: json)

        #expect(entry.gateAction == GateAction.openShort.rawValue)
        #expect(entry.holdWhilePresent == false)
    }

    @Test func decodeInvalidGateActionFallsBackToOpenShort() throws {
        let json = """
        {
          "plate": "2ZB5794",
          "label": "Test",
          "added": "2026-05-01T07:00:00Z",
          "gateAction": "openHoldBeat",
          "holdWhilePresent": true
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(KnownPlates.Entry.self, from: json)

        #expect(entry.gateAction == GateAction.openShort.rawValue)
        #expect(entry.holdWhilePresent)
    }

    @Test func openExtendedIsPreservedForShadowAudit() {
        let entry = KnownPlates.Entry(plate: "BUS1234",
                                      label: "Bus",
                                      added: Date(timeIntervalSince1970: 0),
                                      gateAction: GateAction.openExtended.rawValue,
                                      holdWhilePresent: true)

        #expect(entry.gateAction == GateAction.openExtended.rawValue)
        #expect(entry.holdWhilePresent)
    }

    @MainActor
    @Test func legacyCSVImportPreservesExistingGateOptions() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spz-known-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let knownURL = dir.appendingPathComponent("known.json")
        let csvURL = dir.appendingPathComponent("legacy.csv")
        let encoder = JSONEncoder()
        let existing = KnownPlates.Entry(plate: "BUS1234",
                                         label: "Old bus label",
                                         added: Date(timeIntervalSince1970: 0),
                                         gateAction: GateAction.openExtended.rawValue,
                                         holdWhilePresent: true)
        try encoder.encode([existing]).write(to: knownURL)
        try "plate,label,added,expires\nBUS1234,New label,2026-05-01T07:00:00Z,\n"
            .write(to: csvURL, atomically: true, encoding: .utf8)

        let known = KnownPlates(url: knownURL)
        let result = try known.importCSV(from: csvURL)

        #expect(result.updated == 1)
        #expect(known.entries.count == 1)
        #expect(known.entries[0].label == "New label")
        #expect(known.entries[0].gateAction == GateAction.openExtended.rawValue)
        #expect(known.entries[0].holdWhilePresent)
    }
}
