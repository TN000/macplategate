import SwiftUI
import AppKit

/// WhitelistEditor — inline editor whitelistu v Seznam tabu.
/// Extracted ze StreamView.swift jako součást big-refactor split (krok #10).

struct WhitelistEditor: View {
    @ObservedObject private var known = KnownPlates.shared
    @State private var newPlate: String = ""
    @State private var newLabel: String = ""
    @State private var searchQuery: String = ""
    @State private var selected: KnownPlates.Entry? = nil
    @State private var deleteCandidate: KnownPlates.Entry? = nil
    let listHeight: CGFloat

    var body: some View {
        // WhitelistEditor je přístupný jen přihlášenému uživateli (SEZNAM tab
        // gate v AllowedPassesCard). Per-action password prompty proto není
        // třeba — přidání i mazání fire přímo.
        if let entry = selected {
            PersonDetailView(entry: entry, listHeight: listHeight, onBack: { selected = nil })
        } else {
            editorList
        }
    }

    /// Filtr s diacritic-insensitive case-insensitive substring match na jméno
    /// + plate no-space uppercase contains. Prázdný query → všechny entries.
    private var filteredEntries: [KnownPlates.Entry] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return known.entries }
        let qLabel = q.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let qPlate = q.uppercased()
            .components(separatedBy: .whitespacesAndNewlines).joined()
        return known.entries.filter { e in
            let labelFolded = e.label.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            if labelFolded.contains(qLabel) { return true }
            let platePlain = e.plate.replacingOccurrences(of: " ", with: "")
            if platePlain.contains(qPlate) { return true }
            return false
        }
    }

    private var editorList: some View {
        VStack(spacing: 10) {
            // Search bar — filtruje seznam podle SPZ nebo jména (s/bez diakritiky).
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("Hledat SPZ nebo jméno…", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.vertical, 7)
                if !searchQuery.isEmpty {
                    Button { searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(white: 0.08))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.08), lineWidth: 1))
            )

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    addPlateField
                    addLabelField
                    addButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        addPlateField
                        addButton
                    }
                    addLabelField
                }
            }

            if known.entries.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "star.slash").font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("Žádné známé SPZ.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).frame(height: listHeight - 110)
            } else if filteredEntries.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("Nic neodpovídá hledání.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).frame(height: listHeight - 110)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 4) {
                        ForEach(filteredEntries) { e in
                            Button(action: { selected = e }) {
                                HStack(spacing: 10) {
                                    Text(e.plate)
                                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Color(red: 15/255, green: 15/255, blue: 20/255))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.72)
                                        .padding(.horizontal, 9).padding(.vertical, 3)
                                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white))
                                    Text(e.label).font(.system(size: 12))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Spacer()
                                    gateActionBadge(for: e)
                                    holdShadowButton(for: e)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                    Button {
                                        deleteCandidate = e
                                    } label: {
                                        Image(systemName: "trash").font(.system(size: 11))
                                    }
                                    .buttonStyle(.borderless).foregroundStyle(.red.opacity(0.7))
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.05), lineWidth: 1)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(height: listHeight - 110)
            }
        }
        .padding(.horizontal, 12).padding(.top, 0).padding(.bottom, 10)
        .alert("Smazat SPZ ze seznamu?", isPresented: Binding(
            get: { deleteCandidate != nil },
            set: { if !$0 { deleteCandidate = nil } }
        ), presenting: deleteCandidate) { entry in
            Button("Smazat", role: .destructive) {
                known.remove(plate: entry.plate)
                deleteCandidate = nil
            }
            Button("Zrušit", role: .cancel) {
                deleteCandidate = nil
            }
        } message: { entry in
            Text("\(entry.plate) — \(entry.label)\n\nSmaže se z whitelistu i historie parkovacích sessionů této SPZ. Akce je nevratná.")
        }
    }

    private var addPlateField: some View {
        TextField("5T2 1234", text: $newPlate)
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            .padding(8)
            .background(inputBg)
            .frame(width: 130)
    }

    private var addLabelField: some View {
        TextField("Jméno Příjmení", text: $newLabel)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(8)
            .background(inputBg)
    }

    private var addButton: some View {
        Button(action: {
            known.add(plate: newPlate, label: newLabel.isEmpty ? newPlate : newLabel)
            newPlate = ""; newLabel = ""
        }) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(Color.black)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.green))
        }
        .buttonStyle(.plain)
        .disabled(newPlate.isEmpty)
    }

    private var inputBg: some View {
        RoundedRectangle(cornerRadius: 7).fill(Color(white: 0.08))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func gateActionBadge(for entry: KnownPlates.Entry) -> some View {
        Button {
            let next = entry.gateAction == GateAction.openExtended.rawValue
                ? GateAction.openShort.rawValue
                : GateAction.openExtended.rawValue
            known.updateGateOptions(plate: entry.plate, gateAction: next)
        } label: {
            Text(entry.gateAction == GateAction.openExtended.rawValue ? "BUS" : "1s")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(entry.gateAction == GateAction.openExtended.rawValue ? Color.black : Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(entry.gateAction == GateAction.openExtended.rawValue ? Color.orange : Color.white.opacity(0.06))
                )
        }
        .buttonStyle(.borderless)
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
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help("Shadow režim: auditovat, že by se závora držela otevřená dokud je auto v záběru.")
    }
}
