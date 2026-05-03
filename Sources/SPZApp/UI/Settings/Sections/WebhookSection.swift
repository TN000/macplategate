import SwiftUI
import AppKit

/// WebhookSection — extracted ze SettingsView.swift jako součást big-refactor split (krok #10).

struct WebhookSection: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var hook = WebhookClient.shared
    @State private var testInFlight: Bool = false
    @State private var testResult: (ok: Bool, message: String, ts: Date)? = nil
    @State private var hideTestResultTask: Task<Void, Never>? = nil
    @State private var showVjezdPassword: Bool = false
    @State private var showVyjezdPassword: Bool = false

    var body: some View {
        // Vjezd Shelly device
        shellyDeviceCard(
            title: "Shelly — vjezd",
            accent: Color.green,
            enabledBinding: $state.shellyVjezdEnabled,
            urlBinding: $state.webhookShellyBaseURL,
            userBinding: $state.shellyVjezdUser,
            passwordBinding: $state.shellyVjezdPassword,
            pulseShortBinding: Binding(get: { Int(state.webhookPulseShortSec) },
                                        set: { state.webhookPulseShortSec = Double($0) }),
            pulseExtendedBinding: Binding(get: { Int(state.webhookPulseExtendedSec) },
                                           set: { state.webhookPulseExtendedSec = Double($0) }),
            holdBeatBinding: Binding(get: { Int(state.webhookKeepAliveBeatSec) },
                                      set: { state.webhookKeepAliveBeatSec = Double($0) }),
            showPasswordBinding: $showVjezdPassword,
            includeHoldControls: true,
            cameraName: "vjezd"
        )

        // Vyjezd Shelly device
        shellyDeviceCard(
            title: "Shelly — výjezd",
            accent: Color.cyan,
            enabledBinding: $state.shellyVyjezdEnabled,
            urlBinding: $state.shellyVyjezdBaseURL,
            userBinding: $state.shellyVyjezdUser,
            passwordBinding: $state.shellyVyjezdPassword,
            pulseShortBinding: Binding(get: { Int(state.shellyVyjezdPulseShortSec) },
                                        set: { state.shellyVyjezdPulseShortSec = Double($0) }),
            pulseExtendedBinding: Binding(get: { Int(state.shellyVyjezdPulseExtendedSec) },
                                           set: { state.shellyVyjezdPulseExtendedSec = Double($0) }),
            holdBeatBinding: Binding(get: { Int(state.shellyVyjezdKeepAliveBeatSec) },
                                      set: { state.shellyVyjezdKeepAliveBeatSec = Double($0) }),
            showPasswordBinding: $showVyjezdPassword,
            includeHoldControls: false,
            cameraName: "vyjezd"
        )

        SettingsCard("Příkaz pro otevření závory (legacy)", icon: "link", accent: .blue.opacity(0.8)) {
            VStack(alignment: .leading, spacing: 6) {
                Text("URL (legacy, používá se jen když Base URL výše prázdný)").font(.system(size: 9, weight: .bold)).tracking(1.2)
                    .foregroundStyle(Color.white.opacity(0.45))
                TextField("http://shelly.local/rpc/Switch.Set?id=0&on=true&toggle_after=1",
                          text: $state.webhookURL)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.06))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1)))
            }
            Text("Pro Shelly Pro 1 (gate-opener) typicky:\nhttp://IP/rpc/Switch.Set?id=0&on=true&toggle_after=1")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.green.opacity(0.8))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Divider().background(Color.white.opacity(0.06))
            ToggleRow("Pouze pro známé SPZ",
                      hint: "Když zapnuto, otevře závoru POUZE autům ze seznamu známých SPZ. Když vypnuto, otevře každému autu (včetně neznámých) — nedoporučeno pro ostrý provoz.",
                      isOn: $state.webhookOnlyForKnown)
            Divider().background(Color.white.opacity(0.06))
            StepperRow("Počet opakovaných pokusů",
                       hint: "Pokud se nepodaří odeslat příkaz na závoru napoprvé (např. relé zrovna neodpovídá), kolikrát to zkusit znovu. 0 = zkusí jen jednou.",
                       value: $state.webhookRetryCount, range: 0...10, step: 1) {
                $0 == 0 ? "bez opakování" : "\($0)×"
            }
            StepperRow("Časový limit na odpověď",
                       hint: "Jak dlouho čekat na odpověď od relé, než pokus považovat za neúspěšný. 2000 ms = 2 sekundy. Pokud máš pomalou síť, zvyš.",
                       value: $state.webhookTimeoutMs, range: 500...10000, step: 500) {
                "\($0) ms"
            }

            HStack(spacing: 10) {
                Button(action: runTestFire) {
                    HStack(spacing: 6) {
                        if testInFlight {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.black)
                        } else {
                            Image(systemName: "paperplane.fill").font(.system(size: 11))
                        }
                        Text(testInFlight ? "Odesílám…" : "Test — odeslat příkaz")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(state.webhookURL.isEmpty || testInFlight)
                if let res = testResult {
                    HStack(spacing: 6) {
                        Image(systemName: res.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(res.ok ? Color.green : Color.orange)
                        Text(res.message)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(res.ok ? Color.green : Color.orange)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill((res.ok ? Color.green : Color.orange).opacity(0.10))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .stroke((res.ok ? Color.green : Color.orange).opacity(0.35), lineWidth: 1)))
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }
                Spacer()
            }
            .animation(.easeInOut(duration: 0.18), value: testInFlight)
            .animation(.easeInOut(duration: 0.25), value: testResult?.ts)
        }

        // Test result auto-hide after 6 sec (cancellable on next click).
        // Color.clear je víc spolehlivé než EmptyView — SwiftUI EmptyView mohlo
        // být optimalizováno z view tree, pak by .onDisappear nikdy nestřelil.
        Color.clear.frame(width: 0, height: 0)
            .onDisappear {
                hideTestResultTask?.cancel()
                hideTestResultTask = nil
                // Reset state aby se příštím otevřením Settings nezobrazoval
                // starý chip / locked button po hangnutém požadavku.
                testInFlight = false
                testResult = nil
            }
        if let last = hook.lastFired {
            SettingsCard("Poslední odeslaný příkaz", icon: "clock.fill", accent: .gray.opacity(0.7)) {
                HStack {
                    Text("SPZ").font(.system(size: 9, weight: .bold)).tracking(1.2)
                        .foregroundStyle(Color.white.opacity(0.45))
                    Spacer()
                    Text(last.plate).font(.system(size: 12, design: .monospaced))
                }
                HStack {
                    Text("STATUS").font(.system(size: 9, weight: .bold)).tracking(1.2)
                        .foregroundStyle(Color.white.opacity(0.45))
                    Spacer()
                    Text("\(last.status)").font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(last.status == 200 ? Color.green : Color.orange)
                }
                HStack {
                    Text("ČAS").font(.system(size: 9, weight: .bold)).tracking(1.2)
                        .foregroundStyle(Color.white.opacity(0.45))
                    Spacer()
                    Text(last.ts.formatted(.dateTime))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.85))
                }
                Text(last.url).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    /// Async fire-once s plnou UI feedback smyčkou: spinner během letu, inline
    /// success/error chip po doletu, auto-hide po 6 s.
    /// **Hard timeout safety**: pokud `fireOnce` nikdy nereturnne (DNS hang nad
    /// rámec URLSession timeoutu, semafor stuck v networkError chain), chrání
    /// nás `Task.race` s našim vlastním sleep + fallback message. Bez něj by
    /// `testInFlight=true` zamknul tlačítko napořád.
    private func runTestFire() {
        guard !state.webhookURL.isEmpty, !testInFlight else { return }
        hideTestResultTask?.cancel()
        testInFlight = true
        testResult = nil
        let url = state.webhookURL
        let timeoutSec = max(0.5, Double(state.webhookTimeoutMs) / 1000.0)
        // Hard ceiling = max(timeout × 2, 8 s) — kompatibilní s SSRF DNS resolve
        // (může trvat 5 s) a malou rezervou na URLSession setup.
        let hardCeilingSec = max(timeoutSec * 2.0, 8.0)
        Task { @MainActor in
            let resultBox: ActorIsolated<WebhookResult?> = .init(nil)
            let fireTask = Task<WebhookResult, Never> {
                await WebhookClient.shared.fireOnce(
                    url: url, plate: "TEST", camera: "manual",
                    eventId: "TEST-\(UUID().uuidString)",
                    timeout: timeoutSec)
            }
            let timeoutTask = Task<Void, Never> {
                try? await Task.sleep(nanoseconds: UInt64(hardCeilingSec * 1_000_000_000))
            }
            // Závod: kdo dorazí dřív, vyhraje. Jakmile máme výsledek, druhý
            // úkol cancelujeme.
            await withTaskGroup(of: WebhookResult?.self) { group in
                group.addTask { await fireTask.value }
                group.addTask {
                    await timeoutTask.value
                    return nil       // nil = timeout fired first
                }
                if let first = await group.next() {
                    await resultBox.set(first)
                    group.cancelAll()
                    fireTask.cancel()
                    timeoutTask.cancel()
                }
            }
            testInFlight = false
            switch await resultBox.get() {
            case .some(.success(let httpStatus)):
                testResult = (true, "OK · HTTP \(httpStatus)", Date())
            case .some(.httpError(let status)):
                testResult = (false, "HTTP \(status) — relé odpovědělo chybou", Date())
            case .some(.networkError(let desc)):
                testResult = (false, "Selhání: \(desc)", Date())
            case .some(.rejectedBySSRF(let reason)):
                testResult = (false, "URL zablokována: \(reason)", Date())
            case .some(.rateLimited):
                testResult = (false, "Rate limited (čekej 2 s)", Date())
            case .some(.redirectBlocked(let loc)):
                testResult = (false, "Redirect blokovaný → \(loc)", Date())
            case nil:
                testResult = (false, "Timeout (\(Int(hardCeilingSec)) s) — žádná odpověď", Date())
            }
            self.hideTestResultTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if !Task.isCancelled { testResult = nil }
            }
        }
    }

    /// Per-camera Shelly device card — URL, auth, pulse durations, test buttons.
    /// Vjezd a výjezd používají stejný builder, jen liší binding-y a accent.
    @ViewBuilder
    private func shellyDeviceCard(
        title: String,
        accent: Color,
        enabledBinding: Binding<Bool>,
        urlBinding: Binding<String>,
        userBinding: Binding<String>,
        passwordBinding: Binding<String>,
        pulseShortBinding: Binding<Int>,
        pulseExtendedBinding: Binding<Int>,
        holdBeatBinding: Binding<Int>,
        showPasswordBinding: Binding<Bool>,
        includeHoldControls: Bool,
        cameraName: String
    ) -> some View {
        SettingsCard(title, icon: "antenna.radiowaves.left.and.right",
                     accent: accent.opacity(0.8)) {
            ToggleRow("Aktivní",
                      hint: "Když vypnuto, SPZ tomuto Shelly zařízení neposílá žádné příkazy. ALPR auto-fire na této kameře a webové UI tlačítka jsou ignorovány.",
                      isOn: enabledBinding)
            Divider().background(Color.white.opacity(0.06))

            VStack(alignment: .leading, spacing: 6) {
                Text("BASE URL").font(.system(size: 9, weight: .bold)).tracking(1.2)
                    .foregroundStyle(Color.white.opacity(0.45))
                TextField("http://192.168.x.x", text: urlBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.06))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1)))
                    .disabled(!enabledBinding.wrappedValue)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("UŽIVATEL").font(.system(size: 9, weight: .bold)).tracking(1.2)
                    .foregroundStyle(Color.white.opacity(0.45))
                TextField("admin", text: userBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.06))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1)))
                    .disabled(!enabledBinding.wrappedValue)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("HESLO").font(.system(size: 9, weight: .bold)).tracking(1.2)
                        .foregroundStyle(Color.white.opacity(0.45))
                    Spacer()
                    Button(action: { showPasswordBinding.wrappedValue.toggle() }) {
                        Image(systemName: showPasswordBinding.wrappedValue ? "eye.slash" : "eye")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                }
                Group {
                    if showPasswordBinding.wrappedValue {
                        TextField("ponecháno prázdné = bez auth", text: passwordBinding)
                    } else {
                        SecureField("ponecháno prázdné = bez auth", text: passwordBinding)
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.06))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1)))
                .disabled(!enabledBinding.wrappedValue)
                Text("Shelly Pro 1 (gen 2 firmware) používá Digest auth. URLSession kredence injektne přes URL userinfo a odpoví na 401 challenge automaticky.")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().background(Color.white.opacity(0.06))

            StepperRow("Krátký pulse (otevři)",
                       hint: "Délka pulsu pro standardní průjezd. Shelly toggle_after parameter, AGN2/AGN3 řadič si pak zavře sám.",
                       value: pulseShortBinding, range: 1...30, step: 1) { "\($0) s" }
            StepperRow("Dlouhý pulse (autobus)",
                       hint: "Pulse pro velká vozidla — drží relé sepnuté po celou dobu. Doporučeno 15–30 s.",
                       value: pulseExtendedBinding, range: 5...120, step: 5) { "\($0) s" }
            if includeHoldControls {
                StepperRow("Hold beat (re-trigger)",
                           hint: "V hold-open režimu SPZ posílá `toggle_after=N` každou 1 s. N musí být ≥ 3 (3× redundance per cycle).",
                           value: holdBeatBinding, range: 3...10, step: 1) { "\($0) s" }
            }

            HStack(spacing: 8) {
                Button("Test krátké") {
                    runDeviceScenarioTest(.openShort, camera: cameraName)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(urlBinding.wrappedValue.isEmpty || !enabledBinding.wrappedValue || testInFlight)
                Button("Test autobus") {
                    runDeviceScenarioTest(.openExtended, camera: cameraName)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(urlBinding.wrappedValue.isEmpty || !enabledBinding.wrappedValue || testInFlight)
                if includeHoldControls {
                    Button("Hold 5s") { runHoldTest() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(urlBinding.wrappedValue.isEmpty || !enabledBinding.wrappedValue || testInFlight)
                }
                Spacer()
                if let res = testResult {
                    HStack(spacing: 6) {
                        Image(systemName: res.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(res.ok ? Color.green : Color.orange)
                        Text(res.message)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(res.ok ? Color.green : Color.orange)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    /// Test fire pro per-camera device — vezme aktuální AppState device snapshot.
    private func runDeviceScenarioTest(_ action: GateAction, camera: String) {
        guard !testInFlight else { return }
        let device = state.shellyDevice(for: camera)
        guard !device.baseURL.isEmpty else { return }
        hideTestResultTask?.cancel()
        testInFlight = true
        testResult = nil
        let cfg = device.gateActionConfig()
        Task { @MainActor in
            let result = await WebhookClient.shared.fireGateAction(
                action, baseURL: device.baseURL,
                user: device.user, password: device.password,
                plate: "TEST", camera: camera, config: cfg,
                eventId: "TEST-\(camera)-\(action.auditTag)-\(UUID().uuidString.prefix(8))",
                timeout: max(0.5, Double(state.webhookTimeoutMs) / 1000.0)
            )
            testInFlight = false
            switch result {
            case .success(let s):
                testResult = (true, "OK · HTTP \(s) · \(camera)/\(action.auditTag)", Date())
            case .httpError(let s):
                testResult = (false, "HTTP \(s) — \(camera)/\(action.auditTag)", Date())
            case .networkError(let d):
                testResult = (false, "Selhání: \(d)", Date())
            case .rejectedBySSRF(let r):
                testResult = (false, "URL blokována: \(r)", Date())
            case .rateLimited:
                testResult = (false, "Rate limited (počkej 2 s)", Date())
            case .redirectBlocked(let l):
                testResult = (false, "Redirect blokovaný → \(l)", Date())
            }
            self.hideTestResultTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if !Task.isCancelled { testResult = nil }
            }
        }
    }

    /// Hold 5 s test — jen vjezd device (GateHoldController vázaný na vjezd).
    private func runHoldTest() {
        guard state.shellyDevice(for: "vjezd").isUsable, !testInFlight else { return }
        hideTestResultTask?.cancel()
        testInFlight = true
        testResult = nil
        Task { @MainActor in
            GateHoldController.shared.start(state: state)
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            GateHoldController.shared.stop()
            testInFlight = false
            testResult = (true, "Hold 5 s OK · release sent", Date())
            self.hideTestResultTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if !Task.isCancelled { testResult = nil }
            }
        }
    }
}

/// Pomocný actor pro safe sdílení mezi child Task-y v TaskGroup.
private actor ActorIsolated<T> {
    private var value: T
    init(_ initial: T) { self.value = initial }
    func get() -> T { value }
    func set(_ new: T) { self.value = new }
}

// MARK: - Storage
