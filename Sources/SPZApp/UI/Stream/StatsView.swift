import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// StatsView — souhrnné statistiky využití brány + CSV export.
/// Extracted ze StreamView.swift jako součást big-refactor split (krok #10).

struct StatsView: View {
    let listHeight: CGFloat
    @EnvironmentObject var state: AppState

    // Řada 1 — objem PRŮJEZDŮ (sessions) + celkový počet raw DETEKCÍ.
    @State private var sessTodayCount: Int = 0
    @State private var detectionsTotalCount: Int = 0
    @State private var sessMonthCount: Int = 0
    @State private var sessTotalCount: Int = 0
    // Řada 2 — parkoviště (aktuální stav + měsíční agregáty).
    @State private var openNow: Int = 0
    @State private var avgStayMonth: Int = 0
    @State private var longestStayMonth: Int = 0
    @State private var lastSessionAgo: String = "—"
    // Řada 3 — whitelist + provoz + manuální.
    @State private var whitelistCount: Int = 0
    @State private var dailyPassLifetime: Int = 0
    @State private var peakHour: Int = 0
    @State private var peakHourCount: Int = 0
    @State private var manualCount: Int = 0
    // Top 5.
    @State private var topPlates: [(plate: String, count: Int)] = []
    @State private var topGates: [(plate: String, count: Int)] = []
    // Export CSV feedback badge.
    @State private var exportFeedback: String? = nil
    @State private var exportColor: Color = .green
    private let statColumns = [GridItem(.adaptive(minimum: 116), spacing: 6)]

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 10) {
                // Řada 1 — objem průjezdů (sessions) + celkový počet raw Vision
                //  detekcí. Detekce obsahují každý jednotlivý readout z kamery
                //  (tedy i opakované čtení téhož auta), průjezdy = unikátní vjezdy.
                LazyVGrid(columns: statColumns, spacing: 6) {
                    statBox("DNES", "\(sessTodayCount)", subtitle: "průjezdů")
                    statBox("TENTO MĚSÍC", "\(sessMonthCount)", subtitle: "průjezdů")
                    statBox("CELKEM PRŮJEZDŮ", "\(sessTotalCount)", subtitle: "od začátku")
                    statBox("CELKEM DETEKCÍ", "\(detectionsTotalCount)", subtitle: "raw čtení kamerou", color: .orange)
                }

                // Řada 2 — parkoviště + doby stání.
                LazyVGrid(columns: statColumns, spacing: 6) {
                    statBox("NA PARKOVIŠTI", "\(openNow)", subtitle: "aut teď", color: .orange)
                    statBox("PRŮMĚR STÁNÍ", formatDur(avgStayMonth), subtitle: "měsíc")
                    statBox("NEJDELŠÍ STÁNÍ", formatDur(longestStayMonth), subtitle: "měsíc")
                    statBox("POSLEDNÍ PRŮJEZD", lastSessionAgo, subtitle: "zpět")
                }

                // Řada 3 — whitelist + provoz.
                LazyVGrid(columns: statColumns, spacing: 6) {
                    statBox("TRVALÝCH SPZ", "\(whitelistCount)", subtitle: "ve whitelistu")
                    statBox("DENNÍ OPRÁVNĚNÍ", "\(dailyPassLifetime)", subtitle: "celkem přiděleno", color: .cyan)
                    statBox("ŠPIČKA", "\(peakHour):00", subtitle: "\(peakHourCount) průj. / 30 d")
                    statBox("MANUÁLNÍ", "\(manualCount)", subtitle: "otevření brány", color: .green)
                }

                // Dva seznamy vedle sebe — TOP 5 detekcí + TOP 5 reálných otevření brány
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 8) {
                        topList(title: "TOP 5 DETEKCÍ", subtitle: "tento měsíc",
                                items: topPlates, accent: Color.orange)
                        topList(title: "TOP 5 OTEVŘENÍ BRÁNY", subtitle: "tento měsíc",
                                items: topGates, accent: Color.green)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        topList(title: "TOP 5 DETEKCÍ", subtitle: "tento měsíc",
                                items: topPlates, accent: Color.orange)
                        topList(title: "TOP 5 OTEVŘENÍ BRÁNY", subtitle: "tento měsíc",
                                items: topGates, accent: Color.green)
                    }
                }

                // Confidence histogram — distribuce kvality OCR commits za posledních 30 dní.
                confidenceHistogramPanel()

                // Vehicle type + color distribution.
                // Zobrazí se vždy — buď s daty, nebo s onboarding hint když VehicleClassifier
                // je OFF / ještě neprodukoval commits.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 8) {
                        vehicleTypeSummary
                        vehicleColorSummary
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        vehicleTypeSummary
                        vehicleColorSummary
                    }
                }

                // Export CSV
                exportRow
                .padding(.top, 2)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .onAppear { refresh() }
        // Live auto-refresh: každých 10 s tick + reakce na nové commity
        // (allowedPasses.items.first?.timestamp), na přidání denního vjezdu
        // (dailyPassesAddedTotal), a změny whitelistu (entries.count).
        .background(
            TimelineView(.periodic(from: Date(), by: 10)) { context in
                Color.clear.onChange(of: context.date) { _, _ in refresh() }
            }
        )
        .onChange(of: state.allowedPasses.items.first?.timestamp) { _, _ in refresh() }
        .onChange(of: state.dailyPassesAddedTotal) { _, _ in refresh() }
        .onChange(of: KnownPlates.shared.entries.count) { _, _ in refresh() }
    }

    @ViewBuilder
    private var vehicleTypeSummary: some View {
        if !vehicleTypeDist.isEmpty {
            vehicleTypePanel()
        } else {
            vehicleEmptyPanel(title: "TYPY VOZIDEL", icon: "car")
        }
    }

    @ViewBuilder
    private var vehicleColorSummary: some View {
        if !vehicleColorDist.isEmpty {
            vehicleColorPanel()
        } else {
            vehicleEmptyPanel(title: "BARVY VOZIDEL", icon: "paintpalette")
        }
    }

    private var exportRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                exportTitle
                exportControlButton("Detekce", kind: .detections)
                exportControlButton("Průjezdy/stání", kind: .sessions)
                exportFeedbackBadge
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                exportTitle
                HStack(spacing: 8) {
                    exportControlButton("Detekce", kind: .detections)
                    exportControlButton("Průjezdy/stání", kind: .sessions)
                }
                exportFeedbackBadge
            }
        }
    }

    private var exportTitle: some View {
        Text("EXPORT")
            .font(.system(size: 9, weight: .bold))
            .tracking(1.3)
            .foregroundStyle(Color.white.opacity(0.5))
    }

    @ViewBuilder
    private var exportFeedbackBadge: some View {
        if let msg = exportFeedback {
            Text(LocalizedStringKey(msg))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(exportColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func exportControlButton(_ label: String, kind: ExportKind) -> some View {
        Button(action: { exportCSV(kind: kind) }) {
            HStack(spacing: 5) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 11))
                Text("\(label) CSV")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.1), lineWidth: 1)))
        }
        .buttonStyle(.plain)
    }

    private func topList(title: String, subtitle: String,
                         items: [(plate: String, count: Int)], accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(LocalizedStringKey(title)).font(.system(size: 9, weight: .bold)).tracking(1.3)
                    .foregroundStyle(Color.white.opacity(0.55))
                Text(LocalizedStringKey(subtitle)).font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            if items.isEmpty {
                Text("Zatím žádná data.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(spacing: 6) {
                        Text("\(idx + 1).")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, alignment: .trailing)
                        Text(item.plate)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color(red: 15/255, green: 15/255, blue: 20/255))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(item.count)×")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(accent.opacity(0.95))
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.03)))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06), lineWidth: 1)))
    }

    private func statBox(_ label: String, _ value: String, subtitle: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(label)).font(.system(size: 8, weight: .bold)).tracking(1.3)
                .foregroundStyle(Color.white.opacity(0.5))
            Text(value).font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(LocalizedStringKey(subtitle)).font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.04))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.05), lineWidth: 1)))
    }

    private func formatDur(_ sec: Int) -> String {
        if sec < 60 { return "\(sec) s" }
        let h = sec / 3600
        let m = (sec % 3600) / 60
        if h > 0 { return "\(h) h \(m) m" }
        return "\(m) m"
    }

    @State private var confidenceBuckets: [(conf: Double, count: Int)] = []
    @State private var vehicleTypeDist: [(type: String, count: Int)] = []
    @State private var vehicleColorDist: [(color: String, count: Int)] = []

    @ViewBuilder private func vehicleEmptyPanel(title: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 9, weight: .bold)).tracking(1.3)
                .foregroundStyle(Color.white.opacity(0.5))
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18)).foregroundStyle(.tertiary)
                Text("Žádná data")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Text("Zapněte 'Rozpoznání typu + barvy vozidla' v Nastavení → Optimalizace")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 16)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.03))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.06),
                                                               style: StrokeStyle(lineWidth: 1, dash: [3,3]))))
    }

    @ViewBuilder private func vehicleTypePanel() -> some View {
        let total = vehicleTypeDist.reduce(0) { $0 + $1.count }
        VStack(alignment: .leading, spacing: 6) {
            Text("TYPY VOZIDEL")
                .font(.system(size: 9, weight: .bold)).tracking(1.3)
                .foregroundStyle(Color.white.opacity(0.5))
            ForEach(vehicleTypeDist.prefix(8), id: \.type) { item in
                let pct = total > 0 ? Double(item.count) / Double(total) : 0
                HStack(spacing: 6) {
                    Image(systemName: vehicleSFSymbol(for: item.type))
                        .font(.system(size: 10)).frame(width: 14)
                        .foregroundStyle(.secondary)
                    Text(item.type)
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 60, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.15))
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.blue.opacity(0.7))
                                    .frame(width: geo.size.width * pct),
                                alignment: .leading
                            )
                    }
                    .frame(height: 10)
                    Text("\(item.count)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1)))
    }

    @ViewBuilder private func vehicleColorPanel() -> some View {
        let total = vehicleColorDist.reduce(0) { $0 + $1.count }
        VStack(alignment: .leading, spacing: 6) {
            Text("BARVY VOZIDEL")
                .font(.system(size: 9, weight: .bold)).tracking(1.3)
                .foregroundStyle(Color.white.opacity(0.5))
            ForEach(vehicleColorDist.prefix(8), id: \.color) { item in
                let pct = total > 0 ? Double(item.count) / Double(total) : 0
                HStack(spacing: 6) {
                    Circle()
                        .fill(swiftUIColorForName(item.color))
                        .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
                        .frame(width: 10, height: 10)
                    Text(item.color)
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 60, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.15))
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(swiftUIColorForName(item.color).opacity(0.85))
                                    .frame(width: geo.size.width * pct),
                                alignment: .leading
                            )
                    }
                    .frame(height: 10)
                    Text("\(item.count)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1)))
    }

    /// Confidence histogram bar chart — distribuce jistoty OCR commits za posledních 30 dní.
    /// Help the user vidět jestli má commity s dobrou quality (peak na 0.9+) nebo jestli
    /// velké procento je v 0.5–0.7 pásmu (indikace špatného světla nebo noisy ROI).
    @ViewBuilder private func confidenceHistogramPanel() -> some View {
        let total = confidenceBuckets.reduce(0) { $0 + $1.count }
        let maxCount = confidenceBuckets.map { $0.count }.max() ?? 1
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("HISTOGRAM JISTOTY")
                    .font(.system(size: 9, weight: .bold)).tracking(1.3)
                    .foregroundStyle(Color.white.opacity(0.5))
                Spacer()
                Text("30 DNÍ · \(total) commitů")
                    .font(.system(size: 9, weight: .medium)).tracking(0.8)
                    .foregroundStyle(Color.white.opacity(0.4))
            }
            if confidenceBuckets.isEmpty {
                Text("Žádná data")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .padding(.vertical, 20).frame(maxWidth: .infinity)
            } else {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(confidenceBuckets, id: \.conf) { bucket in
                        VStack(spacing: 2) {
                            Text("\(bucket.count)")
                                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(barColor(for: bucket.conf))
                                .frame(height: max(4, CGFloat(bucket.count) / CGFloat(maxCount) * 60))
                            Text(String(format: "%.2f", bucket.conf))
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.4))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 90)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1)))
    }

    private func barColor(for conf: Double) -> Color {
        // < 0.7 = červená (špatné), 0.7–0.85 = žlutá (hraniční), > 0.85 = zelená (good).
        if conf < 0.7 { return Color.red.opacity(0.75) }
        if conf < 0.85 { return Color.yellow.opacity(0.75) }
        return Color.green.opacity(0.80)
    }

    private func refresh() {
        let cal = Calendar.current
        let now = Date()
        let startOfDay = cal.startOfDay(for: now)
        let startOfMonth: Date = {
            let comp = cal.dateComponents([.year, .month], from: now)
            return cal.date(from: comp) ?? startOfDay
        }()
        let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) ?? now
        let farFuture = cal.date(byAdding: .year, value: 10, to: now) ?? now

        // Řada 1 — sessions (průjezdy) + total raw detekce.
        sessTodayCount = Store.shared.sessionsCountRange(from: startOfDay, to: endOfDay)
        sessMonthCount = Store.shared.sessionsCountRange(from: startOfMonth, to: farFuture)
        sessTotalCount = Store.shared.sessionsCountAll()
        detectionsTotalCount = Store.shared.countAll()

        // Řada 2 — parkoviště.
        openNow = Store.shared.openSessions().count
        avgStayMonth = Store.shared.avgParkingDurationSec(from: startOfMonth, to: farFuture)
        longestStayMonth = Store.shared.longestSessionSec(from: startOfMonth, to: farFuture)
        if let last = Store.shared.lastSessionEntry() {
            let age = Int(now.timeIntervalSince(last))
            lastSessionAgo = formatAgoShort(age)
        } else {
            lastSessionAgo = "—"
        }

        // Řada 3 — admin.
        let entries = KnownPlates.shared.entries
        whitelistCount = entries.filter { $0.expiresAt == nil }.count
        dailyPassLifetime = state.dailyPassesAddedTotal
        let ph = Store.shared.peakHour()
        peakHour = ph.hour
        peakHourCount = ph.count
        manualCount = (try? FileManager.default.contentsOfDirectory(atPath: Store.shared.manualPassesDir.path).count) ?? 0

        // Top 5 seznamy — stále na raw detekcích (pro "najde častěji") a na sessions.
        topPlates = Store.shared.topPlatesByCount(from: startOfMonth, to: farFuture, limit: 5)
        topGates = Store.shared.topPlatesByGateOpenings(from: startOfMonth, to: farFuture, limit: 5)

        // Confidence histogram + vehicle distribution — posledních 30 dní.
        let thirtyDaysAgo = cal.date(byAdding: .day, value: -30, to: now) ?? now
        confidenceBuckets = Store.shared.confidenceHistogram(since: thirtyDaysAgo)
        vehicleTypeDist = Store.shared.vehicleTypeDistribution(since: thirtyDaysAgo)
        vehicleColorDist = Store.shared.vehicleColorDistribution(since: thirtyDaysAgo)
    }

    /// Formát „1 d 3 h", „42 m", „5 s" apod. — pro box "POSLEDNÍ PRŮJEZD".
    private func formatAgoShort(_ sec: Int) -> String {
        if sec < 60 { return "\(sec) s" }
        let m = sec / 60
        if m < 60 { return "\(m) m" }
        let h = m / 60
        if h < 24 { return "\(h) h \(m % 60) m" }
        let d = h / 24
        return "\(d) d \(h % 24) h"
    }

    private enum ExportKind { case detections, sessions }

    private func exportCSV(kind: ExportKind) {
        let panel = NSSavePanel()
        let ts = Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        panel.nameFieldStringValue = kind == .detections ? "spz-detekce-\(ts).csv" : "spz-prujezdy-\(ts).csv"
        panel.allowedContentTypes = [UTType(filenameExtension: "csv") ?? .commaSeparatedText]
        panel.canCreateDirectories = true
        panel.title = "Uložit CSV export"
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            let rows = kind == .detections ?
                Store.shared.exportDetectionsCSV(to: url) :
                Store.shared.exportSessionsCSV(to: url)
            Task { @MainActor in
                if rows >= 0 {
                    showExportFeedback("Exportováno \(rows) řádků", color: .green)
                } else {
                    showExportFeedback("Chyba při zápisu", color: .red)
                }
            }
        }
    }

    private func showExportFeedback(_ text: String, color: Color) {
        exportFeedback = text
        exportColor = color
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if exportFeedback == text { exportFeedback = nil }
        }
    }
}
