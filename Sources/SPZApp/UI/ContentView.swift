import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var selectedTab: Tab = .stream
    @State private var showLoginPrompt: Bool = false
    /// Akce k provedení po úspěšném loginu (např. přepnutí na Settings). Nil =
    /// prostý login přes horní tlačítko, žádná follow-up akce.
    @State private var pendingAfterLogin: (() -> Void)? = nil
    @State private var showWelcomeSheet: Bool = false
    @State private var welcomeInitialPassword: String? = nil

    enum Tab: String, CaseIterable, Identifiable {
        case stream = "Živě"
        case settings = "Nastavení"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .stream: return "play.rectangle.fill"
            case .settings: return "slider.horizontal.3"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(
                selectedTab: $selectedTab,
                onRequestSettings: {
                    if state.isLoggedIn {
                        selectedTab = .settings
                    } else {
                        pendingAfterLogin = { selectedTab = .settings }
                        showLoginPrompt = true
                    }
                },
                onLoginTap: {
                    if state.isLoggedIn {
                        state.isLoggedIn = false
                    } else {
                        pendingAfterLogin = nil
                        showLoginPrompt = true
                    }
                }
            )
            Group {
                switch selectedTab {
                case .stream: StreamTabView()
                case .settings: SettingsTabView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(BackgroundLayer().ignoresSafeArea())
        .sheet(isPresented: $showLoginPrompt) {
            PasswordPromptSheet(
                expected: SPZAdminPassword,
                title: "Přihlášení",
                subtitle: "Zadej administrativní heslo. Po přihlášení budeš mít přístup k Nastavení a whitelist sekci dokud se neodhlásíš.",
                showRememberToggle: true,
                onSuccess: {
                    state.isLoggedIn = true
                    showLoginPrompt = false
                    pendingAfterLogin?()
                    pendingAfterLogin = nil
                },
                onCancel: {
                    showLoginPrompt = false
                    pendingAfterLogin = nil
                }
            )
        }
        .sheet(isPresented: $showWelcomeSheet) {
            WelcomeSheet(
                initialPassword: welcomeInitialPassword ?? "",
                onContinue: {
                    showWelcomeSheet = false
                    showLoginPrompt = true
                }
            )
        }
        .onChange(of: state.isLoggedIn) { _, loggedIn in
            // Při odhlášení automaticky opustit Settings tab + smazat
            // zapamatované heslo (explicit logout = user chce end session).
            if !loggedIn {
                Auth.shared.clearRememberedPassword()
                if selectedTab == .settings { selectedTab = .stream }
            }
        }
        .onAppear {
            // Auto-unlock: pokud user při posledním přihlášení zaškrtl
            // "Zapamatovat", vytáhni uložené heslo a pusť do stavu.
            if !state.isLoggedIn, Auth.shared.recallPassword() != nil {
                state.isLoggedIn = true
            } else if !state.isLoggedIn,
                      let initial = Auth.shared.readInitialPasswordIfExists() {
                // First-run: heslo nebylo nikdy změněno → ukaž ho user-friendly
                // místo aby ho hledal v admin-initial-password.txt na disku.
                welcomeInitialPassword = initial
                showWelcomeSheet = true
            }
            // Spustí Shelly health probe na app-level (ne per-tab) — header
            // bar zobrazuje status + teplotu vždy, takže probe musí běžet
            // i mimo Stream tab. Default interval 60 s (per user request).
            ShellyHealthProbe.shared.start(state: state, intervalSec: 60.0)
        }
    }
}

private struct HeaderBar: View {
    @EnvironmentObject var state: AppState
    @Binding var selectedTab: ContentView.Tab
    let onRequestSettings: () -> Void
    let onLoginTap: () -> Void
    @Namespace private var tabPicker

    var body: some View {
        // Always show stats — removed ViewThatFits fallback.
        // CompactStatsBar gracefully scales with .minimumScaleFactor(0.72) on labels.
        headerRow(showStats: true)
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.md)
        .background(
            Color.black.opacity(0.3)
                .overlay(
                    Rectangle().fill(DS.Color.border).frame(height: 0.5),
                    alignment: .bottom
                )
        )
    }

    private func headerRow(showStats: Bool) -> some View {
        HStack(spacing: DS.Space.lg) {
            // Animated segmented tab picker — matchedGeometryEffect smooth glide
            // mezi tabs (snap spring), žádný hard snap.
            HStack(spacing: 0) {
                ForEach(ContentView.Tab.allCases) { tab in
                    let active = selectedTab == tab
                    Button(action: {
                        if tab == .settings && selectedTab != .settings {
                            onRequestSettings()
                        } else {
                            withAnimation(DS.Motion.snap) { selectedTab = tab }
                        }
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 10, weight: .semibold))
                            Text(LocalizedStringKey(tab.rawValue.uppercased()))
                                .font(.system(size: 11, weight: .semibold))
                                .tracking(1.0)
                        }
                        .foregroundStyle(active ? Color.black : DS.Color.textSecondary)
                        .padding(.horizontal, DS.Space.md)
                        .padding(.vertical, 5)
                        .background(
                            ZStack {
                                if active {
                                    RoundedRectangle(cornerRadius: DS.Radius.sm)
                                        .fill(DS.Color.success)
                                        .matchedGeometryEffect(id: "activeTab", in: tabPicker)
                                }
                            }
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md)
                    .fill(DS.Color.bg2.opacity(0.5))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.md)
                        .stroke(DS.Color.border, lineWidth: 0.5))
            )

            if showStats {
                CompactStatsBar()
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }

            Spacer(minLength: DS.Space.sm)

            LoginBadge(isLoggedIn: state.isLoggedIn, onTap: onLoginTap)
            ShellyMiniBadge()
            HealthBadge()
            StatusBadge()
        }
    }
}

