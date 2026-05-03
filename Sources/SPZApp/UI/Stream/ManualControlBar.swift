import SwiftUI
import AppKit

/// ManualControlBar — úzký panel s manuálními akcemi nad kamerami.
/// Extracted ze StreamView.swift jako součást big-refactor split (krok #10).

struct ManualControlBar: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var cameras: CameraManager
    @ObservedObject private var hook = WebhookClient.shared
    @ObservedObject private var holdController = GateHoldController.shared
    @ObservedObject private var shelly = ShellyHealthProbe.shared
    @State private var showAddSheet: Bool = false
    @State private var showTempSheet: Bool = false
    @State private var lastFireTs: Date? = nil
    @State private var feedback: String? = nil
    @State private var feedbackColor: Color = .green
    /// Tick každou 1 s pro hold timer overlay (5.2s, 6.2s, …).
    @State private var holdTickerNow: Date = Date()

    /// Barva health dot u OTEVŘÍT VJEZD dle posledního webhook fire.
    /// Šedá = ještě nefired, zelená = 2xx do 60 s zpátky, oranžová = 2xx+ starší,
    /// červená = non-2xx (persistent fail).
    private var webhookStatusColor: Color {
        guard let last = hook.lastFired else { return .gray }
        let age = Date().timeIntervalSince(last.ts)
        if last.status >= 200 && last.status < 300 {
            return age < 60 ? .green : .green.opacity(0.5)
        }
        return .red
    }

    private var webhookStatusHint: String {
        guard let last = hook.lastFired else { return "Webhook ještě nebyl odeslán." }
        let age = Int(Date().timeIntervalSince(last.ts))
        let status = last.status == -1 ? "bez odpovědi" : "HTTP \(last.status)"
        return "Poslední: \(status) před \(age) s"
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                openGateButton
                if state.gateScenariosEnabled {
                    busButton
                    holdButton
                }
                if state.shellyVyjezdEnabled {
                    openVyjezdButton
                }
                Spacer(minLength: 6)
                shellyPushEventBadge
                feedbackBadge
                Spacer(minLength: 6)
                temporaryPassButton
                dailyPassButton
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    openGateButton
                    if state.gateScenariosEnabled {
                        busButton
                        holdButton
                    }
                    if state.shellyVyjezdEnabled {
                        openVyjezdButton
                    }
                    Spacer(minLength: 6)
                    shellyPushEventBadge
                    feedbackBadge
                    Spacer(minLength: 6)
                    temporaryPassButton
                    dailyPassButton
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.35))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06), lineWidth: 1))
        )
        .sheet(isPresented: $showAddSheet) {
            AddDailyPassSheet(onClose: { showAddSheet = false })
        }
        .sheet(isPresented: $showTempSheet) {
            AddTemporaryPassSheet(onClose: { showTempSheet = false })
        }
        // Tick každou 1 s během holdu, aby overlay aktualizoval "(5.2s)" čítač.
        // Mimo hold mode je timer no-op (computed property `isHolding` false).
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { now in
            if holdController.isHolding { holdTickerNow = now }
        }
    }

    /// Push event hláška o posledním stavovém přechodu na Shelly relé.
    /// Z probe state-transition detekce — když relé sepnulo (output false→true)
    /// nebo se vypnulo (true→false), zobrazí lidsky čitelnou hlášku:
    ///   • "Shelly: relé sepnulo přes HTTP_in · před 8 s"
    ///   • "Shelly: timer dokončen · před 1 s"
    ///   • "Shelly: ručně vypnuto · před 12 s"
    /// Pokud probe ještě žádný transition nezachytil, badge je skrytý.
    /// Klik = okamžitý refresh (může chytit transition co probe minul).
    @ViewBuilder
    private var shellyPushEventBadge: some View {
        if state.gateBaseURL.isEmpty {
            EmptyView()
        } else if let evt = shelly.lastStateChange {
            let isOn = evt.kind == "switch.on"
            let icon = isOn ? "bolt.fill" : "bolt.slash"
            let color: Color = isOn ? .green : .gray
            let kindShort = isOn ? "ON" : "OFF"
            let srcShort = compactSource(evt.source)
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(color)
                Text(LocalizedStringKey(kindShort))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(color)
                Text("· \(srcShort) · \(timeAgo(evt.at))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(color.opacity(0.08))
                    .overlay(Capsule().stroke(color.opacity(0.3), lineWidth: 1))
            )
            .onTapGesture { shelly.refresh() }
            .help("Shelly: \(isOn ? "relé sepnulo" : "relé vypnuto")\nDůvod: \(humanSource(evt.source))\nKlik = okamžitý refresh.")
            .animation(.easeInOut(duration: 0.25), value: evt.at)
        }
    }

    /// Kompaktní verze source (pro malé bagde uvnitř lišty).
    private func compactSource(_ source: String) -> String {
        switch source {
        case "HTTP_in", "RPC", "WS_in": return "HTTP"
        case "timer": return "TIMER"
        case "input": return "BTN"
        case "MQTT": return "MQTT"
        case "init": return "INIT"
        default: return source.uppercased().prefix(6).description
        }
    }

    /// Mapuje raw Shelly source string na lidskou hlášku.
    private func humanSource(_ source: String) -> String {
        switch source {
        case "HTTP_in", "RPC", "WS_in": return "přes HTTP webhook"
        case "timer": return "auto-vypnutí (timer)"
        case "input": return "fyzické tlačítko"
        case "init": return "po startu Shelly"
        case "loopback": return "interní script"
        default: return source
        }
    }

    /// Lidský čas-od formát: "0 s", "8 s", "47 s", "2 m", "1 h".
    private func timeAgo(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "před \(s) s" }
        if s < 3600 { return "před \(s/60) m" }
        return "před \(s/3600) h"
    }

    private var openGateButton: some View {
        Button(action: openVjezdManually) {
            HStack(spacing: 8) {
                Image(systemName: "lock.open.fill")
                    .font(.system(size: 11, weight: .bold))
                Text("OTEVŘÍT VJEZD")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                // Health dot — stav posledního webhook fire.
                Circle()
                    .fill(webhookStatusColor)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(Color.black.opacity(0.3), lineWidth: 0.5))
            }
            .foregroundStyle(Color.black)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(colors: [Color.green, Color(red: 0.2, green: 0.75, blue: 0.35)],
                                         startPoint: .leading, endPoint: .trailing))
                    .shadow(color: Color.green.opacity(0.30), radius: 5, y: 2)
            )
        }
        .buttonStyle(PressAnimationStyle(cornerRadius: 8, flashColor: .white))
        .help("Okamžitě otevře závoru VJEZDU + uloží full-frame snímek. \(webhookStatusHint)")
    }

    /// Manuální OTEVŘÍT VÝJEZD — fire `.openShort` na druhý Shelly device.
    /// Zobrazené jen pokud `shellyVyjezdEnabled` v Settings.
    private var openVyjezdButton: some View {
        Button(action: openVyjezdManually) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.right.to.line")
                    .font(.system(size: 11, weight: .semibold))
                Text("VÝJEZD")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Color.cyan.opacity(0.95))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.cyan.opacity(0.10))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.cyan.opacity(0.40), lineWidth: 1))
            )
        }
        .buttonStyle(PressAnimationStyle(cornerRadius: 8, flashColor: .cyan))
        .help("Otevře výjezdovou závoru manuálně. Druhý Shelly device — konfigurace v Nastavení → Webhook.")
    }

    private func openVyjezdManually() {
        Task { @MainActor in
            await fireGateAction(.openShort, label: "Brána výjezd", camera: "vyjezd")
        }
    }

    /// Otevři pro autobus / dlouhé vozidlo — `.openExtended` pulse
    /// (default 20 s, settings v Webhook section).
    private var busButton: some View {
        Button(action: openBusManually) {
            HStack(spacing: 6) {
                Image(systemName: "bus.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("AUTOBUS")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text("\(Int(state.webhookPulseExtendedSec))s")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.orange.opacity(0.95))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.10))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.40), lineWidth: 1))
            )
        }
        .buttonStyle(PressAnimationStyle(cornerRadius: 8, flashColor: .orange))
        .help("Otevře závoru na delší dobu (\(Int(state.webhookPulseExtendedSec)) s) — pro autobus, dodávku, návěs.")
    }

    /// Drž závoru otevřenou — toggle. Při zapnutém holdu se beat task posílá
    /// `.openHoldBeat` každou 1 s; po stop posílá `.closeRelease`. Failsafe je
    /// Shelly `auto_off_delay` 60 s — pokud SPZ.app crashne, brána sama padne.
    private var holdButton: some View {
        Button(action: toggleHold) {
            HStack(spacing: 6) {
                Image(systemName: holdController.isHolding ? "hand.raised.fill" : "hand.raised")
                    .font(.system(size: 11, weight: .semibold))
                if holdController.isHolding, let started = holdController.holdStartedAt {
                    let elapsed = Int(holdTickerNow.timeIntervalSince(started))
                    Text("Drží (\(elapsed)s)")
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                } else {
                    Text("DRŽET")
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(holdController.isHolding ? Color.black : Color.yellow.opacity(0.95))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(
                Group {
                    if holdController.isHolding {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(LinearGradient(colors: [Color.yellow, Color.orange],
                                                 startPoint: .leading, endPoint: .trailing))
                            .shadow(color: Color.yellow.opacity(0.30), radius: 4, y: 2)
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.yellow.opacity(0.10))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.yellow.opacity(0.40), lineWidth: 1))
                    }
                }
            )
        }
        .buttonStyle(PressAnimationStyle(cornerRadius: 8, flashColor: .yellow))
        .help(holdController.isHolding
              ? "Závora se drží otevřená. Klikni znovu pro uvolnění."
              : "Drž závoru otevřenou — pro auto co stojí v záboru. Druhý klik uvolní.")
    }

    private var dailyPassButton: some View {
        Button(action: { showAddSheet = true }) {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 11, weight: .semibold))
                Text("DENNÍ VJEZD")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text("\(state.dailyPassExpiryHours) h")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.cyan.opacity(0.95))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.cyan.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.cyan.opacity(0.35), lineWidth: 1))
            )
        }
        .buttonStyle(PressAnimationStyle(cornerRadius: 8, flashColor: .cyan))
        .help("Přidá SPZ do whitelistu s automatickým vypršením po \(state.dailyPassExpiryHours) h (bez hesla).")
    }

    /// Dočasný vjezd s vlastním datem expirace — pro delší návštěvy (>24h),
    /// např. týdenní brigáda, stavební firma. User vybere konkrétní datum + čas
    /// expirace v rozsahu 1h–1rok. Po expiry se entry sám smaže z whitelistu.
    private var temporaryPassButton: some View {
        Button(action: { showTempSheet = true }) {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 11, weight: .semibold))
                Text("DOČASNÝ VJEZD")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Color.purple.opacity(0.95))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.purple.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.purple.opacity(0.35), lineWidth: 1))
            )
        }
        .buttonStyle(PressAnimationStyle(cornerRadius: 8, flashColor: .purple))
        .help("Přidá SPZ do whitelistu s vlastním datem expirace (např. týden / měsíc). Po vypršení se entry automaticky smaže.")
    }

    @ViewBuilder
    private var feedbackBadge: some View {
        if let feedback {
            HStack(spacing: 6) {
                Image(systemName: feedbackColor == .green ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(feedbackColor)
                Text(LocalizedStringKey(feedback))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(feedbackColor.opacity(0.95))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(
                Capsule().fill(feedbackColor.opacity(0.08))
                    .overlay(Capsule().stroke(feedbackColor.opacity(0.3), lineWidth: 1))
            )
            .transition(.opacity)
        }
    }

    private func openVjezdManually() {
        Task { @MainActor in
            await openVjezdManuallyAsync()
        }
    }

    private func openBusManually() {
        Task { @MainActor in
            await fireGateAction(.openExtended, label: "Brána autobus (\(Int(state.webhookPulseExtendedSec)) s)")
        }
    }

    private func toggleHold() {
        if holdController.isHolding {
            holdController.stop()
            state.markGateClosed(camera: "vjezd")
            showFeedback("Hold ukončen — řadič si zavře", color: .green)
        } else {
            guard state.shellyDevice(for: "vjezd").isUsable else {
                showFeedback("Hold vyžaduje Shelly base URL v Settings", color: .orange)
                return
            }
            holdController.start(state: state)
            showFeedback("Drží otevřeno (1 Hz beat)", color: .green)
            state.markGateOpened(camera: "vjezd",
                                  duration: state.bannerDuration(for: .openHoldStart, camera: "vjezd"))
            NotificationHelper.post(title: "Závora drží", body: "Hold-open mode aktivní")
        }
    }

    /// Sdílená cesta pro `.openShort` / `.openExtended` přes scenario routing.
    /// `camera` určuje, který Shelly device se použije — vjezd / výjezd. Auth
    /// (user/password) se vezme z per-camera AppState konfigurace.
    private func fireGateAction(_ action: GateAction, label: String,
                                 camera: String = "vjezd") async {
        let device = state.shellyDevice(for: camera)
        guard device.isUsable else {
            // No-relay: jen vizuální feedback (banner default 5 s).
            state.markGateOpened(camera: camera)
            showFeedback("\(label) — bez relé", color: .orange)
            return
        }
        let cfg = device.gateActionConfig()
        let t0 = Date()
        let result = await WebhookClient.shared.fireGateAction(
            action, baseURL: device.baseURL,
            user: device.user, password: device.password,
            plate: "MANUAL", camera: camera, config: cfg,
            eventId: "MANUAL-\(camera)-\(action.auditTag)-\(UUID().uuidString.prefix(8))",
            timeout: 2.0
        )
        let latencyMs = Int(Date().timeIntervalSince(t0) * 1000)
        state.recordShellyResult(result, camera: camera, latencyMs: latencyMs)
        guard case .success(let httpStatus) = result else {
            let humanMsg: String
            switch result {
            case .rejectedBySSRF: humanMsg = "URL relé blokována (SSRF)"
            case .rateLimited: humanMsg = "Příliš rychle za sebou — počkej 2 s"
            case .httpError(let s): humanMsg = "Relé HTTP \(s) (chyba)"
            case .networkError: humanMsg = "Síť: relé neodpovídá"
            case .redirectBlocked: humanMsg = "Relé pošle redirect (zablokováno)"
            default: humanMsg = "Relé neodpovědělo"
            }
            showFeedback("\(label) — \(humanMsg)", color: .red)
            shelly.refresh()
            return
        }
        // Banner duration sync s actual gate-open timerem (autobus = 20 s, short = 1 s).
        state.markGateOpened(camera: camera,
                              duration: state.bannerDuration(for: action, camera: camera))
        showFeedback("\(label) · HTTP \(httpStatus) · \(latencyMs) ms", color: .green)
        shelly.burstAfterFire()
        NotificationHelper.post(title: "Závora otevřena", body: label)
    }

    private func openVjezdManuallyAsync() async {
        // Per-camera Shelly device — vjezd. Pokud disabled / bez URL, no-relay.
        let device = state.shellyDevice(for: "vjezd")
        if device.isUsable {
            let cfg = device.gateActionConfig()
            let t0 = Date()
            let result = await WebhookClient.shared.fireGateAction(
                .openShort, baseURL: device.baseURL,
                user: device.user, password: device.password,
                plate: "MANUAL", camera: "vjezd", config: cfg,
                eventId: "MANUAL-openShort-\(UUID().uuidString.prefix(8))",
                timeout: 2.0
            )
            state.recordShellyResult(result, camera: "vjezd",
                                      latencyMs: Int(Date().timeIntervalSince(t0) * 1000))
            guard case .success = result else {
                switch result {
                case .rejectedBySSRF:
                    showFeedback("Webhook URL blokována", color: .red)
                case .rateLimited:
                    showFeedback("Počkej chvilku, relé je chráněné limitem", color: .orange)
                default:
                    showFeedback("Relé neodpovědělo, závora se neotevřela", color: .red)
                }
                shelly.refresh()  // ověř že relé je nedostupné (badge → 🔴)
                FileHandle.safeStderrWrite("[Manual] vjezd open failed: \(result)\n".data(using: .utf8)!)
                return
            }
            // Burst probe — 5× 1 Hz refresh aby probe zachytil
            // `output=true` během krátké pulse a vystřelil push event.
            // Bez tohoto by 60s background probe pulse celý minul.
            shelly.burstAfterFire()
        }

        // macOS notifikace — i když je app v pozadí, user dostane potvrzení.
        // Banner duration sync s actual gate-open timerem (`webhookPulseShortSec`).
        state.markGateOpened(camera: "vjezd",
                              duration: state.bannerDuration(for: .openShort, camera: "vjezd"))
        NotificationHelper.post(
            title: "Závora otevřena",
            body: "Manuální otevření VJEZDU"
        )

        // 2) Fullscreen snapshot z vjezd kamery → manual-prujezdy/
        let saved = saveManualVjezdSnapshot()

        lastFireTs = Date()
        if let saved {
            showFeedback("Brána otevřena + snímek uložen", color: .green)
            FileHandle.safeStderrWrite("[Manual] vjezd opened, snapshot=\(saved.lastPathComponent)\n".data(using: .utf8)!)
        } else {
            showFeedback("Brána otevřena (kamera neposkytla snímek)", color: .orange)
            FileHandle.safeStderrWrite("[Manual] vjezd opened, snapshot FAILED (no latest buffer)\n".data(using: .utf8)!)
        }
    }

    private func saveManualVjezdSnapshot() -> URL? {
        guard let svc = cameras.services["vjezd"], let pb = svc.snapshotLatest() else { return nil }
        let ci = CIImage(cvPixelBuffer: pb)
        guard let cg = SharedCIContext.shared.createCGImage(ci, from: ci.extent) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        return Store.shared.persistManualPass(cameraName: "vjezd", fullImage: img)
    }

    private func showFeedback(_ text: String, color: Color) {
        feedback = text
        feedbackColor = color
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if feedback == text { feedback = nil }
        }
    }
}
