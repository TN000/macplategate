import Testing
import Foundation
@testable import SPZApp

/// Phase A unit tests — focus na **klasifikační logiku + storage helpers**.
/// Ne real OCR run (Vision na synthetic plate je flaky a CI-unstable). Real
/// OCR validation je smoke test přes CLI: `swift run SPZApp replay-snapshots`.
@Suite("SnapshotReplay")
struct SnapshotReplayTests {

    // MARK: - classify() pure function

    @Test func classifyBaseline() {
        // predicted == dbPlate, no override → baseline
        let m = SnapshotReplay.classify(predicted: "EL916BC", dbPlate: "EL916BC", override: nil)
        #expect(m == .baseline)
    }

    @Test func classifyRegression() {
        // predicted != dbPlate, no override → suspect regression
        let m = SnapshotReplay.classify(predicted: "EL916BX", dbPlate: "EL916BC", override: nil)
        #expect(m == .regression)
    }

    @Test func classifyFixed() {
        // override exists, predicted matches override → fixed (better than baseline)
        let m = SnapshotReplay.classify(predicted: "3ZC0779", dbPlate: "0ZC0779", override: "3ZC0779")
        #expect(m == .fixed)
    }

    @Test func classifyStillWrong() {
        // override exists, predicted ≠ override → stillWrong
        let m = SnapshotReplay.classify(predicted: "BZC0779", dbPlate: "0ZC0779", override: "3ZC0779")
        #expect(m == .stillWrong)
    }

    @Test func classifyNoDetect() {
        let m = SnapshotReplay.classify(predicted: nil, dbPlate: "EL916BC", override: nil)
        #expect(m == .noDetect)
    }

    @Test func classifyCaseInsensitive() {
        // Pipeline normalizuje na uppercase; classify musí matchnout regardless.
        let m1 = SnapshotReplay.classify(predicted: "el916bc", dbPlate: "EL916BC", override: nil)
        #expect(m1 == .baseline)
        let m2 = SnapshotReplay.classify(predicted: "EL916BC", dbPlate: "el916bc", override: nil)
        #expect(m2 == .baseline)
    }

    // MARK: - levenshtein()

    @Test func levenshteinExactMatch() {
        #expect(SnapshotReplay.levenshtein("EL916BC", "EL916BC") == 0)
    }

    @Test func levenshteinSingleSub() {
        #expect(SnapshotReplay.levenshtein("EL916BC", "EL916BX") == 1)
    }

    @Test func levenshteinInsert() {
        #expect(SnapshotReplay.levenshtein("EL916BC", "EL9166BC") == 1)
    }

    @Test func levenshteinEmpty() {
        #expect(SnapshotReplay.levenshtein("", "ABC") == 3)
        #expect(SnapshotReplay.levenshtein("ABC", "") == 3)
        #expect(SnapshotReplay.levenshtein("", "") == 0)
    }

    @Test func levenshteinCaseInsensitive() {
        #expect(SnapshotReplay.levenshtein("abc", "ABC") == 0)
    }

    // MARK: - summarize() math

    @Test func summarizeCounts() {
        let results: [SnapshotReplayResult] = [
            mkResult(.baseline, latency: 100),
            mkResult(.baseline, latency: 110),
            mkResult(.regression, latency: 120),
            mkResult(.fixed, latency: 130),
            mkResult(.stillWrong, latency: 140),
            mkResult(.noDetect, latency: 150),
        ]
        let m = SnapshotReplay.summarize(results, gitHash: "test", ocrParams: .default)
        #expect(m.total == 6)
        #expect(m.baseline == 2)
        #expect(m.regression == 1)
        #expect(m.fixed == 1)
        #expect(m.stillWrong == 1)
        #expect(m.noDetect == 1)
    }

    @Test func summarizeEmpty() {
        let m = SnapshotReplay.summarize([], gitHash: "test", ocrParams: .default)
        #expect(m.total == 0)
        #expect(m.p95LatencyMs == 0)
    }

    @Test func summarizeP95Latency() {
        // 100 latencies: 1,2,...,100. p95 idx = 95 (0-based: 94 returns value 95).
        let results = (1...100).map { mkResult(.baseline, latency: Double($0)) }
        let m = SnapshotReplay.summarize(results, gitHash: "test", ocrParams: .default)
        #expect(m.p95LatencyMs >= 95.0 && m.p95LatencyMs <= 96.0)
    }

    private func mkResult(_ matchType: MatchType, latency: Double) -> SnapshotReplayResult {
        SnapshotReplayResult(
            snapshotPath: "/tmp/test.heic", dbPlate: "EL916BC",
            userOverridePlate: nil, predictedPlate: "EL916BC",
            charErrors: 0, matchType: matchType,
            inferenceMs: latency, confidence: 1.0
        )
    }

    // MARK: - ReplayOverrideStore append + loadEffective