/// Mini Shelly badge — vedle HealthBadge mezi ostatními status checker-y.
/// Ukazuje stav relé jako malý kruhový tint indicator + label "Shelly" + malinkou
/// teplotu (subscriptem) pokud je k dispozici. Klik = okamžitý refresh probe.
private struct ShellyMiniBadge: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var shelly = ShellyHealthProbe.shared

    private var statusTint: Color {
        switch shelly.status {
        case .idle: return DS.Color.textSecondary
        case .ok: return DS.Color.success
        case .slow: return .yellow
        case .unreachable: return DS.Color.danger
        case .http: return .orange
        }
    }

    private var statusLabel: String {
        if state.gateBaseURL.isEmpty { return "Bez relé" }
        switch shelly.status {
        case .idle: return "Shelly ?"
        case .ok: return "Shelly"
        case .slow: return "Shelly pomalý"
        case .unreachable: return "Shelly off"
        case .http(let s): return "Shelly \(s)"
        }
    }

    private func tempColor(for t: Double) -> Color {
        if t >= 85 { return DS.Color.danger }
        if t >= 70 { return .yellow }
        return DS.Color.textSecondary
    }

    var body: some View {
        Button(action: { shelly.refresh() }) {
            HStack(spacing: 5) {
                Circle().fill(statusTint).frame(width: 6, height: 6)
                Text(LocalizedStringKey(statusLabel))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary)
                if !state.gateBaseURL.isEmpty, let t = shelly.relayTempC {
                    Text(String(format: "%.0f°", t))
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(tempColor(for: t).opacity(0.9))
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(DS.Color.bg2.opacity(0.5))
                    .overlay(Capsule().stroke(DS.Color.border, lineWidth: 0.5))
            )
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private var helpText: String {
        if state.gateBaseURL.isEmpty {
            return "Není nastavený Shelly base URL — provoz bez fyzického relé"
        }
        var s = "Klik = okamžitá kontrola Shelly. Probe běží automaticky každých 60 s."
        if let t = shelly.relayTempC {
            s += String(format: "\nTeplota relé: %.1f °C  (warning ≥ 70, kritická ≥ 85)", t)
        }
        return s
    }
}

/// Login/logout toggle. Šedý když odhlášen, zelený když přihlášen.
private struct LoginBadge: View {
    let isLoggedIn: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            DSPill(
                label: isLoggedIn ? "Odhlásit" : "Přihlásit",
                icon: isLoggedIn ? "lock.open.fill" : "lock.fill",
                tint: isLoggedIn ? DS.Color.success : DS.Color.textSecondary
            )
        }
        .buttonStyle(.plain)
        .help(isLoggedIn ? "Kliknutím se odhlásíš" : "Kliknutím se přihlásíš")
    }
}

