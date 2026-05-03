import SwiftUI
import AppKit

/// RecentCard — karta s posledními detekcemi (top-right pravý sloupec).
/// Extracted ze StreamView.swift jako součást big-refactor split (krok #10).

struct RecentCard: View {
    @EnvironmentObject var state: AppState
    @State private var tab: DetTab = .recent
    @State private var parkingOpen: [Store.ParkingSession] = []
    @State private var parkingTick: Date = Date()

    enum DetTab: String, CaseIterable, Identifiable {
        case recent = "Detekce"
        case parking = "Parkoviště"
        var id: String { rawValue }
    }

    private let visibleRows: CGFloat = 4
    private let rowHeight: CGFloat = 44
    private let rowSpacing: CGFloat = 1

    private var listHeight: CGFloat {
        rowHeight * visibleRows + rowSpacing * (visibleRows - 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ForEach(DetTab.allCases) { t in
                    pillButton(t)
                }
                // Počet aut aktuálně na parkovišti — zobrazeno jen na PARKOVIŠTĚ tabu.
                if tab == .parking {
                    HStack(spacing: 5) {
                        Image(systemName: "car.2.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("\(parkingOpen.count)")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                        Text(parkingOpen.count == 1 ? "auto" : (parkingOpen.count >= 2 && parkingOpen.count <= 4 ? "auta" : "aut"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(Color.orange.opacity(0.95))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(
                        Capsule().fill(Color.orange.opacity(0.12))
                            .overlay(Capsule().stroke(Color.orange.opacity(0.35), lineWidth: 1))
                    )
                }
                Spacer(minLength: 10)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)

            Group {
                switch tab {
                case .recent: recentList()
                case .parking: parkingList()
                }
            }
            .frame(maxHeight: .infinity)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
        .onAppear { refreshParking() }
        // Auto-refresh seznamu na parkovišti — commit vjezd/vyjezd → nejnovější
        // item v allowedPasses má nový timestamp. `.count` nefungoval protože
        // buffer capped na 10 → po zaplnění se count nemění.
        .onChange(of: state.allowedPasses.items.first?.timestamp) { _, _ in refreshParking() }
        // Whitelist add/remove (včetně denního vjezdu přes AddDailyPassSheet)
        // může ovlivnit viditelnost sessionu — re-fetch.
        .onChange(of: KnownPlates.shared.entries.count) { _, _ in refreshParking() }
    }

    private func pillButton(_ t: DetTab) -> some View {
        let active = (tab == t)
        return Button(action: {
            tab = t
            if t == .parking { refreshParking() }
        }) {
            Text(LocalizedStringKey(t.rawValue.uppercased()))
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.0)
                .lineLimit(1)
                .foregroundStyle(active ? Color.black : Color.white.opacity(0.55))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(pillBg(active: active))
        }
        .buttonStyle(.plain)
    }

    private func pillBg(active: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(active ? Color.green : Color.white.opacity(0.04))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                active ? Color.green.opacity(0.4) : Color.white.opacity(0.06),
                lineWidth: 1))
    }

    @ViewBuilder
    private func recentList() -> some View {
        if state.recents.items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "car.side")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text("Čekám na první SPZ…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: listHeight)
        } else {
            // LazyVStack byl zdrojem resize artefaktů: při drag-resize okna
            // recycler cell layers občas udržely stale bitmap obsahu (fragmenty
            // textu "JISTOTA" / plate chars) v jistota sloupci. 10 řádků je málo —
            // plain VStack bez lazy materializace je stabilní.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: rowSpacing) {
                    ForEach(state.recents.items.prefix(10)) { rec in
                        RecentRow(rec: rec).frame(height: rowHeight)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: .infinity)
            .clipped()
        }
    }

    @ViewBuilder
    private func parkingList() -> some View {
        if parkingOpen.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "parkingsign")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text("Parkoviště je prázdné.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: listHeight)
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: rowSpacing) {
                    ForEach(parkingOpen) { s in
                        parkingRow(s).frame(height: rowHeight)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .frame(maxHeight: .infinity)
            // Periodický refresh — 10s tick updatuje duration string + re-query
            // open sessions z DB (safety net proti propuštěným update signalům).
            .background(
                TimelineView(.periodic(from: Date(), by: 10)) { context in
                    Color.clear.onChange(of: context.date) { _, new in
                        parkingTick = new
                        refreshParking()
                    }
                }
            )
        }
    }

    private func parkingRow(_ s: Store.ParkingSession) -> some View {
        let entry = KnownPlates.shared.match(s.plate)
        let label = entry?.label ?? "—"
        let displayLabel = state.isLoggedIn ? label : String(repeating: "•", count: max(4, min(label.count, 10)))
        let since = s.entryTs.map { parkingTick.timeIntervalSince($0) } ?? 0
        return HStack(spacing: 12) {
            Image(systemName: "car.fill")
                .font(.system(size: 20))
                .foregroundStyle(Color.orange.opacity(0.85))
                .frame(width: 44)
            HStack(spacing: 10) {
                Text(s.plate)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(red: 15/255, green: 15/255, blue: 20/255))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white))
                Text(displayLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 4) {
                    Circle().fill(Color.orange).frame(width: 5, height: 5)
                    Text("VJEZD").font(.system(size: 8, weight: .bold)).tracking(1.2)
                        .foregroundStyle(.orange)
                }
                Text(s.entryTs?.formatted(.dateTime.hour().minute()) ?? "—")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.9))
                if let ts = s.entryTs {
                    Text(ts.formatted(.dateTime.day().month(.twoDigits).year(.twoDigits)))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            divider
            VStack(alignment: .leading, spacing: 2) {
                Text("STÁNÍ")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(Color.white.opacity(0.45))
                Text(formatDur(Int(since)))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.orange.opacity(0.95))
                    .lineLimit(1)
            }
            .frame(width: 90, alignment: .leading)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.05), lineWidth: 1))
        )
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1, height: 26)
    }

    private func formatDur(_ sec: Int) -> String {
        if sec < 60 { return "\(sec) s" }
        let h = sec / 3600
        let m = (sec % 3600) / 60
        if h > 0 { return "\(h) h \(m) m" }
        return "\(m) m"
    }

    private func refreshParking() {
        parkingOpen = Store.shared.openSessions()
        parkingTick = Date()
    }
}
