import SwiftUI
import AppKit

/// ManualPassesSection — extracted ze SettingsView.swift jako součást big-refactor split (krok #10).

struct ManualPassesSection: View {
    @EnvironmentObject var state: AppState
    @State private var fileCount: Int = 0
    @State private var dirSize: String = "—"
    @State private var activeDailyCount: Int = 0

    var body: some View {
        SettingsCard("Manuální průjezdy", icon: "lock.open.fill", accent: .green.opacity(0.8),
                     trailing: { AnyView(Button {
                        refresh()
                     } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10))
                     }.buttonStyle(GhostButtonStyle())) }) {
            infoRow("Soubory", "\(fileCount)")
            infoRow("Velikost", dirSize)
            infoRow("Složka", Store.shared.manualPassesDir.path)
            StepperRow("Max počet záznamů",
                       hint: "FIFO ořez nejstarších fotek při překročení.",
                       value: $state.manualPassesMaxCount, range: 10...5000, step: 10) {
                "\($0)"
            }
            HStack(spacing: 8) {
                Button("Prune teď") {
                    Store.shared.manualPassesMaxCount = state.manualPassesMaxCount
                    Store.shared.pruneManualPassesNow()
                    refresh()
                }.buttonStyle(GhostButtonStyle())
                Button("Otevřít složku") {
                    NSWorkspace.shared.open(Store.shared.manualPassesDir)
                }.buttonStyle(GhostButtonStyle())
                Spacer()
            }
        }

        SettingsCard("Denní vjezd", icon: "calendar.badge.plus", accent: .cyan.opacity(0.8)) {
            StepperRow("Platnost (hodin)",
                       hint: "Po této době se SPZ automaticky smaže z whitelistu.",
                       value: $state.dailyPassExpiryHours, range: 1...168, step: 1) {
                "\($0) h"
            }
            infoRow("Aktivních denních SPZ", "\(activeDailyCount)")
            HStack(spacing: 8) {
                Button("Smazat expirované teď") {
                    KnownPlates.shared.pruneExpired()
                    refresh()
                }.buttonStyle(GhostButtonStyle())
                Spacer()
            }
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        let fm = FileManager.default
        let dir = Store.shared.manualPassesDir
        if let items = try? fm.contentsOfDirectory(atPath: dir.path) {
            fileCount = items.count
            var total: Int64 = 0
            for name in items {
                let p = dir.appendingPathComponent(name).path
                if let s = try? fm.attributesOfItem(atPath: p)[.size] as? NSNumber {
                    total += s.int64Value
                }
            }
            let f = ByteCountFormatter()
            f.countStyle = .file
            dirSize = f.string(fromByteCount: total)
        } else {
            fileCount = 0
            dirSize = "—"
        }
        activeDailyCount = KnownPlates.shared.entries.filter { $0.expiresAt != nil }.count
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(LocalizedStringKey(label)).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.9))
                .lineLimit(1).truncationMode(.middle)
        }
    }
}

// MARK: - Network diag

// MARK: - Log viewer sheet