private struct StatusBadge: View {
    @EnvironmentObject var cameras: CameraManager
    private var connected: Bool { cameras.anyConnected }

    var body: some View {
        DSPill(
            label: connected ? "Živě" : "Nepřipojeno",
            tint: connected ? DS.Color.success : DS.Color.danger,
            dotPulse: connected
        )
    }
}

/// Souhrnné zdravotní tlačítko — zelená/žluta/červená tečka + tooltip se seznamem
/// check výsledků. Kliknutí = popover s plným detailem.
private struct HealthBadge: View {
    @EnvironmentObject var health: HealthMonitor
    @State private var showDetail = false

    private var tint: Color {
        switch health.overall {
        case .ok: return DS.Color.success
        case .warning: return DS.Color.warning
        case .error: return DS.Color.danger
        }
    }

    private var label: String {
        switch health.overall {
        case .ok: return "OK"
        case .warning: return "Pozor"
        case .error: return "Chyba"
        }
    }

    private var tooltip: String {
        health.checks.map { c -> String in
            let sym: String
            switch c.level {
            case .ok: sym = "✓"
            case .warning: sym = "!"
            case .error: sym = "✗"
            }
            return "\(sym) \(c.name): \(c.detail)"
        }.joined(separator: "\n")
    }

    var body: some View {
        Button(action: { showDetail.toggle() }) {
            DSPill(label: label, tint: tint)
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .popover(isPresented: $showDetail, arrowEdge: .top) {
            HealthDetailPopover()
                .environmentObject(health)
        }
    }
}

private struct HealthDetailPopover: View {
    @EnvironmentObject var health: HealthMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PROVOZNÍ STAV")
                .font(.system(size: 10, weight: .bold)).tracking(1.8)
                .foregroundStyle(.secondary)
            ForEach(Array(health.checks.enumerated()), id: \.offset) { _, c in
                HStack(spacing: 10) {
                    Circle()
                        .fill(color(for: c.level))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.name).font(.system(size: 12, weight: .semibold))
                        Text(c.detail).font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
            }
            Divider().padding(.vertical, 2)
            Text("Obnoveno: \(health.lastUpdate.formatted(date: .omitted, time: .standard))")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 320)
    }

    private func color(for level: HealthMonitor.Level) -> Color {
        switch level {
        case .ok: return .green
        case .warning: return .yellow
        case .error: return .red
        }
    }
}

/// Animated background — slow drifting mesh gradient. Apple Vision Pro / Sonoma
/// dynamic wallpaper feel. M4 GPU renders v <0.5 ms per frame.
private struct BackgroundLayer: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        ZStack {
            // Base — warm dark s blue tint.
            DS.Color.bg0
            // Top-left aurora — subtle green glow (matches accent).
            RadialGradient(
                colors: [
                    DS.Color.success.opacity(0.18),
                    .clear
                ],
                center: UnitPoint(x: 0.1 + 0.05 * sin(phase), y: 0.05),
                startRadius: 0,
                endRadius: 700
            )
            // Bottom-right aurora — purple/info accent.
            RadialGradient(
                colors: [
                    DS.Color.accent.opacity(0.20),
                    .clear
                ],
                center: UnitPoint(x: 0.95 - 0.06 * cos(phase), y: 1.0),
                startRadius: 0,
                endRadius: 800
            )
            // Center subtle blue lift — depth.
            RadialGradient(
                colors: [
                    DS.Color.info.opacity(0.08),
                    .clear
                ],
                center: UnitPoint(x: 0.5, y: 0.5 + 0.1 * sin(phase * 0.7)),
                startRadius: 0,
                endRadius: 500
            )
        }
        .onAppear {
            withAnimation(.linear(duration: 30).repeatForever(autoreverses: true)) {
                phase = .pi * 2
            }
        }
    }
}
