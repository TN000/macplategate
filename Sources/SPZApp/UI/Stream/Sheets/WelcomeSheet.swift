import SwiftUI
import AppKit

/// First-run modal — zobrazuje vygenerované initial admin heslo.
/// Spouští se z `ContentView.onAppear` jen pokud `Auth.shared.readInitialPasswordIfExists()`
/// vrací non-nil (= user zatím heslo nezměnil). Po dismissu vede přímo na PasswordPromptSheet.
struct WelcomeSheet: View {
    let initialPassword: String
    let onContinue: () -> Void

    @State private var copied: Bool = false

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "key.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text("VÍTEJ V MACPLATEGATE")
                        .font(.system(size: 10, weight: .bold)).tracking(1.5)
                        .foregroundStyle(.secondary)
                    Text("První spuštění — počáteční heslo")
                        .font(.system(size: 14, weight: .semibold))
                }
                Spacer()
            }

            Text("Pro přístup do Nastavení a whitelistu bylo vygenerováno bezpečné náhodné heslo. Zkopíruj ho a po prvním přihlášení ho změň v Nastavení → Bezpečnost. Tento dialog se víc neobjeví poté co heslo změníš.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(initialPassword)
                    .font(.system(size: 16, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(white: 0.08))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.1), lineWidth: 1))
                    )
                Button(action: copy) {
                    Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(.system(size: 16))
                        .foregroundStyle(copied ? Color.green : Color.white)
                        .frame(width: 38, height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white.opacity(0.06))
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white.opacity(0.1), lineWidth: 1))
                        )
                }
                .buttonStyle(.plain)
                .help("Zkopírovat heslo do schránky")
            }

            Text("Heslo je uložené i v souboru ~/Library/Application Support/MacPlateGate/admin-initial-password.txt (perms 0600). Soubor se automaticky smaže po první změně hesla.")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(action: onContinue) {
                    Text("Pokračovat na přihlášení")
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .foregroundStyle(Color.black)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.green))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(
                    colors: [Color(white: 0.10), Color(white: 0.06)],
                    startPoint: .top, endPoint: .bottom))
        )
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(initialPassword, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}
