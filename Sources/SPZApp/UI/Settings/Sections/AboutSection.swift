import SwiftUI
import AppKit

/// AboutSection — extracted ze SettingsView.swift jako součást big-refactor split (krok #10).

struct AboutSection: View {
    @State private var autostartEnabled: Bool = AutostartManager.isEnabled()
    @State private var autostartFeedback: String? = nil
    /// Tick každých 5 s aby engine stats card refresh-oval bez restart UI.
    @State private var statsTick: Date = Date()

    var body: some View {
        EngineStatsCard()
            .onReceive(Timer.publish(every: 5.0, on: .main, in: .common).autoconnect()) { now in
                statsTick = now
            }
            .id(statsTick)  // force redraw každých 5s

        SettingsCard("SPZ · ALPR", icon: "video.fill", accent: .green) {
            Text("Native macOS app pro čtení SPZ z IP kamery.")
                .font(.system(size: 12))
            Text("Apple Vision OCR (Neural Engine) + native VideoToolbox RTSP decode.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Divider().background(Color.white.opacity(0.06))
            infoRow("Stack", "SwiftUI · Vision · VideoToolbox · CoreImage · SQLite")
            infoRow("Platform", "macOS 15+ Apple Silicon (ANE)")
            infoRow("Build", (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev")
        }

        SettingsCard("Soukromí a data", icon: "hand.raised.fill", accent: .teal.opacity(0.8)) {
            Text("Aplikace běží lokálně v LAN. Video se neposílá do cloudu; ukládají se jen detekce, audit logy a snapshoty průjezdů na tomto Macu.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().background(Color.white.opacity(0.06))
            infoRow("Ukládá", "SPZ · čas · kamera · snapshot · audit")
            infoRow("Přenos", "RTSP kamera · lokální Shelly/Webhook")
            infoRow("Ochrana", "lokální soubory 0600/0700")
        }

        SettingsCard("Spuštění při přihlášení", icon: "power", accent: .green.opacity(0.7)) {
            ToggleRow("Spustit automaticky při přihlášení",
                      hint: "Po přihlášení uživatele se SPZ.app sama spustí. Užitečné pokud appka běží non-stop jako ALPR brána. Vyžaduje aby byla v /Applications.",
                      isOn: Binding(
                        get: { autostartEnabled },
                        set: { newValue in
                            let result = AutostartManager.setEnabled(newValue)
                            autostartEnabled = AutostartManager.isEnabled()
                            autostartFeedback = result
                            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                                if autostartFeedback == result { autostartFeedback = nil }
                            }
                        }))
            if let msg = autostartFeedback {
                Text(LocalizedStringKey(msg))
                    .font(.system(size: 10))
                    .foregroundStyle(msg.hasPrefix("Chyba") ? Color.red : Color.green)
            }
        }

        SettingsCard("Soubory", icon: "folder.fill", accent: .gray.opacity(0.8)) {
            let base = Store.shared.snapshotsDir.deletingLastPathComponent()
            HStack {
                Text(base.path).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                Button("Otevřít") { NSWorkspace.shared.open(base) }
                    .buttonStyle(GhostButtonStyle())
            }
            HStack {
                Text("Log").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Button("Otevřít log") {
                    let url = base.appendingPathComponent("spz.log")
                    NSWorkspace.shared.open(url)
                }.buttonStyle(GhostButtonStyle())
            }
        }
    }

    fileprivate func infoRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k.uppercased()).font(.system(size: 9, weight: .bold)).tracking(1.2)
                .foregroundStyle(Color.white.opacity(0.45))
            Spacer()
            Text(v).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.85))
        }
    }
}

/// Live statistika sekundární engine vs Apple Vision OCR.
/// Per-session counters z `EngineStats.shared.snapshot()`. Refresh každých 5 s.
private struct EngineStatsCard: View {
    var body: some View {
        let s = EngineStats.shared.snapshot()
        let elapsed = Int(Date().timeIntervalSince(s.startedAt))
        let elapsedStr: String = {
            if elapsed < 60 { return "\(elapsed) s" }
            if elapsed < 3600 { return "\(elapsed/60) m" }
            return "\(elapsed/3600) h \((elapsed%3600)/60) m"
        }()

        SettingsCard("Sekundární engine vs Apple Vision",
                     icon: "chart.bar.xaxis",
                     accent: .blue.opacity(0.8)) {
            row("Vision celkem (všechny readings)",
                value: "\(s.visionTotal)",
                hint: "Kolikrát Vision detekoval text v posledních \(elapsedStr).")
            row("Pod 5 znaků (junk filter)",
                value: "\(s.secondarySkipped)",
                pct: pct(s.secondarySkipped, s.visionTotal),
                color: .gray,
                hint: "1-4 char fragmenty (světlomety, čísla domů). Sekundární engine je dostane skip-nutý.")
            row("Posláno do sekundárního",
                value: "\(s.secondaryCalled)",
                pct: pct(s.secondaryCalled, s.visionTotal),
                color: .blue,
                hint: "Plate-like text (≥ 5 chars) → ONNX FastPlateOCR cross-check.")
            Divider().background(Color.white.opacity(0.06))
            row("✓ Oba shoda (cross-validated)",
                value: "\(s.bothAgreed)",
                pct: pct(s.bothAgreed, s.secondaryCalled),
                color: .green,
                hint: "Oba engines vrátily identický text — cross-validated boost (2× váha v trackeru).")
            row("≈ L-1 fuzzy shoda",
                value: "\(s.l1Agreed)",
                pct: pct(s.l1Agreed, s.secondaryCalled),
                color: .yellow,
                hint: "Liší se v jednom znaku (typicky O/0, B/8). Sekundární confirms s nižší jistotou.")
            row("≠ Neshoda",
                value: "\(s.disagreed)",
                pct: pct(s.disagreed, s.secondaryCalled),
                color: .orange,
                hint: "Engines vrátily zcela jiný text. Vision wins (default), ale audit ukáže pár pro review.")
            row("∅ Sekundární prázdný",
                value: "\(s.secondaryEmpty)",
                pct: pct(s.secondaryEmpty, s.secondaryCalled),
                color: .gray,
                hint: "Sekundární engine nedokázal nic přečíst — Vision wins.")
            Divider().background(Color.white.opacity(0.06))
            HStack {
                Text("BĚŽÍ").font(.system(size: 9, weight: .bold)).tracking(1.2)
                    .foregroundStyle(Color.white.opacity(0.45))
                Spacer()
                Text(elapsedStr).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.85))
            }
            HStack {
                Spacer()
                Button("Vynulovat") { EngineStats.shared.reset() }
                    .buttonStyle(GhostButtonStyle())
            }
        }
    }

    private func pct(_ num: Int, _ den: Int) -> String? {
        guard den > 0 else { return nil }
        return String(format: "%.1f %%", Double(num) * 100.0 / Double(den))
    }

    @ViewBuilder
    private func row(_ label: String, value: String,
                     pct: String? = nil, color: Color = .white,
                     hint: String? = nil) -> some View {
        HStack {
            Text(LocalizedStringKey(label)).font(.system(size: 11))
                .foregroundStyle(color.opacity(0.95))
            if let h = hint {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .help(h)
            }
            Spacer()
            HStack(spacing: 6) {
                Text(value)
                    .font(.system(size: 12, weight: .heavy, design: .monospaced))
                    .foregroundStyle(color)
                if let p = pct {
                    Text(LocalizedStringKey(p))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(color.opacity(0.7))
                }
            }
        }
    }
}
