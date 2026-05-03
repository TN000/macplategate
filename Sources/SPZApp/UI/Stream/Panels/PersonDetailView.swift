import SwiftUI
import AppKit

/// PersonDetailView — kompletní měsíční přehled jedné SPZ.
/// Extracted ze StreamView.swift jako součást big-refactor split (krok #10).

struct PersonDetailView: View {
    let entry: KnownPlates.Entry
    let listHeight: CGFloat
    let onBack: () -> Void

    @State private var sessions: [Store.ParkingSession] = []
    @State private var detCounts: [String: Int] = [:]

    /// První den aktuálního měsíce (midnight) — cutoff pro „tento měsíc".
    private var monthStart: Date {
        let cal = Calendar.current
        let now = Date()
        return cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now.addingTimeInterval(-30 * 86400)
    }

    private var closedDurations: [Int] {
        sessions.compactMap { $0.durationSec }
    }
    private var totalSec: Int { closedDurations.reduce(0, +) }
    private var avgSec: Int { closedDurations.isEmpty ? 0 : totalSec / closedDurations.count }
    private var visitsCount: Int { sessions.count }
    private var currentlyParked: Bool { sessions.contains { $0.isOpen } }
    private var lastEntry: Date? { sessions.compactMap { $0.entryTs }.max() }
    private var lastExit: Date? { sessions.compactMap { $0.exitTs }.max() }
    private var vjezdDet: Int { detCounts["vjezd"] ?? 0 }
    private var vyjezdDet: Int { detCounts["vyjezd"] ?? detCounts["výjezd"] ?? 0 }
    private var totalDet: Int { detCounts.values.reduce(0, +) }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button(action: onBack) {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                        Text("Zpět").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.primary.opacity(0.85))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08), lineWidth: 1)))
                }
                .buttonStyle(.plain)
                Text(entry.plate)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(red: 15/255, green: 15/255, blue: 20/255))
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white))
                Text(entry.label)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if currentlyParked {
                    HStack(spacing: 5) {
                        Circle().fill(Color.orange).frame(width: 7, height: 7)
                        Text("NA PARKOVIŠTI").font(.system(size: 9, weight: .bold)).tracking(1.2)
                            .foregroundStyle(.orange)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Color.orange.opacity(0.12))
                        .overlay(Capsule().stroke(Color.orange.opacity(0.4), lineWidth: 1)))
                }
            }

            // Stats grid — 1×3: počet průjezdů (= kolikrát se reálně otevřela
            // závora pro toto auto), celkový strávený čas, průměr na návštěvu.
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                statBox("PRŮJEZDŮ", "\(visitsCount)", unit: "tento měs.")
                statBox("CELKEM", formatDuration(totalSec), unit: "strávený čas")
                statBox("PRŮMĚR", formatDuration(avgSec), unit: "na návštěvu")
            }

            // Sessions list
            HStack {
                Text("HISTORIE").font(.system(size: 9, weight: .bold)).tracking(1.2)
                    .foregroundStyle(Color.white.opacity(0.5))
                Spacer()
                if let le = lastEntry {
                    Text("Poslední vjezd: \(le.formatted(.dateTime.day().month().hour().minute()))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 2)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 4) {
                    if sessions.isEmpty {
                        Text("Žádné průjezdy tento měsíc.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .padding(10)
                    } else {
                        ForEach(sessions) { s in sessionRow(s) }
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(height: listHeight - 160)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .onAppear { refresh() }
    }

    private func statBox(_ k: String, _ v: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(LocalizedStringKey(k)).font(.system(size: 8, weight: .bold)).tracking(1.4)
                .foregroundStyle(Color.white.opacity(0.5))
            Text(v).font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1).minimumScaleFactor(0.75)
            Text(LocalizedStringKey(unit)).font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.06), lineWidth: 1)))
    }

    private func sessionRow(_ s: Store.ParkingSession) -> some View {
        HStack(spacing: 8) {
            Circle().fill(s.isOpen ? Color.orange : Color.green).frame(width: 6, height: 6)
            Text(s.entryTs?.formatted(.dateTime.day().month().hour().minute()) ?? "—")
                .font(.system(size: 11, design: .monospaced))
            Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(.tertiary)
            Text(s.exitTs?.formatted(.dateTime.day().month().hour().minute()) ?? (s.isOpen ? "na parkovišti" : "—"))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(s.isOpen ? Color.orange : .primary.opacity(0.85))
            Spacer()
            if let d = s.durationSec {
                Text(formatDuration(d))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.green.opacity(0.9))
            } else if s.isOpen, let e = s.entryTs {
                Text(formatDuration(Int(Date().timeIntervalSince(e))) + " …")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.orange.opacity(0.9))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.03)))
    }

    private func refresh() {
        sessions = Store.shared.sessions(plate: entry.plate, since: monthStart)
        detCounts = Store.shared.detectionCountsByCamera(plate: entry.plate, since: monthStart)
    }

    private func formatDuration(_ sec: Int) -> String {
        if sec <= 0 { return "—" }
        let h = sec / 3600
        let m = (sec % 3600) / 60
        if h > 0 { return "\(h) h \(m) m" }
        return "\(m) m"
    }
}
