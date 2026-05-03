import Foundation
import SwiftUI

/// Periodicky pingne Shelly (`Switch.GetStatus`) a publikuje user-friendly
/// reachability + latency + relé output stav. UI (ManualControlBar) na něj
/// observuje a kreslí badge `🟢 Shelly · 47 ms · 27 °C` / `🔴 nedostupný`.
///
/// **Cíl:** user vidí stav relé bez nutnosti klikat tlačítko. Pokud Shelly
/// vypadne (síťový kabel, výpadek napájení), red badge se objeví do 10 s.
@MainActor
final class ShellyHealthProbe: ObservableObject {
    static let shared = ShellyHealthProbe()

    enum Status: Equatable {
        case idle              // base URL prázdná → no-relay setup
        case ok                // 2xx response within timeout
        case slow              // 2xx ale > 500 ms (síť přetížená?)
        case unreachable       // network error / timeout
        case http(Int)         // non-2xx HTTP odpověď (Shelly restart, auth?)

        var emoji: String {
            switch self {
            case .idle: return "·"
            case .ok: return "🟢"
            case .slow: return "🟡"
            case .unreachable: return "🔴"
            case .http: return "🟠"
            }
        }
        var label: String {
            switch self {
            case .idle: return "Bez relé"
            case .ok: return "Shelly OK"
            case .slow: return "Shelly pomalý"
            case .unreachable: return "Shelly nedostupný"
            case .http(let s): return "Shelly HTTP \(s)"
            }
        }
    }

    @Published private(set) var status: Status = .idle
    /// Poslední úspěšná latence v ms. nil = nikdy úspěšně neresponde.
    @Published private(set) var lastLatencyMs: Int? = nil
    /// Aktuální výstup relé (true = sepnuto = brána se otevírá / drží otevřená).
    @Published private(set) var relayOutput: Bool = false
    /// Aktuální teplota relé v °C. Indikuje že kontakt sepíná (pak teplo stoupá).
    @Published private(set) var relayTempC: Double? = nil
    /// Sekundy do auto-vypnutí (Shelly toggle_after timer). nil = žádný timer.
    @Published private(set) var pulseRemainingSec: Double? = nil
    /// Poslední úspěšný probe — UI zobrazí "naposledy před 12 s".
    @Published private(set) var lastProbeAt: Date? = nil
    /// Poslední state transition (relayOutput false→true nebo true→false).
    /// UI v ManualControlBar ukáže lidskou hlášku
    /// "Shelly: relé sepnulo přes HTTP_in · před 8 s".
    /// Není to push (Shelly to neposílá samo), ale derived z probe transition.
    @Published private(set) var lastStateChange: PushEvent? = nil
    /// Kolik po sobě jdoucích probes bylo nad slow threshold. Slow status
    /// publikujeme až po 2 po sobě jdoucích — single spike (cold TCP, App Nap
    /// throttle) nedělá UI false alarm.
    private var consecutiveSlowCount: Int = 0
    /// Slow threshold (ms). Reálný LAN RTT na Shelly je 0.5–1 ms, HTTP RPC
    /// 40–50 ms. 1500 ms je velmi tolerantní — flag se objeví jen pokud
    /// device skutečně visí (firmware update, disk write, RAM pressure).
    private static let slowThresholdMs: Int = 1500

    /// Push-style event derivovaný ze state transition.
    /// `kind`: "switch.on" / "switch.off"
    /// `source`: kdo to vyvolal — "HTTP_in" (náš webhook), "timer" (toggle_after expire),
    ///           "input" (fyzické tlačítko), "init" (po power-on).
    struct PushEvent: Equatable {
        let kind: String
        let source: String
        let at: Date
    }

    private var probeTask: Task<Void, Never>?
    private weak var state: AppState?
    private var lastSeenOutput: Bool = false

