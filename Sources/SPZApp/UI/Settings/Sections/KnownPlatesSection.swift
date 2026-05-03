import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// KnownPlatesSection — extracted ze SettingsView.swift jako součást big-refactor split (krok #10).

struct KnownPlatesSection: View {
    @ObservedObject private var known = KnownPlates.shared
    @State private var newPlate: String = ""
    @State private var newLabel: String = ""
    @State private var deleteCandidate: KnownPlates.Entry? = nil
    @State private var csvFeedback: String? = nil
    @State private var csvFeedbackColor: Color = .green

    var body: some View {
        SettingsCard("Whitelist", icon: "star.fill", accent: .yellow.opacity(0.85),
                     trailing: { AnyView(Text("\(known.entries.count)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)) }) {
            Text("Seznam povolených SPZ (automaticky otevírá závoru). Aplikace toleruje 1 chybu ve čtení — např. místo 4GH5678 přečte 4GHI678 a stejně najde shodu. Pro zaměstnance a známé dodavatele, kteří mají právo vjezdu.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("5T2 1234", text: $newPlate)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(8).background(inputBg)
                    .frame(width: 140)
                TextField("Jméno Příjmení", text: $newLabel)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(8).background(inputBg)
                Button("Přidat") {
                    known.add(plate: newPlate, label: newLabel.isEmpty ? newPlate : newLabel)
                    newPlate = ""; newLabel = ""
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(newPlate.isEmpty)
            }

            // CSV bulk operations
            HStack(spacing: 8) {
                Button {
                    exportCSV()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 10))
                        Text("Exportovat CSV").font(.system(size: 11, weight: .semibold))
                    }
                }.buttonStyle(GhostButtonStyle())
                Button {
                    importCSV()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down").font(.system(size: 10))
                        Text("Importovat CSV").font(.system(size: 11, weight: .semibold))
                    }
                }.buttonStyle(GhostButtonStyle())
                if let msg = csvFeedback {
                    Text(LocalizedStringKey(msg))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(csvFeedbackColor)
                        .lineLimit(1)
                }
                Spacer()
            }

            if known.entries.isEmpty {
                Text("Zatím žádné.").font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 5) {
                    ForEach(known.entries) { e in
                        HStack(spacing: 10) {
                            Text(e.plate)
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color(red: 15/255, green: 15/255, blue: 20/255))
                                .padding(.horizontal, 9).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white))
                            Text(e.label).font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            gateActionPicker(for: e)
                            holdShadowButton(for: e)
                            Text(e.added.formatted(date: .abbreviated, time: .omitted))
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                            Button { deleteCandidate = e } label: {
                                Image(systemName: "trash").font(.system(size: 11))
                            }
                            .buttonStyle(.borderless).foregroundStyle(.red.opacity(0.7))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.03))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.04), lineWidth: 1)))
                    }
                }
            }
        }
        .alert("Smazat SPZ ze seznamu?", isPresented: Binding(
            get: { deleteCandidate != nil },
            set: { if !$0 { deleteCandidate = nil } }
        ), presenting: deleteCandidate) { entry in
            Button("Smazat", role: .destructive) {
                known.remove(plate: entry.plate); deleteCandidate = nil
            }
            Button("Zrušit", role: .cancel) { deleteCandidate = nil }
        } message: { entry in
            Text("\(entry.plate) — \(entry.label)\n\nSmaže se z whitelistu i historie parkovacích sessionů této SPZ. Akce je nevratná.")
        }
    }

    private var inputBg: some View {
        RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.06))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func gateActionPicker(for entry: KnownPlates.Entry) -> some View {
        Picker("", selection: Binding(
            get: { entry.gateAction },
            set: { known.updateGateOptions(plate: entry.plate, gateAction: $0) }
        )) {
            Text("Krátce").tag(GateAction.openShort.rawValue)
            Text("Autobus").tag(GateAction.openExtended.rawValue)
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 98)
        .help("Shadow režim: ALPR zatím fyzicky otevře krátce, ale audit zapíše zamýšlenou akci.")
    }

    private func holdShadowButton(for entry: KnownPlates.Entry) -> some View {
        Button {
            known.updateGateOptions(plate: entry.plate,
                                    holdWhilePresent: !entry.holdWhilePresent)
        } label: {
            Image(systemName: entry.holdWhilePresent ? "hand.raised.fill" : "hand.raised")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(entry.holdWhilePresent ? Color.orange : Color.secondary)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .help("Shadow režim: auditovat, že by se závora držela otevřená dokud je auto v záběru.")
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "csv") ?? .commaSeparatedText]
        panel.nameFieldStringValue = "spz-whitelist.csv"
        panel.title = "Export whitelistu do CSV"
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            do {
                try known.exportCSV(to: url)
                Task { @MainActor in
                    showCSVFeedback("Exportováno \(known.entries.count) SPZ", color: .green)
                }
            } catch {
                Task { @MainActor in
                    showCSVFeedback("Chyba: \(error.localizedDescription)", color: .red)
                }
            }
        }
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "csv") ?? .commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.title = "Import whitelistu z CSV"
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            do {
                let res = try known.importCSV(from: url)
                Task { @MainActor in
                    showCSVFeedback("Přidáno: \(res.added), upraveno: \(res.updated), přeskočeno: \(res.skipped)", color: .green)
                }
            } catch {
                Task { @MainActor in
                    showCSVFeedback("Chyba: \(error.localizedDescription)", color: .red)
                }
            }
        }
    }

    private func showCSVFeedback(_ text: String, color: Color) {
        csvFeedback = text
        csvFeedbackColor = color
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if csvFeedback == text { csvFeedback = nil }
        }
    }
}

// MARK: - Webhook
