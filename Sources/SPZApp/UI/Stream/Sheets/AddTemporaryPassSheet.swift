import SwiftUI

/// Sheet pro přidání **dočasného vjezdu s vlastním datem expirace** do whitelistu.
/// Bez admin hesla — pro plánované návštěvy delší než denní (např. týden u nás
/// staví). Default expiry = +7 dní, user může vybrat libovolné datum + čas v
/// rozsahu (now + 1h … now + 1 rok). Po expiry se entry automaticky odstraní
/// z whitelistu (sdílená logika s daily passes).
struct AddTemporaryPassSheet: View {
    @EnvironmentObject var state: AppState
    let onClose: () -> Void

    @State private var plateInput: String = ""
    @State private var labelInput: String = ""
    @State private var expiryDate: Date = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var error: String? = nil
    @FocusState private var focusedPlate: Bool

    /// Range pro picker — minimum +1h od teď (nesmysl past), max +1 rok.
    private var dateRange: ClosedRange<Date> {
        let now = Date()
        let minDate = now.addingTimeInterval(3600)
        let maxDate = Calendar.current.date(byAdding: .year, value: 1, to: now) ?? now
        return minDate...maxDate
    }

    private var humanDuration: String {
        let interval = expiryDate.timeIntervalSince(Date())
        let days = Int(interval / 86400)
        let hours = Int(interval.truncatingRemainder(dividingBy: 86400) / 3600)
        if days >= 1 {
            return "\(days) \(days == 1 ? "den" : (days < 5 ? "dny" : "dní"))" + (hours > 0 ? " \(hours) h" : "")
        }
        return "\(hours) h"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.purple)
                VStack(alignment: .leading, spacing: 3) {
                    Text("DOČASNÝ VJEZD")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.5)
                        .foregroundStyle(.secondary)
                    Text("Vjezd do zvoleného data")
                        .font(.system(size: 14, weight: .semibold))
                }
                Spacer()
            }

            Text("Pro delší návštěvy (např. tydenní brigáda u nás). Vyber datum a čas, kdy má vjezd vypršet — entry se po této době automaticky smaže z whitelistu. Bez hesla — přístup volný.")
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
                TextField("např. Stavební firma XY", text: $labelInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.08))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 1))
                    )
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Platí do").font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(.secondary)
                    Spacer()
                    Text(humanDuration)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.purple.opacity(0.85))
                }
                DatePicker("",
                           selection: $expiryDate,
                           in: dateRange,
                           displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.08))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 1))
                    )
                HStack(spacing: 8) {
                    quickPresetButton("+1 den", days: 1)
                    quickPresetButton("+3 dny", days: 3)
                    quickPresetButton("+1 týden", days: 7)
                    quickPresetButton("+2 týdny", days: 14)
                    quickPresetButton("+1 měsíc", days: 30)
                }
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
                        .foregroundStyle(Color.white)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.purple))
                }
                .buttonStyle(PressAnimationStyle(cornerRadius: 7, flashColor: .white))
                .disabled(plateInput.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [Color(white: 0.10), Color(white: 0.06)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .onAppear { focusedPlate = true }
    }

    private func quickPresetButton(_ label: String, days: Int) -> some View {
        Button(action: {
            if let d = Calendar.current.date(byAdding: .day, value: days, to: Date()) {
                expiryDate = d
            }
        }) {
            Text(LocalizedStringKey(label))
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .foregroundStyle(Color.purple.opacity(0.95))
                .background(
                    Capsule()
                        .fill(Color.purple.opacity(0.10))
                        .overlay(Capsule().stroke(Color.purple.opacity(0.3), lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
    }

    private func submit() {
        let plate = plateInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plate.isEmpty else {
            error = "SPZ nesmí být prázdná."
            return
        }
        guard expiryDate > Date() else {
            error = "Datum expirace musí být v budoucnosti."
            return
        }
        let label = labelInput.trimmingCharacters(in: .whitespacesAndNewlines)
        KnownPlates.shared.add(plate: plate,
                               label: label.isEmpty ? "Dočasný vjezd" : label,
                               expiresAt: expiryDate)
        state.dailyPassesAddedTotal += 1
        FileHandle.safeStderrWrite(
            "[Manual] temporary pass added plate=\(plate) label=\(label) expires=\(Store.sharedISO8601.string(from: expiryDate))\n"
                .data(using: .utf8) ?? Data())
        onClose()
    }
}
