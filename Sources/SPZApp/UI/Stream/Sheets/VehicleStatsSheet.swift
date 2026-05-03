import SwiftUI

/// Statistika konkrétního vozidla (libovolná SPZ — i mimo whitelist).
/// Zobrazuje: počet průjezdů celkem / 7d / 30d, posledních N návštěv,
/// průměrný čas stání + total času stání, peak hour vzoru, whitelist info.
///
/// Otevírá se klikem na řádek v Historii nebo Detekci panelu (jen když
/// uživatel je přihlášen — bez admin hesla bychom mohli leak-ovat sledovaní
/// zaměstnanců/zákazníků).
struct VehicleStatsSheet: View {
    let plate: String
    let onClose: () -> Void

    @State private var allDetections: [RecentDetection] = []
    @State private var sessions: [Store.ParkingSession] = []
    @State private var confirmDeleteAll: Bool = false

    private let last30Days: Date = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    private let last7Days: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    private let allTime: Date = Calendar.current.date(byAdding: .year, value: -10, to: Date()) ?? Date()

    private var whitelistEntry: KnownPlates.Entry? {
        KnownPlates.shared.match(plate)
    }

    private var totalCount: Int { allDetections.count }
    private var last7Count: Int {
        allDetections.filter { $0.timestamp >= last7Days }.count
    }
    private var last30Count: Int {
        allDetections.filter { $0.timestamp >= last30Days }.count
    }
    private var firstSeen: Date? { allDetections.last?.timestamp }
    private var lastSeen: Date? { allDetections.first?.timestamp }

    private var avgParkingSec: Int? {
        let durations = sessions.compactMap { $0.durationSec }.filter { $0 > 0 }
        guard !durations.isEmpty else { return nil }
        return durations.reduce(0, +) / durations.count
    }
    private var totalParkingSec: Int {
        sessions.compactMap { $0.durationSec }.filter { $0 > 0 }.reduce(0, +)
    }

