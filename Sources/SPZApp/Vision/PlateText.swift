import Foundation

/// Value-type wrapper kolem normalizovaného plate textu. Zabaluje 3 fakta o
/// plate textu, která dnes putují odděleně skrz pipeline (text: String, region:
/// PlateRegion, isStrictValidCz: Bool) — a centralizuje logiku canonical formy
/// (trim spaces, uppercase, no-special-chars). Eliminuje class of bugs typu
/// "porovnávám raw OCR s canonical WL" které dnes řeší roztrouzené
/// `replacingOccurrences(of: " ", with: "")` v 5+ místech.
///
/// ## Kdy použít vs. nepoužít
///
/// **Použij** kdekoli máš plate text a potřebuješ ho v canonical formě pro
/// porovnání (whitelist match, dedup, file naming, DB lookup) → `PlateText.canonicalize(s)`.
///
/// **Nepoužij** pro Vision OCR pre-normalize nebo internal Normalizer logic —
/// tam se rozlišují varianty (s/bez mezer, EL/EV prefix, vanity rules) které
/// mizí v canonical formě. Tj. canonical je terminal, ne pre-processing step.
///
/// ## Struktura
///
/// `from(raw:)` je **jediný validní entry point** pro full PlateText. Spustí
/// CzNormalizer.process → vyhodnotí region → vrátí struct nebo nil (invalid).
/// `canonicalize(_:)` je čistá utility — žádný validátor, žádný region — jen
/// normalizace špatně-formátovaného textu pro string compare.
struct PlateText: Equatable, Hashable {
    /// Bez mezer, uppercase, ASCII alfanumeric only. To, co jde do DB / WL match /
    /// recents key. Příklad: "2ZB 5794" → "2ZB5794", "wob zk295" → "WOBZK295".
    let canonical: String

    /// OCR text před normalizací (pro debug / audit). Vision dal raw text,
    /// CzNormalizer ho upravil do `canonical`. Drží se jen pro logy.
    let raw: String

    /// Detekovaný region — strict CZ regex (`2ZB5794`), CZ electric (`EL123AB`),
    /// SK (`AB123CD`), foreign (DE/IT/...), vanity (`ABC123`), nebo `.unknown`.
    let region: PlateRegion

    /// True jen pro strict CZ formate (CZ / CZ⚡ / SK). Vanity ani foreign
    /// neprošli stricter format checks → tracker je sice akceptuje (fast-car
    /// path), ale snippet pro automatic actions má být striktnější.
    let isStrictValid: Bool

    /// Single normalization entry — CzNormalizer + region rozhodnutí.
    /// Vrátí nil pokud raw text není parseable jako jakýkoli plate formát.
    static func from(raw: String) -> PlateText? {
        let (text, valid, region) = CzNormalizer.process(raw)
        guard valid, !text.isEmpty else { return nil }
        let isStrict: Bool = [.cz, .czElectric, .sk].contains(region)
        return PlateText(canonical: canonicalize(text), raw: raw,
                         region: region, isStrictValid: isStrict)
    }

    /// Canonical form — `uppercased` + keep only ASCII A-Z/0-9. Použij kdykoli
    /// porovnáváš raw text proti canonical (DB plate, WL key, file name slug).
    /// Idempotentní (kanonikalizace canonical → ten samý canonical).
    static func canonicalize(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let scalars = s.uppercased().unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }
}
