import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Store snapshot + manual passes management — extension Store.
/// Extracted ze Store.swift jako součást big-refactor split (krok #10).
/// Drží file-system retention pro `snapshots/` (HEIC) a `manual-prujezdy/` (JPEG).

extension Store {
    func ensureSnapshotIndex() {
        if snapshotIndexLoaded { return }
        refreshSnapshotIndex()
    }

    func refreshSnapshotIndex() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: snapshotsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        snapshotIndex = items.compactMap { u -> (URL, Date)? in
            guard let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
            return (u, d)
        }.sorted(by: { $0.date < $1.date })
        snapshotIndexLoaded = true
    }

    /// Volá se po úspěšném zápisu snapshotu — incremental přidání do indexu
    /// (na konec, protože nový snapshot = nejnovější datum).
    func snapshotIndexAppend(_ url: URL) {
        guard snapshotIndexLoaded else { return }  // ensureSnapshotIndex udělá plný load
        snapshotIndex.append((url, Date()))
    }

    func pruneSnapshotsIfNeeded() {
        commitsSinceRetention += 1
        if commitsSinceRetention < Self.retentionInterval { return }
        commitsSinceRetention = 0
        pruneSnapshotsNow()
    }

    func pruneSnapshotsNow() {
        ensureSnapshotIndex()
        // Periodický full rescan kvůli externím změnám (user smaže ručně).
        pruneCallCount += 1
        if pruneCallCount >= Self.fullRescanInterval {
            pruneCallCount = 0
            refreshSnapshotIndex()
        }
        let fm = FileManager.default
        var removed = 0

        // 1) Age-based prune — snapshotIndex je sorted by date ascending,
        //    takže odřežeme prefix starší než cutoff.
        if snapshotRetentionDays > 0 {
            let cutoff = Date().addingTimeInterval(-snapshotRetentionDays * 86_400)
            while let first = snapshotIndex.first, first.date < cutoff {
                try? fm.removeItem(at: first.url)
                snapshotIndex.removeFirst()
                removed += 1
            }
        }
        // 2) Count-based prune — odřež nejstarší (prefix) dokud nejsme pod limitem.
        if snapshotMaxFiles > 0, snapshotIndex.count > snapshotMaxFiles {
            let toRemove = snapshotIndex.count - snapshotMaxFiles
            for _ in 0..<toRemove {
                if let first = snapshotIndex.first {
                    try? fm.removeItem(at: first.url)
                    snapshotIndex.removeFirst()
                    removed += 1
                }
            }
        }
        if removed > 0 {
            FileHandle.safeStderrWrite(
                "[Store] pruneSnapshots removed=\(removed)\n".data(using: .utf8)!
            )
        }
    }

    /// Uloží full-frame JPEG manuálního průjezdu do `manual-prujezdy/`.
    /// Název: `{ISO8601}.{ms}_{camera}_MANUAL.jpg`. Vrací path nebo nil.
    /// Po zápisu ořízne nejstarší soubory nad `manualPassesMaxCount`.
    @discardableResult
    func persistManualPass(cameraName: String, fullImage: NSImage) -> URL? {
        var resultURL: URL? = nil
        autoreleasepool {
            guard let cg = fullImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let now = Date()
            let stamp = Self.sharedISO8601.string(from: now)
                .replacingOccurrences(of: ":", with: "-")
            let milli = Int((now.timeIntervalSince1970 * 1000).truncatingRemainder(dividingBy: 1000))
            let fname = "\(stamp).\(String(format: "%03d", milli))_\(cameraName)_MANUAL.heic"
            let url = manualPassesDir.appendingPathComponent(fname)
            guard let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.heic.identifier as CFString, 1, nil
            ) else { return }
            CGImageDestinationAddImage(dest, cg, [
                kCGImageDestinationLossyCompressionQuality: 0.9,
            ] as CFDictionary)
            if CGImageDestinationFinalize(dest) {
                resultURL = url
            }
        }
        pruneManualPassesNow()
        return resultURL
    }

    /// FIFO ořez `manual-prujezdy/` nad `manualPassesMaxCount`.
    func pruneManualPassesNow() {
        guard manualPassesMaxCount > 0 else { return }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: manualPassesDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let withDates: [(url: URL, date: Date)] = items.compactMap { u in
            guard let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
            return (u, d)
        }
        guard withDates.count > manualPassesMaxCount else { return }
        let sorted = withDates.sorted { $0.date < $1.date }  // nejstarší first
        let toRemove = withDates.count - manualPassesMaxCount
        for item in sorted.prefix(toRemove) {
            try? fm.removeItem(at: item.url)
        }
        FileHandle.safeStderrWrite(
            "[Store] pruneManualPasses removed=\(toRemove)\n".data(using: .utf8)!)
    }
}
