import Foundation

enum PlateRegion: String {
    case cz = "CZ"
    case czElectric = "CZ⚡"  // elektrovozidlo — EL nebo EV prefix + 3 digits + 2 letters
    case czVanity = "CZ*"   // značka na přání (vyhláška 343/2014 Sb. / §7a zák. 56/2001)
    case sk = "SK"
    case foreign = "EU"     // cizí plate (DE/AT/PL…): prefix-písmena-separátor-číslice-suffix
    case unknown = ""
}

enum PlateValidator {
    // CZ standardní: **7 znaků** — 1 digit + 1 letter + 1 alphanumeric + 4 digits (např. 6S2 6003).
    // Písmena G, O, Q, W jsou **zakázaná** (vyhláška 343/2014 Sb. §7a) — jsou vizuálně
    // zaměnitelná s 6/0/0/V a nikdy se nepoužívají. Range `A-FH-NPR-VXYZ` vyloučí všechna 4.
    static let czPattern = try! NSRegularExpression(
        pattern: #"^[0-9][A-FH-NPR-VXYZ][A-FH-NPR-VXYZ0-9] ?[0-9]{4}$"#
    )
    // CZ elektrovozidla: **EL / EV** prefix + 3 číslice + 2 písmena (např. EL067BJ).
    // Platí od 2022 kdy MD ČR zavedlo speciální série pro BEV (EL) a plug-in hybrid (EV).
    // Validace MUSÍ běžet PŘED skPattern (oba matchují shodný glyph vzor).
    static let czElectricPattern = try! NSRegularExpression(
        pattern: #"^(?:EL|EV)[0-9]{3}[A-Z]{2}$"#
    )
    // CZ značka na přání / nestandardní plate: **5–8 znaků** bez mezery, min. **2**
    // číslice, **min. 1 písmeno**, bez G/O/Q/W.
    // ≥2 digits filtruje signboard texts ("STADION" → "STADI0N" má jen 1 digit).
    // Pravé vanity typicky 2+ digit (SPZNEM4M je hraniční tolerance).
    // Range: A-F (skip G), H-N (skip O), P (skip Q), R-V (skip W), X,Y,Z.
    static let czVanityPattern = try! NSRegularExpression(
        pattern: #"^(?=(?:[^0-9]*[0-9]){2})(?=.*[A-Z])[A-FH-NPR-VXYZ0-9]{5,8}$"#
    )
    // SK: 2 písmena + 3 číslice + 2 písmena (např. BA123XY).
    static let skPattern = try! NSRegularExpression(pattern: #"^[A-Z]{2}[0-9]{3}[A-Z]{2}$"#)
    // Cizí plate (DE/AT/PL/IT/ES/...): tři strukturované formáty v alternativě.
    //   (DE-style)  [1-3 letters] [-/ ] [1-2 letters] [-/ ] [2-4 digits] [optional E/H]
    //               "B-AB 1234", "M PR 1234", "HH-KK 123E", "WOB ZK 295"
    //   (IT-style)  [2 letters] [-/ ] [3 digits] [-/ ] [2 letters]
    //               "AB 123 CD", "AB-123-CD"
    //   (ES-style)  [4 digits] [-/ ] [3 letters]
    //               "1234 ABC", "1234-BCD"
    static let foreignPattern = try! NSRegularExpression(
        pattern: #"^(?:[A-Z]{1,3}[- ][A-Z]{1,2}[- ][0-9]{2,4}[EH]?|[A-Z]{2}[- ][0-9]{3}[- ][A-Z]{2}|[0-9]{4}[- ][A-Z]{3})$"#
    )
    static let minAspect: CGFloat = 2.0
    static let maxAspect: CGFloat = 6.0

    /// Priorita: CZ standard → CZ electric (EL/EV prefix) → SK → CZ vanity → foreign.
    /// Random text neprojde. CZ electric MUSÍ BÝT PŘED SK protože oba matchují shodný
    /// glyph vzor [A-Z]{2}[0-9]{3}[A-Z]{2}; pro EL067BJ-style plates chceme region=CZ⚡ ne SK.
    static func validate(_ text: String) -> (valid: Bool, region: PlateRegion) {
        let r = NSRange(text.startIndex..., in: text)
        if czPattern.firstMatch(in: text, range: r) != nil {
            return (true, .cz)
        }
        let noSpaceEarly = text.replacingOccurrences(of: " ", with: "")
        let rNSE = NSRange(noSpaceEarly.startIndex..., in: noSpaceEarly)
        if czElectricPattern.firstMatch(in: noSpaceEarly, range: rNSE) != nil {
            return (true, .czElectric)
        }
        if skPattern.firstMatch(in: text, range: r) != nil {
            return (true, .sk)
        }
        // Foreign MUSÍ být před vanity — "AB 123 CD" (IT) by jinak jako noSpace
        // "AB123CD" matchlo czVanity a .foreign by se nikdy nedostalo ke slovu.
        if foreignPattern.firstMatch(in: text, range: r) != nil {
            let alnum = text.filter { $0.isLetter || $0.isNumber }
            if alnum.count >= 5, alnum.contains(where: { $0.isNumber }) {
                return (true, .foreign)
            }
        }
        let noSpace = text.replacingOccurrences(of: " ", with: "")
        let rNS = NSRange(noSpace.startIndex..., in: noSpace)
        if czVanityPattern.firstMatch(in: noSpace, range: rNS) != nil {
            return (true, .czVanity)
        }
        return (false, .unknown)
    }

    static func aspectMatches(_ rect: CGRect) -> Bool {
        guard rect.height > 0 else { return false }
        let ar = rect.width / rect.height
        return ar >= minAspect && ar <= maxAspect
    }
}
