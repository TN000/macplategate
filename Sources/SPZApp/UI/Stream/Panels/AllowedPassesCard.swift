import SwiftUI

/// AllowedPassesCard — karta s historií whitelist průjezdů.
/// Extracted ze StreamView.swift jako součást big-refactor split (krok #10).

struct AllowedPassesCard: View {
    @EnvironmentObject var state: AppState
    @State private var tab: PassTab = .stats  // default po unlock posune se na .history
    @State private var showLoginPrompt: Bool = false
    @State private var pendingTabAfterLogin: PassTab?

    enum PassTab: String, CaseIterable, Identifiable {
        // STATISTIKY první (default veřejný), HISTORIE + SEZNAM login-gated.
        case stats = "Statistiky"
        case history = "Historie"
        case list = "Seznam"
        var id: String { rawValue }

        /// Vyžaduje přihlášení — bez auth je tab uzamčený.
        var requiresLogin: Bool {
            switch self {
            case .history, .list: return true
            case .stats: return false
            }
        }
    }

    private let visibleRows: CGFloat = 4
    private let rowHeight: CGFloat = 44
    private let rowSpacing: CGFloat = 1

    private var listHeight: CGFloat {
        rowHeight * visibleRows + rowSpacing * (visibleRows - 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                // Dva pill-style „cudliky" místo statického titulku — aktivní je
                // zelený, neaktivní transparent. Klik přepíná tab.
                ForEach(PassTab.allCases) { t in
                    Button(action: {
                        if t.requiresLogin && !state.isLoggedIn {
                            pendingTabAfterLogin = t
                            showLoginPrompt = true
                        } else {
                            tab = t
                        }
                    }) {
                        HStack(spacing: 5) {
                            if t.requiresLogin && !state.isLoggedIn {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            Text(LocalizedStringKey(t.rawValue.uppercased()))
                                .font(.system(size: 11, weight: .semibold))
                                .tracking(1.0)
                                .lineLimit(1)
                        }
                        .foregroundStyle(tab == t ? Color.black : Color.white.opacity(0.55))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(tab == t ? Color.green : Color.white.opacity(0.04))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                                    tab == t ? Color.green.opacity(0.4) : Color.white.opacity(0.06),
                                    lineWidth: 1))
                        )
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 10)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)

            Group {
                switch tab {
                case .list:
                    WhitelistEditor(listHeight: listHeight)
                case .history:
                    HistoryView(listHeight: listHeight)
                case .stats:
                    StatsView(listHeight: listHeight)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
        .onAppear {
            // Default tab když uživatel není logged → public Statistiky.
            if !state.isLoggedIn && tab.requiresLogin { tab = .stats }
        }
        .onChange(of: state.isLoggedIn) { _, loggedIn in
            // Po logout přepni zpět na public tab.
            if !loggedIn && tab.requiresLogin { tab = .stats }
        }
        .sheet(isPresented: $showLoginPrompt) {
            PasswordPromptSheet(
                expected: SPZAdminPassword,
                title: "Přihlášení",
                subtitle: "Tento panel vyžaduje přihlášení. Po úspěšném loginu budeš mít přístup ke všem chráněným sekcím (HISTORIE + SEZNAM).",
                showRememberToggle: true,
                onSuccess: {
                    state.isLoggedIn = true
                    showLoginPrompt = false
                    if let pending = pendingTabAfterLogin {
                        tab = pending
                        pendingTabAfterLogin = nil
                    }
                },
                onCancel: {
                    showLoginPrompt = false
                    pendingTabAfterLogin = nil
                }
            )
        }
        .onChange(of: state.isLoggedIn) { _, loggedIn in
            // Při odhlášení automaticky opustit SEZNAM tab, aby se chráněný
            // obsah nezobrazoval odhlášenému uživateli.
            if !loggedIn && tab == .list { tab = .history }
        }
    }
}
