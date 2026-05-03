import Foundation
import ServiceManagement

/// Registrace SPZ.app jako login item přes `SMAppService.mainApp`.
/// Vyžaduje macOS 13+ (target projektu macOS 15 → OK).
///
/// SMAppService registruje aktuální app bundle ze své lokace. Pokud je app
/// spuštěná z `/Applications/SPZ.app`, registrace přidá login item. Pokud
/// je spuštěná z `build/`, login item odkazuje tam → nefunguje po rebuildu.
enum AutostartManager {
    /// Vrátí true pokud je SPZ.app registrovaná jako login item.
    static func isEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Zapne / vypne autostart. Vrací user-facing hlášku o výsledku (CZ).
    @discardableResult
    static func setEnabled(_ on: Bool) -> String {
        do {
            if on {
                try SMAppService.mainApp.register()
                return "Zapnuto — SPZ.app se spustí při přihlášení."
            } else {
                try SMAppService.mainApp.unregister()
                return "Vypnuto — automatické spouštění zrušeno."
            }
        } catch {
            return "Chyba: \(error.localizedDescription). App musí být v /Applications."
        }
    }
}
