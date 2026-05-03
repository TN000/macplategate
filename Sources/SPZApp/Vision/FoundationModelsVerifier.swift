import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Intelligence on-device LLM verification layer pro plate text (macOS 26+).
///
/// Používá FoundationModels framework (dodáno s macOS 26, Xcode 26+). LLM běží
/// plně na ANE, zero cloud calls, zero per-request cost. Model ~3B parametrů
/// (compact Apple Intelligence model), typical inference ~200–500 ms na M4.
///
/// **Use case:** post-OCR correction pro low-confidence plates (Vision conf < 0.85).
/// LLM dostane kontext — CZ SPZ format pravidla + OCR chyby (B↔8, O↔0, I↔1, Z↔2)
/// — a vrátí nejpravděpodobnější corrected plate text.
///
/// **Opt-in:** `AppState.useFoundationModelsVerification` (default OFF). Vyžaduje:
/// 1. macOS 26+ (availability check přes `@available`)
/// 2. Foundation Models framework stažený (Xcode → Settings → Components → Apple Intelligence)
/// 3. Apple Intelligence povolený v System Settings
///
/// **Fallback:** když model není dostupný, `available` = false, pipeline pokračuje bez
/// verification (no-op). Žádná regrese.
///
/// **Performance budget:** 500 ms timeout — při překročení returneme original plate
/// aby se pipeline commit nezaseknul. PlatePipeline.commit() čeká sync na result.
final class FoundationModelsVerifier: @unchecked Sendable {
    static let shared = FoundationModelsVerifier()

    /// True pokud je LLM na device available a ready.
    private(set) var isAvailable: Bool = false

    // Model reference cached; session creates per-call aby transcript nebobtnal.
    // Dřív shared session akumuloval transcript přes všechny verify() calls →
    // po N commitech unbounded memory + pomalejší inference (context window).
    private var modelAny: Any?

    private init() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            // SystemLanguageModel.default je Apple Intelligence on-device model.
            // Supply chain of trust: Apple bundle → macOS install → user Apple Intelligence
            // enrollment. Pokud kterýkoli step chybí, `isAvailable` = false.
            let model = SystemLanguageModel.default
            if model.availability == .available {
                self.modelAny = model
                self.isAvailable = true
                FileHandle.safeStderrWrite(
                    "[FoundationModels] LLM verifier ready (on-device)\n".data(using: .utf8)!)
            } else {
                FileHandle.safeStderrWrite(
                    "[FoundationModels] SystemLanguageModel unavailable: \(model.availability)\n"
                        .data(using: .utf8)!)
            }
        }
        #else
        FileHandle.safeStderrWrite(
            "[FoundationModels] framework not linked (macOS pre-26) — verifier disabled\n"
                .data(using: .utf8)!)
        #endif
    }

    /// Request LLM to verify/correct a candidate plate text.
    /// Returns: corrected text nebo nil při failure / timeout.
    /// Synchronní (blocking) — PlatePipeline.commit() je nízkofrekvenční (max ~1/s),
    /// acceptable to block ~200–500 ms per call.
    func verify(plate: String, region: String, confidence: Double) -> String? {
        guard isAvailable else { return nil }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard let model = modelAny as? SystemLanguageModel else { return nil }
            // Fresh session per call — transcript buildup by jinak N × verify() = N × memory growth.
            let session = LanguageModelSession(
                model: model,
                instructions: Instructions {
                    "You are a license plate text correction assistant. "
                    "Given OCR output for a Czech/Slovak/EU license plate, "
                    "identify likely OCR errors and return the most probable correct text. "
                    "Common OCR confusions: B↔8, O↔0, I↔1, Z↔2, D↔0, S↔5, G↔6, Q↔O. "
                    "Czech plate format: 1 digit + 2 letters + 4 digits (e.g. '7ZF1234'). "
                    "Slovak: 2 letters + 3 digits + 2 letters (e.g. 'EL165CN'). "
                    "Respond with ONLY the corrected plate text, uppercase, no spaces or dashes. "
                    "If input looks already correct, return it unchanged."
                }
            )
            let prompt = """
            Raw OCR candidate: \(plate)
            Region hint: \(region)
            OCR confidence: \(String(format: "%.2f", confidence))
            Return corrected plate text only:
            """
            // Timeout via Task group — 1s max (inference typical 200-500ms)
            return runSyncWithTimeout(seconds: 1.0) { () async throws -> String? in
                let response = try await session.respond(to: prompt)
                let cleaned = response.content
                    .uppercased()
                    .replacingOccurrences(of: " ", with: "")
                    .replacingOccurrences(of: "-", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Validate — reasonable length, alphanumeric only
                guard cleaned.count >= 4, cleaned.count <= 12,
                      cleaned.allSatisfy({ $0.isLetter || $0.isNumber }) else {
                    return nil
                }
                return cleaned
            }
        }
        #endif
        return nil
    }

    /// Run async work sync with hard timeout. Pokud async work nedoběhne do N s,
    /// vrátí nil (pipeline pokračuje s originálem).
    private func runSyncWithTimeout<T>(seconds: Double, _ work: @escaping () async throws -> T?) -> T? {
        let sem = DispatchSemaphore(value: 0)
        var result: T? = nil
        let task = Task {
            do {
                result = try await work()
            } catch {
                FileHandle.safeStderrWrite(
                    "[FoundationModels] verify failed: \(error)\n".data(using: .utf8)!)
            }
            sem.signal()
        }
        if sem.wait(timeout: .now() + .init(floatLiteral: seconds)) == .timedOut {
            task.cancel()
            return nil
        }
        return result
    }
}