    private var entriesCount: Int { allDetections.filter { $0.cameraName == "vjezd" }.count }
    private var exitsCount: Int { allDetections.filter { $0.cameraName == "vyjezd" || $0.cameraName == "výjezd" }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider().background(Color.white.opacity(0.08))

            countCardsRow

            if let avg = avgParkingSec {
                parkingStatsRow(avg: avg)
            }

            Divider().background(Color.white.opacity(0.08))

            recentVisitsList

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button(action: { confirmDeleteAll = true }) {
                    HStack(spacing: 5) {
                        Image(systemName: "trash.fill").font(.system(size: 10))
                        Text("SMAZAT VŠE (\(allDetections.count))")
                            .font(.system(size: 11, weight: .bold)).tracking(0.8)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .foregroundStyle(Color.red.opacity(0.95))
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.red.opacity(0.10))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.red.opacity(0.35), lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)
                .disabled(allDetections.isEmpty)
                .help("Smaže VŠECHNY detekce této SPZ z DB + odpovídající .heic snapshoty z disku.")
                Spacer()
                Button(action: onClose) {
                    Text("Zavřít").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .foregroundStyle(Color.black)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.85)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 660)
        .alert("Smazat všechny záznamy?", isPresented: $confirmDeleteAll) {
            Button("Zrušit", role: .cancel) {}
            Button("Smazat \(allDetections.count) záznamů", role: .destructive) {
                let removed = Store.shared.deleteAllDetections(plate: plate, unlinkSnapshots: true)
                FileHandle.safeStderrWrite("[VehicleStatsSheet] bulk delete plate=\(plate) removed=\(removed)\n".data(using: .utf8)!)
                onClose()
            }
        } message: {
            Text("Smaže všech \(allDetections.count) detekcí + odpovídající .heic snapshoty z disku. Akce nejde vrátit.")
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [Color(white: 0.10), Color(white: 0.06)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .onAppear { loadStats() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 22))
                .foregroundStyle(Color.cyan.opacity(0.85))
            VStack(alignment: .leading, spacing: 4) {
                Text("STATISTIKA VOZIDLA")
                    .font(.system(size: 9, weight: .bold)).tracking(1.5)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(plate)
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(red: 15/255, green: 15/255, blue: 20/255))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(whitelistEntry != nil ? Color.white : Color.orange.opacity(0.85))
                        )
                    if let e = whitelistEntry {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("WHITELIST").font(.system(size: 8, weight: .bold)).tracking(1.2)
                                .foregroundStyle(Color.green.opacity(0.85))
                            if !e.label.isEmpty {
                                Text(e.label).font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.primary)
                            }
                            if let exp = e.expiresAt {
                                Text("platí do \(exp.formatted(.dateTime.day().month().year().hour().minute()))")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("MIMO WHITELIST").font(.system(size: 8, weight: .bold)).tracking(1.2)
                                .foregroundStyle(Color.orange.opacity(0.95))
                            Text("vozidlo není v evidenci")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer()
        }
    }

    // MARK: - Count cards

    private var countCardsRow: some View {
        HStack(spacing: 10) {
            statCard(label: "CELKEM", value: "\(totalCount)", subtitle: firstSeen.map { "od \($0.formatted(.dateTime.day().month().year()))" }, tint: .blue)
            statCard(label: "30 DNÍ", value: "\(last30Count)", subtitle: nil, tint: .cyan)
            statCard(label: "7 DNÍ", value: "\(last7Count)", subtitle: nil, tint: .teal)
            statCard(label: "VJEZD/VÝJEZD", value: "\(entriesCount)/\(exitsCount)", subtitle: nil, tint: .green)
        }
    }

    private func statCard(label: String, value: String, subtitle: String?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(label)).font(.system(size: 8, weight: .bold)).tracking(1.2)
                .foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(tint.opacity(0.95))
            if let sub = subtitle {
                Text(sub).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(" ").font(.system(size: 8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(tint.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.25), lineWidth: 1))
        )
    }

    // MARK: - Parking stats

    private func parkingStatsRow(avg: Int) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("PRŮMĚRNÉ STÁNÍ").font(.system(size: 8, weight: .bold)).tracking(1.2)
                    .foregroundStyle(.secondary)
                Text(formatDuration(avg))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.orange.opacity(0.95))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text("CELKEM ČASU").font(.system(size: 8, weight: .bold)).tracking(1.2)
                    .foregroundStyle(.secondary)
                Text(formatDuration(totalParkingSec))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.purple.opacity(0.95))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text("SESSIONS").font(.system(size: 8, weight: .bold)).tracking(1.2)
                    .foregroundStyle(.secondary)
                Text("\(sessions.count)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.cyan.opacity(0.95))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
    }

    // MARK: - Recent visits

    private var recentVisitsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("VŠECHNY NÁVŠTĚVY").font(.system(size: 9, weight: .bold)).tracking(1.4)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(allDetections.count)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            if allDetections.isEmpty {
                Text("Žádné záznamy v DB.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 1) {
                        ForEach(allDetections) { rec in
                            visitRow(rec)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
    }

    private func visitRow(_ rec: RecentDetection) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(rec.cameraName == "vjezd" ? Color.green : Color.blue)
                .frame(width: 6, height: 6)
            Text(LocalizedStringKey(rec.cameraName.uppercased()))
                .font(.system(size: 9, weight: .bold)).tracking(1.0)
                .foregroundStyle(rec.cameraName == "vjezd" ? Color.green.opacity(0.85) : Color.blue.opacity(0.85))
                .frame(width: 56, alignment: .leading)
            Text(rec.timestamp.formatted(.dateTime.day().month(.twoDigits).year(.twoDigits).hour().minute().second()))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
            Spacer()
            Text(String(format: "%.0f%%", rec.confidence * 100))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(rec.confidence >= 0.85 ? .green : (rec.confidence >= 0.6 ? .orange : .red))
            Button(action: { deleteSingle(rec) }) {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.red.opacity(0.75))
                    .padding(.horizontal, 4).padding(.vertical, 2)
            }
            .buttonStyle(.plain)
            .help("Smaže tento jeden záznam + .heic snapshot.")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.white.opacity(0.025))
        )
    }

    private func deleteSingle(_ rec: RecentDetection) {
        let ok = Store.shared.deleteDetection(id: rec.id, unlinkSnapshot: true)
        if ok {
            FileHandle.safeStderrWrite("[VehicleStatsSheet] delete id=\(rec.id) plate=\(rec.plate)\n".data(using: .utf8)!)
            // Re-load — bez tohoto by deleted record visel v UI dokud se sheet nezavře.
            loadStats()
        }
    }

    // MARK: - Data load

    private func loadStats() {
        // Query přes plateQuery — substring LIKE; pro stat na konkrétní SPZ
        // potřebujeme exact match. Proto refiltruj na canonical equality.
        let canonical = plate.replacingOccurrences(of: " ", with: "").uppercased()
        let raw = Store.shared.queryDetections(fromDate: nil, toDate: nil,
                                                plateQuery: canonical, camera: nil,
                                                limit: 500)
        allDetections = raw.filter { rec in
            rec.plate.replacingOccurrences(of: " ", with: "").uppercased() == canonical
        }
        sessions = Store.shared.sessions(plate: plate, since: allTime)
    }

    // MARK: - Helpers

    private func formatDuration(_ sec: Int) -> String {
        if sec < 60 { return "\(sec) s" }
        let h = sec / 3600
        let m = (sec % 3600) / 60
        if h >= 24 {
            let d = h / 24
            let hr = h % 24
            return "\(d) d \(hr) h"
        }
        if h > 0 { return "\(h) h \(m) m" }
        return "\(m) m"
    }
}
