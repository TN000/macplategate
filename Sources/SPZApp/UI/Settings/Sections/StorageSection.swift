import SwiftUI
import AppKit

/// StorageSection — extracted ze SettingsView.swift jako součást big-refactor split (krok #10).

struct StorageSection: View {
    @EnvironmentObject var state: AppState
    @State private var dbSize: String = "…"
    @State private var jsonlSize: String = "…"
    @State private var snapCount: String = "…"
    @State private var snapSize: String = "…"
    @State private var manualCount: String = "…"
    @State private var manualSize: String = "…"
    @State private var logSize: String = "…"
    @State private var totalSize: String = "…"
    @State private var showLogSheet: Bool = false

    var body: some View {
        SettingsCard("Stav úložiště", icon: "internaldrive.fill", accent: .teal.opacity(0.8),
                     trailing: { AnyView(Button {
                        refresh()
                     } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10))
                     }.buttonStyle(GhostButtonStyle())) }) {
            infoRow("DNES / CELKEM", "\(state.totalToday) / \(state.totalAll)")
            Divider().background(Color.white.opacity(0.06))
            infoRow("Databáze detekcí", dbSize)
            infoRow("Audit log (JSONL)", jsonlSize)
            infoRow("Fotek (počet)", snapCount)
            infoRow("Fotek (velikost)", snapSize)
            infoRow("Manuálních průjezdů", "\(manualCount) / \(manualSize)")
            infoRow("Aplikační log", logSize)
            Divider().background(Color.white.opacity(0.06))
            infoRow("CELKEM NA DISKU", totalSize)
            infoRow("Cesta k datům", Store.shared.snapshotsDir.deletingLastPathComponent().path)
            HStack(spacing: 8) {
                Button("Zobrazit posledních 200 řádků logu") {
                    showLogSheet = true
                }.buttonStyle(GhostButtonStyle())
                Spacer()
            }
        }
        .sheet(isPresented: $showLogSheet) {
            LogViewerSheet(onClose: { showLogSheet = false })
        }

        SettingsCard("Notifikace neaktivních SPZ", icon: "bell.badge.fill", accent: .yellow.opacity(0.8)) {
            ToggleRow("Upozornění pro dlouho neviděné SPZ",
                      hint: "Denně projde whitelist a hlásí SPZ co nebyla detekována déle než zvolený počet dní. Vhodné pro firemní provoz — upozorní, že zaměstnanec / zákazník přestal jezdit. Log: [UnseenAlerter] FIRE plate=X lastSeen=... v spz.log. Dedup 7 dní per SPZ (nespamuje).",
                      isOn: $state.unseenPlateAlertsEnabled)
            if state.unseenPlateAlertsEnabled {
                StepperRow("Práh neaktivity (dny)",
                           hint: "Kolik dní musí SPZ nebýt viděna aby se vystřelilo upozornění. Default 30 dní = měsíční okno.",
                           value: $state.unseenPlateAlertDays, range: 3...365, step: 1) {
                    "\($0) dní"
                }
                HStack(spacing: 8) {
                    Button("Skenovat teď") {
                        let fired = UnseenPlateAlerter.shared.runScan()
                        refresh()
                        FileHandle.safeStderrWrite(
                            "[UnseenAlerter] manual scan → \(fired.count) SPZ fired\n".data(using: .utf8)!)
                    }
                    .buttonStyle(GhostButtonStyle())
                    Spacer()
                }
            }
        }

        SettingsCard("Archivace fotek detekovaných SPZ", icon: "archivebox.fill", accent: .orange.opacity(0.8)) {
            StepperRow("Uchovat počet dní",
                       hint: "Jak dlouho se ukládají fotky zaznamenaných SPZ. Po této době se starší fotky automaticky mažou, aby nezabíraly místo. 0 = uchovávat navždy (pozor — disk se bude plnit).",
                       value: $state.snapshotRetentionDays, range: 0...365, step: 1) {
                $0 == 0 ? "neomezeno" : "\($0) dní"
            }
            StepperRow("Maximálně souborů",
                       hint: "Horní strop počtu uložených fotek. Při překročení se smažou nejstarší. 0 = bez limitu.",
                       value: $state.snapshotRetentionMaxCount, range: 0...100000, step: 500) {
                $0 == 0 ? "neomezeno" : "\($0)"
            }
            HStack(spacing: 8) {
                Button("Uklidit teď") {
                    Store.shared.snapshotRetentionDays = Double(state.snapshotRetentionDays)
                    Store.shared.snapshotMaxFiles = state.snapshotRetentionMaxCount
                    Store.shared.pruneSnapshotsNow()
                    refresh()
                }
                .buttonStyle(GhostButtonStyle())
                Spacer()
            }
        }

        SettingsCard("Údržba databáze", icon: "wrench.and.screwdriver.fill", accent: .red.opacity(0.7)) {
            HStack {
                Text("Zhutnit databázi (zápisy → hlavní soubor)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Zhutnit") {
                    _ = Store.shared.periodicCheckpoint()
                }.buttonStyle(GhostButtonStyle())
            }
            HStack {
                Text("Otevřít složku s daty ve Finderu")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Otevřít") {
                    NSWorkspace.shared.open(Store.shared.snapshotsDir.deletingLastPathComponent())
                }.buttonStyle(GhostButtonStyle())
            }
        }
        .onAppear { refresh() }
    }

    private func infoRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(LocalizedStringKey(k)).font(.system(size: 9, weight: .bold)).tracking(1.2)
                .foregroundStyle(Color.white.opacity(0.45))
            Spacer()
            Text(v).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(1).truncationMode(.middle)
        }
    }

    private func refresh() {
        let base = Store.shared.snapshotsDir.deletingLastPathComponent()
        let fm = FileManager.default
        let fmt = ByteCountFormatter(); fmt.countStyle = .file

        func dirSize(_ url: URL) -> (count: Int, bytes: Int64) {
            guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return (0, 0) }
            var total: Int64 = 0
            for u in items {
                if let s = (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize { total += Int64(s) }
            }
            return (items.count, total)
        }
        func fileSize(_ url: URL) -> Int64 {
            (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        }

        let dbBytes = fileSize(base.appendingPathComponent("detections.db"))
            + fileSize(base.appendingPathComponent("detections.db-wal"))
            + fileSize(base.appendingPathComponent("detections.db-shm"))
        let jsonlBytes = fileSize(base.appendingPathComponent("detections.jsonl"))
        let snaps = dirSize(Store.shared.snapshotsDir)
        let manuals = dirSize(Store.shared.manualPassesDir)
        let logBytes = fileSize(base.appendingPathComponent("spz.log"))
            + fileSize(base.appendingPathComponent("spz.log.1"))

        dbSize = fmt.string(fromByteCount: dbBytes)
        jsonlSize = fmt.string(fromByteCount: jsonlBytes)
        snapCount = "\(snaps.count)"
        snapSize = fmt.string(fromByteCount: snaps.bytes)
        manualCount = "\(manuals.count)"
        manualSize = fmt.string(fromByteCount: manuals.bytes)
        logSize = fmt.string(fromByteCount: logBytes)
        totalSize = fmt.string(fromByteCount: dbBytes + jsonlBytes + snaps.bytes + manuals.bytes + logBytes)
    }

    private func formatSize(_ url: URL) -> String {
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let s = attrs[.size] as? NSNumber {
            let f = ByteCountFormatter(); f.countStyle = .file
            return f.string(fromByteCount: s.int64Value)
        }
        return "—"
    }
}

// MARK: - Manuální průjezdy
