import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// HistoryView — všechny detekce z SQLite s filtrem po datu/SPZ/kameře.
/// Extracted ze StreamView.swift jako součást big-refactor split (krok #10).

struct HistoryView: View {
    let listHeight: CGFloat
    @EnvironmentObject var state: AppState

    @State private var results: [RecentDetection] = []
    @State private var plateQuery: String = ""
    @State private var cameraFilter: String = ""  // "" = všechny
    @State private var daysBack: Int = 7
    @State private var isLoading: Bool = false

    var body: some View {
        VStack(spacing: 8) {
            // Filter bar
            filterBar
            .padding(.horizontal, 10).padding(.top, 6)

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                    Text("Žádné záznamy pro zvolený filtr.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 1) {
                        ForEach(results) { rec in
                            RecentRow(rec: rec).frame(height: 44)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .onAppear { refresh() }
        .onChange(of: plateQuery) { _, new in
            // Debounce typing.
            let current = new
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if self.plateQuery == current { self.refresh() }
            }
        }
        // Auto-refresh při novém commit — bind na recents buffer first item.
        // RecentsBuffer.append posune nový commit na index 0; .id se změní,
        // SwiftUI propaguje change → refresh() re-query DB s aktuálními filtry.
        // Bez tohoto user musel kliknout pryč/zpět aby viděl nový průjezd.
        .onChange(of: state.recents.items.first?.id) { _, _ in
            refresh()
        }
    }

    private func refresh() {
        isLoading = true
        let from: Date? = daysBack > 0
            ? Calendar.current.date(byAdding: .day, value: -daysBack, to: Date())
            : nil
        let cam = cameraFilter.isEmpty ? nil : cameraFilter
        let q = plateQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            let res = Store.shared.queryDetections(
                fromDate: from,
                toDate: nil,
                plateQuery: q.isEmpty ? nil : q,
                camera: cam,
                limit: 200
            )
            self.results = res
            self.isLoading = false
        }
    }

    @ViewBuilder
    private var filterBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                searchField
                Divider().frame(height: 14)
                cameraPicker
                Divider().frame(height: 14)
                daysPicker
                Spacer(minLength: 4)
                resultCount
                exportButtons
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    searchField
                    Spacer(minLength: 0)
                    resultCount
                }
                HStack(spacing: 8) {
                    cameraPicker
                    daysPicker
                    Spacer(minLength: 0)
                    exportButtons
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("SPZ", text: $plateQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 120)
                .onSubmit { refresh() }
            if !plateQuery.isEmpty {
                Button { plateQuery = ""; refresh() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
    }

    private var cameraPicker: some View {
        Picker("", selection: $cameraFilter) {
            Text("Vše").tag("")
            ForEach(state.cameras.filter { $0.enabled }, id: \.name) { cam in
                Text(cam.label).tag(cam.name)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .onChange(of: cameraFilter) { _, _ in refresh() }
    }

    private var daysPicker: some View {
        Picker("", selection: $daysBack) {
            Text("1 d").tag(1)
            Text("7 d").tag(7)
            Text("30 d").tag(30)
            Text("90 d").tag(90)
            Text("Vše").tag(0)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .onChange(of: daysBack) { _, _ in refresh() }
    }

    private var resultCount: some View {
        Text("\(results.count)")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(minWidth: 28, alignment: .trailing)
    }

    private var exportButtons: some View {
        HStack(spacing: 6) {
            exportButton(label: "CSV", icon: "square.and.arrow.up", action: exportFilteredCSV)
                .disabled(results.isEmpty)
                .help("Export aktuálně zobrazených detekcí do CSV.")
            exportButton(label: "JSON", icon: "curlybraces", action: exportFilteredJSON)
                .disabled(results.isEmpty)
                .help("Export aktuálně zobrazených detekcí do JSON.")
        }
    }

    private func exportButton(label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                Text(LocalizedStringKey(label)).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.1), lineWidth: 1)))
        }
        .buttonStyle(PressAnimationStyle(cornerRadius: 6, flashColor: .white))
    }

    /// Export aktuálně zobrazených detekcí (po filtraci) do JSON.
    private func exportFilteredJSON() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.json]
        let ts = Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        panel.nameFieldStringValue = "spz-historie-\(ts).json"
        panel.title = "Export zobrazených detekcí do JSON"
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            let iso = ISO8601DateFormatter()
            let items: [[String: Any]] = results.map { r in
                var d: [String: Any] = [
                    "id": r.id,
                    "ts": iso.string(from: r.timestamp),
                    "camera": r.cameraName,
                    "plate": r.plate,
                    "region": r.region.rawValue,
                    "confidence": Double(r.confidence)
                ]
                if let vt = r.vehicleType { d["vehicle_type"] = vt }
                if let vc = r.vehicleColor { d["vehicle_color"] = vc }
                return d
            }
            let payload: [String: Any] = [
                "exported_at": iso.string(from: Date()),
                "count": items.count,
                "detections": items
            ]
            if let json = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
                try? json.write(to: url, options: .atomic)
            }
        }
    }

    /// Export aktuálně zobrazených detekcí (po filtraci) do CSV.
    private func exportFilteredCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "csv") ?? .commaSeparatedText]
        let ts = Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        panel.nameFieldStringValue = "spz-historie-\(ts).csv"
        panel.title = "Export zobrazených detekcí do CSV"
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            var csv = "id,cas,kamera,spz,region,jistota,typ_vozidla,barva_vozidla\n"
            let iso = ISO8601DateFormatter()
            for r in results {
                func esc(_ s: String) -> String {
                    if s.contains(",") || s.contains("\"") || s.contains("\n") {
                        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                    }
                    return s
                }
                let vt = r.vehicleType ?? ""
                let vc = r.vehicleColor ?? ""
                csv += "\(r.id),\(iso.string(from: r.timestamp)),\(esc(r.cameraName)),\(esc(r.plate)),\(r.region.rawValue),\(String(format: "%.3f", r.confidence)),\(esc(vt)),\(esc(vc))\n"
            }
            try? csv.data(using: .utf8)?.write(to: url, options: .atomic)
        }
    }
}
