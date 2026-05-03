import SwiftUI

/// Sheet pro přidání dočasného (denní platnost) záznamu do whitelistu.
/// Bez admin hesla — režim "denní vjezd" pro plánované návštěvy.
/// Auto-purged po `state.dailyPassExpiryHours` (default 24h).
///
/// Extracted ze `StreamView.swift` jako součást big-refactor split (krok #10).
struct AddDailyPassSheet: View {
    @EnvironmentObject var state: AppState
    let onClose: () -> Void

    @State private var plateInput: String = ""
    @State private var labelInput: String = ""
    @State private var error: String? = nil
    @FocusState private var focusedPlate: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.cyan)
                VStack(alignment: .leading, spacing: 3) {
                    Text("DENNÍ VJEZD")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.5)
                        .foregroundStyle(.secondary)
                    Text("Dočasný záznam do whitelistu")
                        .font(.system(size: 14, weight: .semibold))
                }
                Spacer()
            }

            Text("Platnost: \(state.dailyPassExpiryHours) hodin. Po této době se záznam automaticky smaže z whitelistu. Bez hesla — přístup volný.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("SPZ").font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(.secondary)
                TextField("5T2 1234", text: $plateInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, design: .monospaced))
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.08))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 1))
                    )
                    .focused($focusedPlate)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Jméno / firma").font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(.secondary)
                TextField("např. Doručovatel DPD", text: $labelInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.08))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 1))
                    )
            }

            if let error {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(.red)
                    Text(error).font(.system(size: 11)).foregroundStyle(.red)
                }
            }

            HStack(spacing: 8) {
                Button(action: onClose) {
                    Text("Zrušit").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .foregroundStyle(.primary)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.1), lineWidth: 1)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(action: submit) {
                    Text("Přidat").font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .foregroundStyle(Color.black)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.cyan))
                }
                .buttonStyle(PressAnimationStyle(cornerRadius: 7, flashColor: .white))
                .disabled(plateInput.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [Color(white: 0.10), Color(white: 0.06)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .onAppear { focusedPlate = true }
    }

    private func submit() {
        let plate = plateInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plate.isEmpty else {
            error = "SPZ nesmí být prázdná."
            return
        }
        let label = labelInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let expiry = Date().addingTimeInterval(TimeInterval(state.dailyPassExpiryHours) * 3600)
        KnownPlates.shared.add(plate: plate, label: label.isEmpty ? "Denní vjezd" : label, expiresAt: expiry)
        state.dailyPassesAddedTotal += 1
        FileHandle.safeStderrWrite(
            "[Manual] daily pass added plate=\(plate) label=\(label) expires=\(Store.sharedISO8601.string(from: expiry))\n"
                .data(using: .utf8) ?? Data())
        onClose()
    }
}
