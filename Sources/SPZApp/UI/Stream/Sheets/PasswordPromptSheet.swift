import SwiftUI

/// Sheet pro ověření admin hesla — používá se před přidáním SPZ do whitelistu,
/// odebráním sessions, správou kamer atd. (citlivé operace).
///
/// Extracted ze `StreamView.swift` jako součást big-refactor split (krok #10).
struct PasswordPromptSheet: View {
    let expected: String
    var title: String = "Přidání SPZ do whitelistu"
    var subtitle: String = "Zadej administrativní heslo pro provedení této akce."
    /// Pokud true, zobrazí se "Zapamatovat heslo" checkbox. Při zaškrtnutí
    /// a úspěšné verifikaci se heslo uloží lokálně pro auto-login
    /// při příštím startu aplikace.
    var showRememberToggle: Bool = false
    let onSuccess: () -> Void
    let onCancel: () -> Void

    @State private var input: String = ""
    @State private var error: Bool = false
    @State private var remember: Bool = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text("OVĚŘENÍ HESLA").font(.system(size: 10, weight: .bold)).tracking(1.5)
                        .foregroundStyle(.secondary)
                    Text(LocalizedStringKey(title)).font(.system(size: 14, weight: .semibold))
                }
                Spacer()
            }

            Text(LocalizedStringKey(subtitle))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Heslo", text: $input)
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .monospaced))
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(white: 0.08))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                            error ? Color.red.opacity(0.6) : Color.white.opacity(0.1),
                            lineWidth: 1))
                )
                .focused($focused)
                .onSubmit { submit() }

            if error {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(.red)
                    Text("Nesprávné heslo.")
                        .font(.system(size: 11)).foregroundStyle(.red)
                }
            }

            if showRememberToggle {
                Toggle(isOn: $remember) {
                    Text("Zapamatovat heslo (uloženo v Klíčence macOS)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)
            }

            HStack(spacing: 8) {
                Button(action: onCancel) {
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
                    Text("Potvrdit").font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .foregroundStyle(Color.black)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.green))
                }
                .buttonStyle(PressAnimationStyle(cornerRadius: 7, flashColor: .white))
                .disabled(input.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [Color(white: 0.10), Color(white: 0.06)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .onAppear { focused = true }
    }

    private func submit() {
        // Verifikace přes Auth.shared.
        if Auth.shared.verify(input) {
            error = false
            if showRememberToggle && remember {
                Auth.shared.rememberPassword(input)
            }
            onSuccess()
        } else {
            error = true
            input = ""
        }
    }
}