    /// Bind na AppState a spustí periodic probe loop. Voláno z `bind` v UI nebo
    /// při startu app. Pokud je base URL prázdná, status zůstane `.idle`.
    /// Default interval 60 s — teplota relé se nemění rychle, status změny
    /// catchneme přes manual `refresh()` po každém fire.
    func start(state: AppState, intervalSec: TimeInterval = 60.0) {
        self.state = state
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.probeOnce()
                try? await Task.sleep(for: .seconds(intervalSec))
            }
        }
    }

    /// Burst probe — po každém fire spustí 5× 1Hz refresh aby zachytil
    /// `output=true` během krátké pulse. Pak fallback na background interval.
    /// Voláno z UI cestou (Otevřít/Autobus) a po success WebUI / ALPR commit.
    func burstAfterFire() {
        Task { [weak self] in
            for _ in 0..<5 {
                await self?.probeOnce()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Force-refresh — užitečné po manuálním fire (user klikl "Otevřít",
    /// chceme okamžitě vidět output=true a pak po 1s output=false).
    func refresh() {
        Task { [weak self] in await self?.probeOnce() }
    }

    private func probeOnce() async {
        guard let state else { status = .idle; return }
        let device = state.shellyDevice(for: "vjezd")
        guard !device.baseURL.isEmpty else {
            status = .idle
            return
        }
        // Build URL — `Switch.GetStatus?id=0`. Direct URL build je jednodušší
        // protože GetStatus není v GateAction enumu.
        var base = device.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") { base.removeLast() }
        if let url = URL(string: base), (url.path.isEmpty || url.path == "/") {
            base += "/rpc/Switch.GetStatus"
        } else if base.contains("/rpc/Switch.Set") {
            base = base.replacingOccurrences(of: "/rpc/Switch.Set", with: "/rpc/Switch.GetStatus")
        }
        if let qIdx = base.firstIndex(of: "?") { base = String(base[..<qIdx]) }
        let urlString = base + "?id=0"
        guard let url = URL(string: urlString) else { return }

        let started = Date()
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                             timeoutInterval: 2.0)
        req.setValue("SPZ/1.0 (probe)", forHTTPHeaderField: "User-Agent")
        do {
            var (data, response): (Data, URLResponse) = try await URLSession.shared.data(for: req)
            var httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
            // **Digest auth retry** — stejný pattern jako WebhookClient.fireInternal.
            // URLSession na macOS Digest challenge nezavolá callback, manuální
            // RFC 7616 výpočet + retry s `Authorization: Digest ...` headerem.
            if httpStatus == 401, !device.user.isEmpty,
               let httpResp = response as? HTTPURLResponse,
               let www = (httpResp.value(forHTTPHeaderField: "WWW-Authenticate")
                         ?? httpResp.value(forHTTPHeaderField: "Www-Authenticate")),
               let challenge = WebhookDigestAuth.parseChallenge(www) {
                let pathAndQuery: String = {
                    var p = url.path
                    if p.isEmpty { p = "/" }
                    if let q = url.query, !q.isEmpty { p += "?\(q)" }
                    return p
                }()
                let authValue = WebhookDigestAuth.authorizationHeader(
                    challenge: challenge, method: "GET", uri: pathAndQuery,
                    user: device.user, password: device.password)
                var authReq = req
                authReq.setValue(authValue, forHTTPHeaderField: "Authorization")
                let (data2, resp2) = try await URLSession.shared.data(for: authReq)
                data = data2
                response = resp2
                httpStatus = (resp2 as? HTTPURLResponse)?.statusCode ?? -1
            }
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            if (200..<300).contains(httpStatus) {
                lastLatencyMs = elapsed
                lastProbeAt = Date()
                // Debounced slow detection — single spike (cold TCP / App Nap
                // throttle) nesmí flag-ovat. Threshold 1500 ms je tolerantní
                // k macOS background scheduling jitter.
                if elapsed > Self.slowThresholdMs {
                    consecutiveSlowCount += 1
                    status = consecutiveSlowCount >= 2 ? .slow : .ok
                } else {
                    consecutiveSlowCount = 0
                    status = .ok
                }
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let newOutput = (json["output"] as? Bool) ?? false
                    let source = (json["source"] as? String) ?? "?"
                    // State transition detection — pokud se output změnil
                    // od posledního probe, vystřel "push event" záznam.
                    // To je derived push (nejde z opravdové Shelly Webhook
                    // subscription), ale UI se chová stejně.
                    if newOutput != lastSeenOutput {
                        let kind = newOutput ? "switch.on" : "switch.off"
                        lastStateChange = PushEvent(kind: kind, source: source, at: Date())
                        lastSeenOutput = newOutput
                    }
                    relayOutput = newOutput
                    if let temp = (json["temperature"] as? [String: Any])?["tC"] as? Double {
                        relayTempC = temp
                    }
                    if let timerStarted = json["timer_started_at"] as? Double,
                       let timerDur = json["timer_duration"] as? Double {
                        let remaining = (timerStarted + timerDur) - Date().timeIntervalSince1970
                        pulseRemainingSec = remaining > 0 ? remaining : nil
                    } else {
                        pulseRemainingSec = nil
                    }
                }
            } else {
                status = .http(httpStatus)
            }
        } catch {
            status = .unreachable
        }
    }
}
