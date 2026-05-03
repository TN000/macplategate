import SwiftUI
import AppKit

/// NetworkSection — extracted ze SettingsView.swift jako součást big-refactor split (krok #10).

struct NetworkSection: View {
    @EnvironmentObject var state: AppState
    @State private var interfaces: [NetworkDiag.Interface] = []

    /// První non-loopback IPv4 — kandidát URL pro přístup z LAN.
    private var preferredIP: String {
        interfaces.first(where: { !$0.ipv4.isEmpty && $0.ipv4 != "127.0.0.1" })?.ipv4 ?? "127.0.0.1"
    }

    private var webUIURL: String {
        "https://\(preferredIP):\(state.webUIPort)/"
    }

    var body: some View {
        SettingsCard("Webové UI", icon: "globe", accent: .green.opacity(0.85),
                     trailing: {
                        AnyView(
                            Toggle("", isOn: $state.webUIEnabled)
                                .toggleStyle(.switch).labelsHidden()
                        )
                     }) {
            Text("Vzdálené ovládání z prohlížeče v LAN — HTTPS + Basic Auth. Self-signed certifikát, prohlížeč jednorázově varuje (Advanced → Pokračovat).")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            StepperRow("Port", hint: "1024–65535, default 22224. Po změně se server restartuje.",
                       value: $state.webUIPort, range: 1024...65535, step: 1) { "\($0)" }

            VStack(alignment: .leading, spacing: 6) {
                Text("ADRESA").font(.system(size: 9, weight: .bold)).tracking(1.3)
                    .foregroundStyle(Color.white.opacity(0.45))
                HStack(spacing: 8) {
                    Text(LocalizedStringKey(webUIURL))
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(state.webUIEnabled ? .primary : .secondary)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(webUIURL, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 10))
                    }.buttonStyle(GhostButtonStyle())
                    .help("Zkopírovat URL")
                }

                Text("PŘIHLÁŠENÍ (uživatel / heslo)").font(.system(size: 9, weight: .bold)).tracking(1.3)
                    .foregroundStyle(Color.white.opacity(0.45))
                    .padding(.top, 4)
                HStack(spacing: 6) {
                    Text("admin /")
                        .font(.system(size: 12, design: .monospaced))
                    TextField("heslo (min 12 znaků, 3+ typů)", text: $state.webUIPassword)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.1), lineWidth: 1))
                        )
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(state.webUIPassword, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 10))
                    }.buttonStyle(GhostButtonStyle()).help("Zkopírovat heslo")
                    Button {
                        state.webUIPassword = generateStrongPassword(length: 20)
                    } label: {
                        Image(systemName: "wand.and.stars").font(.system(size: 10))
                    }.buttonStyle(GhostButtonStyle()).help("Vygenerovat silné heslo (20 znaků)")
                }
                // Live validation — proč webUI nepoběží.
                if let issue = WebServer.webUIPasswordRejection(state.webUIPassword) {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                        Text(LocalizedStringKey(issue))
                            .font(.system(size: 10))
                            .foregroundStyle(.orange.opacity(0.9))
                    }
                    Text("Pravidla: min. 12 znaků; alespoň 3 typy znaků (velká písmena, malá, číslice, speciální); žádný známý vzor jako \"admin\", \"heslo\", \"12345\", \"qwerty\".")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.white.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.green)
                        Text("Heslo splňuje pravidla")
                            .font(.system(size: 10))
                            .foregroundStyle(.green.opacity(0.9))
                    }
                }
            }

            Divider().background(Color.white.opacity(0.06))

            // Rate limit
            ToggleRow("Rate limit (blokace brute-force)",
                      hint: "Po 5 neúspěšných pokusech o přihlášení z jedné IP se ta IP zablokuje na 5 minut. Chrání proti hádání hesla. Doporučeno nechat zapnuté.",
                      isOn: $state.webUIRateLimitEnabled)

            Divider().background(Color.white.opacity(0.06))

            // IP whitelist
            VStack(alignment: .leading, spacing: 6) {
                Text("IP WHITELIST (volitelné)").font(.system(size: 9, weight: .bold)).tracking(1.3)
                    .foregroundStyle(Color.white.opacity(0.45))
                Text("CIDR ranges oddělené čárkou. Když prázdné, povolené všechny IP. Např.: 192.168.0.0/24, 10.0.0.0/8")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("192.168.0.0/24", text: $state.webUIAllowedCIDRs)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.1), lineWidth: 1))
                    )
            }

            HStack(spacing: 10) {
                Button("Znovu vygenerovat certifikát") {
                    _ = CertManager.regenerate()
                    if state.webUIEnabled {
                        WebServer.shared.bind(state: state)
                        WebServer.shared.start(port: UInt16(state.webUIPort))
                    }
                }
                .buttonStyle(GhostButtonStyle())
                .font(.system(size: 11))
                Spacer()
                if let d = CertManager.certCreationDate() {
                    Text("Cert z \(d.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }

        SettingsCard("Síťové rozhraní", icon: "network", accent: .cyan.opacity(0.8),
                     trailing: { AnyView(Button {
                        interfaces = NetworkDiag.listInterfaces()
                     } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10))
                     }.buttonStyle(GhostButtonStyle())) }) {
            if interfaces.isEmpty {
                Text("Načítám…").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(interfaces) { ifc in
                        HStack(spacing: 10) {
                            Image(systemName: ifc.icon)
                                .font(.system(size: 12)).foregroundStyle(ifc.color)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ifc.name.uppercased())
                                    .font(.system(size: 11, weight: .bold)).tracking(1.2)
                                Text(ifc.kind).font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(ifc.ipv4.isEmpty ? "—" : ifc.ipv4)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.primary.opacity(0.85))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.03))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.04), lineWidth: 1)))
                    }
                }
            }
        }
        SettingsCard("Info", icon: "info.circle", accent: .blue.opacity(0.8)) {
            Text("macOS vybírá rozhraní podle routovací tabulky (nejbližší subnet + metric). V kartě Kamery vidíš u každé IP info Route přes: enX — tak poznáš, zda stream jde přes ethernet (en0) nebo WiFi (en1).")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { interfaces = NetworkDiag.listInterfaces() }
    }
}

// MARK: - About

// MARK: - Security (change admin password)
