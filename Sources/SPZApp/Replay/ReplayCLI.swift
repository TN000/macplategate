import Foundation

/// CLI dispatch pro SnapshotReplay headless mode.
///
/// Invocation: `swift run SPZApp replay-snapshots [--min-height N] [--dual-pass] [--fast]
///                                                [--retry-threshold N] [--retry-boxes N]
///                                                [--concurrency N] [--output PATH]`
///
/// Žádný AppState / SwiftUI / WebServer init — main.swift hop nás directně
/// sem před `SPZApp.main()`. Po dokončení `exit(0)`.
enum ReplayCLI {

    static func canHandle(_ argv: [String]) -> Bool {
        argv.count >= 2 && argv[1] == "replay-snapshots"
    }

    static func run(args: [String]) {
        // Parse flags. args[0] je "replay-snapshots" — skip.
        let flags = Array(args.dropFirst())
        var ocrParams = OCRParams.default
        var concurrency: Int = 1
        var explicitOutput: URL? = nil
        var i = 0
        while i < flags.count {
            switch flags[i] {
            case "--min-height":
                if i + 1 < flags.count, let v = Double(flags[i+1]) {
                    ocrParams.minObsHeightFraction = CGFloat(v)
                    i += 1
                }
            case "--dual-pass":
                ocrParams.dualPass = true
            case "--fast":
                ocrParams.fastMode = true
            case "--disable-enhanced-retry":
                ocrParams.enhancedRetryEnabled = false
            case "--retry-threshold":
                if i + 1 < flags.count, let v = Float(flags[i+1]) {
                    ocrParams.enhancedRetryThreshold = v
                    i += 1
                }
            case "--retry-boxes":
                if i + 1 < flags.count, let v = Int(flags[i+1]) {
                    ocrParams.maxRetryBoxes = max(0, min(v, 4))
                    i += 1
                }
            case "--concurrency":
                if i + 1 < flags.count, let v = Int(flags[i+1]) {
                    concurrency = max(1, min(v, 8))
                    i += 1
                }
            case "--output":
                if i + 1 < flags.count {
                    explicitOutput = URL(fileURLWithPath: flags[i+1])
                    i += 1
                }
            case "-h", "--help":
                printUsage()
                return
            default:
                FileHandle.safeStderrWrite(
                    "Unknown flag: \(flags[i])\n".data(using: .utf8)!)
                printUsage()
                return
            }
            i += 1
        }

        // Resolve paths (defaults).
        let appSupport = AppPaths.baseDir
        let snapshotsDir = appSupport.appendingPathComponent("snapshots", isDirectory: true)
        let dbPath = appSupport.appendingPathComponent("detections.db")
        let overridesPath = ReplayOverrideStore.defaultURL
        let resultsDir = appSupport.appendingPathComponent("replay-results", isDirectory: true)
        try? FileManager.default.createDirectory(at: resultsDir,
                                                  withIntermediateDirectories: true)

        let gitHash = currentGitHash() ?? "unknown"

        // Header.
        let paramsLabel = """
        params={minHeight:\(ocrParams.minObsHeightFraction), \
        dualPass:\(ocrParams.dualPass), fast:\(ocrParams.fastMode), \
        enhanced:\(ocrParams.enhancedRetryEnabled), retry:\(ocrParams.enhancedRetryThreshold), \
        boxes:\(ocrParams.maxRetryBoxes), conc:\(concurrency)}
        """
        print("SPZApp replay-snapshots @ git:\(gitHash)  \(paramsLabel)")
        print(String(repeating: "=", count: 65))

        // Run.
        let t0 = Date()
        let results = SnapshotReplay.runAll(
            snapshotsDir: snapshotsDir, dbPath: dbPath,
            overridesPath: overridesPath, ocrParams: ocrParams,
            concurrency: concurrency
        )
        let elapsedSec = Date().timeIntervalSince(t0)

        let metrics = SnapshotReplay.summarize(results, gitHash: gitHash, ocrParams: ocrParams)
        printSummary(metrics, elapsedSec: elapsedSec)
        printTopRegressions(results)

        // Persist JSONL detail.
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let outputURL = explicitOutput ?? resultsDir.appendingPathComponent("\(stamp).jsonl")
        writeJSONL(results: results, metrics: metrics, to: outputURL)
        print("\ndetail: \(outputURL.path)")
    }

