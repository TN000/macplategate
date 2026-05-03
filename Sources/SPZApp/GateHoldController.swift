import Foundation
import SwiftUI

/// Drží Shelly relé sepnuté po dobu, kdy auto stojí před závorou
/// ("ridič se zakecal"). Implementace = `.openHoldStart` jako iniciální fire,
/// pak periodicky 1 Hz `.openHoldBeat` (re-trigger Shelly toggle_after) dokud
/// admin neukončí přes `stop()`.
///
/// **Failsafe:** kdyby SPZ.app crashla mezi beat-y, Shelly Pro 1 musí mít
/// nakonfigurovaný `auto_off=true, auto_off_delay=60` v `Switch.SetConfig`.
/// Tím se relé samo vypne za max 60 s a brána padne. Toto SPZ.app sama
/// nenastavuje — admin nastavuje jednorázově ve web UI Shelly.
@MainActor
final class GateHoldController: ObservableObject {
    static let shared = GateHoldController()

    @Published private(set) var isHolding: Bool = false
    @Published private(set) var holdStartedAt: Date? = nil
    /// Poslední fire výsledek — UI zobrazí varování pokud relé neodpovídá.
    @Published private(set) var lastResult: WebhookResult? = nil

    private var beatTask: Task<Void, Never>?
    private weak var state: AppState?
    /// Cache z posledního `start()` — `stop()` ji použije pro `.closeRelease`
    /// fire i kdyby `state` reference byla nil (např. release přes WebUI bez
    /// předchozího hold start v té samé instanci).
    private var lastBaseURL: String = ""
    private var lastConfig: GateActionConfig = .defaults

    /// Začne držet bránu otevřenou. Pokud už drží, no-op.
    /// Initial fire je `.openHoldStart` (Shelly on=true bez toggle_after);
    /// následně beat task posílá `.openHoldBeat` každých `beatIntervalSec`.
    func start(state: AppState, beatIntervalSec: TimeInterval = 1.0) {
        guard !isHolding else { return }
        self.state = state
        isHolding = true
        holdStartedAt = Date()
        beatTask?.cancel()
        let cfg = state.gateActionConfigSnapshot()
        let baseURL = state.gateBaseURL
        lastBaseURL = baseURL
        lastConfig = cfg
        beatTask = Task { [weak self] in
            // 1) initial fire
            await self?.fire(action: .openHoldStart, baseURL: baseURL, config: cfg)
            // 2) beat loop (1 Hz default)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(beatIntervalSec))
                if Task.isCancelled { return }
                guard let self else { return }
                let cfg2 = await MainActor.run { self.state?.gateActionConfigSnapshot() ?? .defaults }
                let base2 = await MainActor.run { self.state?.gateBaseURL ?? "" }
                await self.fire(action: .openHoldBeat, baseURL: base2, config: cfg2)
            }
        }
    }

    /// Ukončí hold — pošle `.closeRelease` (Shelly off) a zruší beat task.
    /// AGN2/AGN3 řadič pak začne svůj interní TCA timer a brána zavře sama.
    /// Funguje i když `start()` nebyl volán v této instanci — použije
    /// `lastBaseURL` cache nebo aktuální `state.gateBaseURL` jako fallback.
    func stop() {
        beatTask?.cancel()
        beatTask = nil
        isHolding = false
        holdStartedAt = nil
        let baseURL = !lastBaseURL.isEmpty ? lastBaseURL : (state?.gateBaseURL ?? "")
        let cfg = !lastBaseURL.isEmpty ? lastConfig : (state?.gateActionConfigSnapshot() ?? .defaults)
        guard !baseURL.isEmpty else { return }
        Task { [weak self] in
            await self?.fire(action: .closeRelease, baseURL: baseURL, config: cfg)
        }
    }

    private func fire(action: GateAction, baseURL: String, config: GateActionConfig) async {
        guard !baseURL.isEmpty else { return }  // no-relay mode
        let result = await WebhookClient.shared.fireGateAction(
            action,
            baseURL: baseURL,
            plate: "MANUAL-HOLD",
            camera: "vjezd",
            config: config,
            eventId: "HOLD-\(action.auditTag)-\(UUID().uuidString.prefix(8))"
        )
        await MainActor.run { self.lastResult = result }
    }
}