    @Test func overrideStoreAppendAndLoad() throws {
        let url = tempJsonlURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let path = "/tmp/snap1.heic"
        let override = ReplayOverride(snapshotPath: path, truePlate: "EL916BC", markedAt: Date())
        ReplayOverrideStore.appendSync(override, to: url)

        let loaded = ReplayOverrideStore.loadEffective(from: url)
        let std = ReplayOverrideStore.normalizePath(path)
        #expect(loaded[std] == "EL916BC")
    }

    @Test func overrideStoreDedupeSamePath() throws {
        let url = tempJsonlURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let path = "/tmp/snap2.heic"
        ReplayOverrideStore.appendSync(
            ReplayOverride(snapshotPath: path, truePlate: "OLD", markedAt: Date()),
            to: url
        )
        ReplayOverrideStore.appendSync(
            ReplayOverride(snapshotPath: path, truePlate: "NEW", markedAt: Date()),
            to: url
        )

        let loaded = ReplayOverrideStore.loadEffective(from: url)
        let std = ReplayOverrideStore.normalizePath(path)
        // Pozdější vyhrává.
        #expect(loaded[std] == "NEW")
    }

    @Test func overrideStoreUppercasesText() throws {
        let url = tempJsonlURL()
        defer { try? FileManager.default.removeItem(at: url) }

        ReplayOverrideStore.appendSync(
            ReplayOverride(snapshotPath: "/tmp/snap.heic", truePlate: "el916bc", markedAt: Date()),
            to: url
        )

        let loaded = ReplayOverrideStore.loadEffective(from: url)
        // Mělo by se uložit uppercase (matching s OCR uppercase output).
        #expect(loaded.values.contains("EL916BC"))
    }

    @Test func overrideStoreMissingFileEmpty() {
        let url = URL(fileURLWithPath: "/tmp/non-existent-\(UUID().uuidString).jsonl")
        let loaded = ReplayOverrideStore.loadEffective(from: url)
        #expect(loaded.isEmpty)
    }

    // MARK: - effectiveOverride tolerantní lookup

    @Test func effectiveOverrideExactMatch() {
        let path = "/tmp/snap.heic"
        let std = ReplayOverrideStore.normalizePath(path)
        let dict = [std: "EL916BC"]
        let result = ReplayOverrideStore.effectiveOverride(for: path, in: dict)
        #expect(result == "EL916BC")
    }

    @Test func effectiveOverrideBasenameMatch() {
        // Override stored under "/old/path/snap.heic" — query path "/different/dir/snap.heic"
        // should match by basename.
        let dict = ["/old/path/snap.heic": "EL916BC"]
        let result = ReplayOverrideStore.effectiveOverride(
            for: "/different/dir/snap.heic", in: dict
        )
        #expect(result == "EL916BC")
    }

    @Test func effectiveOverrideRawHeicStrip() {
        // Override stored pro "snap.heic", query je raw sidecar "snap.raw.heic".
        let dict = ["/some/dir/snap.heic": "EL916BC"]
        let result = ReplayOverrideStore.effectiveOverride(
            for: "/different/dir/snap.raw.heic", in: dict
        )
        #expect(result == "EL916BC")
    }

    @Test func effectiveOverrideNoMatch() {
        let dict = ["/path/snap.heic": "EL916BC"]
        let result = ReplayOverrideStore.effectiveOverride(
            for: "/path/different.heic", in: dict
        )
        #expect(result == nil)
    }

    // MARK: - normalizePath

    @Test func normalizePathStandardizes() {
        let p = ReplayOverrideStore.normalizePath("/tmp/./foo/../bar.heic")
        // Expected: collapsed to "/tmp/bar.heic" (or system-specific resolution).
        #expect(p.hasSuffix("bar.heic"))
        #expect(!p.contains("./"))
        #expect(!p.contains(".."))
    }

    @Test func normalizePathEmpty() {
        #expect(ReplayOverrideStore.normalizePath("") == "")
    }

    // MARK: - DB lookup tolerance (SnapshotReplay.lookupDbPlate)

    @Test func lookupDbPlateExact() {
        let url = URL(fileURLWithPath: "/tmp/x/snap.heic").standardizedFileURL
        let dbIndex = [url.path: "EL916BC"]
        let result = SnapshotReplay.lookupDbPlate(snapshotURL: url, dbIndex: dbIndex)
        #expect(result == "EL916BC")
    }

    @Test func lookupDbPlateBasenameMatch() {
        // DB has different absolute path but same basename.
        let dbIndex = ["/old/storage/snap.heic": "EL916BC"]
        let url = URL(fileURLWithPath: "/new/storage/snap.heic")
        let result = SnapshotReplay.lookupDbPlate(snapshotURL: url, dbIndex: dbIndex)
        #expect(result == "EL916BC")
    }

    @Test func lookupDbPlateNoMatch() {
        let dbIndex = ["/path/a.heic": "EL916BC"]
        let url = URL(fileURLWithPath: "/path/b.heic")
        let result = SnapshotReplay.lookupDbPlate(snapshotURL: url, dbIndex: dbIndex)
        #expect(result == nil)
    }

    // MARK: - Helpers

    private func tempJsonlURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("test-overrides-\(UUID().uuidString).jsonl")
    }
}