    // MARK: - Output

    private static func printSummary(_ m: ReplayMetrics, elapsedSec: TimeInterval) {
        let pct: (Int) -> String = { count in
            guard m.total > 0 else { return "  0.0%" }
            let p = Double(count) / Double(m.total) * 100.0
            return String(format: "%5.1f%%", p)
        }
        print("total: \(m.total)  (\(String(format: "%.1f", elapsedSec))s wall)")
        print("  baseline:    \(String(format: "%4d", m.baseline)) (\(pct(m.baseline)))  ← matches DB commit text")
        print("  regression:  \(String(format: "%4d", m.regression)) (\(pct(m.regression)))  ← worse than baseline (suspect)")
        print("  fixed:       \(String(format: "%4d", m.fixed)) (\(pct(m.fixed)))  ← override matches new prediction")
        print("  stillWrong:  \(String(format: "%4d", m.stillWrong)) (\(pct(m.stillWrong)))  ← override exists, still misreading")
        print("  noDetect:    \(String(format: "%4d", m.noDetect)) (\(pct(m.noDetect)))  ← OCR returned nothing")
        print("p95 latency: \(String(format: "%.0f", m.p95LatencyMs)) ms")
    }

    private static func printTopRegressions(_ results: [SnapshotReplayResult]) {
        let regressions = results.filter { $0.matchType == .regression }
            .sorted { $0.charErrors > $1.charErrors }
            .prefix(10)
        guard !regressions.isEmpty else { return }
        print("\ntop regressions (current OCR worse than commit-time):")
        for r in regressions {
            let basename = (r.snapshotPath as NSString).lastPathComponent
            let pred = r.predictedPlate ?? "<no detect>"
            print("  \(basename): was=\"\(r.dbPlate)\" → now=\"\(pred)\" (\(r.charErrors) char errs)")
        }
    }

    private static func writeJSONL(results: [SnapshotReplayResult],
                                   metrics: ReplayMetrics, to url: URL) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        // První řádek = metrics summary; následuje per-result detail.
        var lines: [Data] = []
        if let metricsLine = try? enc.encode(metrics) { lines.append(metricsLine) }
        for r in results {
            if let line = try? enc.encode(r) { lines.append(line) }
        }
        let content = lines
            .compactMap { String(data: $0, encoding: .utf8) }
            .joined(separator: "\n") + "\n"
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func printUsage() {
        let usage = """
        Usage: SPZApp replay-snapshots [options]

        Replays existing snapshots through current PlateOCR pipeline + reports
        regression vs DB commit-time text. NOT an accuracy measurement —
        DB plate text is the pipeline's commit-time tip, not ground truth.

        Options:
          --min-height N   Min observation height fraction (default 0.025)
          --dual-pass      Enable dual-pass OCR (rev2+rev3 model fusion)
          --fast           Use Vision .fast recognition level (default .accurate)
          --disable-enhanced-retry
                           Disable tight enhanced retry for A/B baseline
          --retry-threshold N
                           Enhanced retry confidence threshold (default 0.95)
          --retry-boxes N  Max enhanced retry Y-clusters per snapshot (default 2)
          --concurrency N  Parallel snapshots (default 1, max 8). >1 thermal-tepelný.
          --output PATH    Custom JSONL output path (default replay-results/<ts>.jsonl)
          -h, --help       Print this message
        """
        print(usage)
    }

    // MARK: - Git hash

    private static func currentGitHash() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["git", "rev-parse", "--short", "HEAD"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()  // discard
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let hash = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return hash?.isEmpty == false ? hash : nil
        } catch {
            return nil
        }
    }
}
