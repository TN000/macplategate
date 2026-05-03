import SwiftUI
import AppKit

/// SecuritySection — extracted ze SettingsView.swift jako součást big-refactor split (krok #10).

struct SecuritySection: View {
    @EnvironmentObject var state: AppState
    @State private var current: String = ""
    @State private var new1: String = ""
    @State private var new2: String = ""
    @State private var message: String? = nil
    @State private var isError: Bool = false

    var body: some View {
        SettingsCard("Admin heslo", icon: "lock.shield.fill", accent: .green.opacity(0.85)) {
            Text("Heslo chrání přístup k Nastavení, whitelist editoru a dalším admin akcím. Hash je uložený lokálně v chráněném souboru s právy 0600.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                fieldLabel("Současné heslo")
                SecureField("", text: $current)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(8)
                    .background(inputBg)

                fieldLabel("Nové heslo (min. 8 znaků)")
                SecureField("", text: $new1)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(8)
                    .background(inputBg)

                fieldLabel("Potvrzení nového hesla")
                SecureField("", text: $new2)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(8)
                    .background(inputBg)
            }

            if let m = message {
                HStack(spacing: 6) {
                    Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(isError ? Color.red : Color.green)
                    Text(LocalizedStringKey(m))
                        .font(.system(size: 11))
                        .foregroundStyle(isError ? Color.red : Color.green)
                }
            }

            HStack {
                Spacer()
                Button("Změnit heslo") { submit() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(current.isEmpty || new1.isEmpty || new2.isEmpty)
            }
        }
    }

    private var inputBg: some View {
        RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.06))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func fieldLabel(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.system(size: 9, weight: .bold)).tracking(1.3)
            .foregroundStyle(Color.white.opacity(0.45))
    }

    private func submit() {
        state.markAdminActivity()
        // Clear předchozí message aby user viděl, že se nová validace teď provádí.
        message = nil
        isError = false
        guard Auth.shared.verify(current) else {
            isError = true; message = "Současné heslo není správné."
            return
        }
        guard new1.count >= 8 else {
            isError = true; message = "Nové heslo musí mít alespoň 8 znaků."
            return
        }
        guard new1 == new2 else {
            isError = true; message = "Potvrzení nového hesla se neshoduje."
            return
        }
        do {
            try Auth.shared.setPassword(new1)
            isError = false
            message = "Heslo změněno. Initial-password soubor (pokud existoval) byl smazán."
            current = ""; new1 = ""; new2 = ""
        } catch {
            isError = true
            message = "Uložení hesla selhalo: \(error.localizedDescription)"
        }
    }
}
