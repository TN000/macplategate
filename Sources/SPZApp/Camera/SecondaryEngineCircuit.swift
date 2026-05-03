import Foundation

/// Per-pipeline circuit breaker pro sekundární OCR engine. Per-instance (ne global)
/// aby vjezd timeout neblokoval vyjezd — failure isolation se shoduje s pipeline
/// ownership.
///
/// **Single-flight gate** (`tryBegin`) zabezpečuje, že max 1 ORT inference běží
/// per pipeline current. ORT session není thread-safe pro souběžné `run` calls
/// na stejnou session.
///
/// **Trip pattern:** při timeout / repetitivní fail volá `trip(seconds:)` —
/// circuit zůstane `disabled` po N sekund, žádné nové `tryBegin` nepustí.
/// Po expiraci automatický recovery (next `tryBegin` testuje `now >= disabledUntil`).
///
/// Engine reference je shared `static let` v PlatePipeline (jeden ORT session
/// per process, žádný benefit z duplikace). Circuit state je per-instance.
final class SecondaryEngineCircuit: @unchecked Sendable {
    let engine: PlateRecognitionEngine?
    private let lock = NSLock()
    private var disabledUntil: Date = .distantPast
    private var inFlight: Bool = false

    init(engine: PlateRecognitionEngine?) {
        self.engine = engine
    }

    /// Vrací true pokud nejsme v disable window. Read-only, neclaimuje slot.
    /// Test-friendly přes `now` injection.
    func allowsRun(now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return now >= disabledUntil
    }

    /// Atomicky claimuje single-flight slot — vrací true pokud nikdo další právě
    /// neběží AND circuit není v disable window. Volající MUSÍ párovat s `finish()`.
    func tryBegin(now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard now >= disabledUntil, !inFlight else { return false }
        inFlight = true
        return true
    }

    /// Uvolní single-flight slot. Volá se přes `defer` po `tryBegin() == true`.
    func finish() {
        lock.lock(); defer { lock.unlock() }
        inFlight = false
    }

    /// Disable circuit na N sekund (typicky 300 = 5 min při timeout). Engine sám
    /// se neukončuje — jen pipeline ho přestane volat dokud disable nevyprší.
    /// `Audit.event` emituje `engine_disabled` s diagnostikou pro post-mortem.
    func trip(seconds: TimeInterval, reason: String, camera: String, now: Date = Date()) {
        lock.lock()
        disabledUntil = now.addingTimeInterval(seconds)
        lock.unlock()
        Audit.event("engine_disabled", [
            "engine": engine?.name ?? "secondary",
            "camera": camera,
            "seconds": Int(seconds),
            "reason": reason
        ])
    }

    #if DEBUG
    /// Test helper: read-only snapshot pro assertions.
    var debugSnapshot: (disabledUntil: Date, inFlight: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (disabledUntil, inFlight)
    }
    #endif
}
