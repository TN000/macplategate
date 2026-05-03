import Foundation

/// Pos-aware CZ SPZ normalizace — řeší typické OCR confusions O↔0, I↔1, B↔8.
/// CZ formát: NXX NNNN  (pos 0=number, 1=letter, 2=alphanumeric, 3-6=numbers)
/// Pokud má text 7 znaků (po odstranění mezer), aplikujeme substituce
/// podle toho co se DLE FORMÁTU očekává v dané pozici.
enum CzNormalizer {
    private static let alphaToDigit: [Character: Character] = [
        "O": "0", "Q": "0", "D": "0",
        "I": "1", "L": "1", "T": "1",  // "1" v CZ plate fontu má diagonální
                                        // horní serif + vertikální bar → Vision
                                        // na rozmazaném/pootočeném obraze často
                                        // interpretuje jako "T" (horiz. bar +
                                        // vert. stem). T→1 na digit pozicích.
        "Z": "2", "B": "8", "S": "5", "G": "6",
    ]
    /// Opačný směr — na pozicích kde CZ plate VYŽADUJE písmeno ale Vision vrátil číslici.
    /// Nepřidáváme zde O/Q (ty jsou zakázané v CZ plates), jen 1→I, 0→D (častá záměna
    /// v stylizovaných fontech s úzkým "0"), 2→Z, 5→S, 8→B, 6→G.
    private static let digitToAlpha: [Character: Character] = [
        "1": "I", "0": "D", "2": "Z", "5": "S", "8": "B", "6": "G",
    ]
    private static let invalidChars = CharacterSet.alphanumerics
        .union(.whitespaces)
        .union(CharacterSet(charactersIn: "-"))
        .inverted

    /// First-pass — uppercase, drop diakritiku/specials, collapse spaces.
    /// **O a Q → 0 globálně** (oba znaky jsou v CZ plates zakázané a OCR je často mate
    /// s číslicí 0). Uživatel požaduje: nikde O, vždy 0.
    static func basicNormalize(_ raw: String) -> String {
        let upper = raw.uppercased()
            .replacingOccurrences(of: "O", with: "0")
            .replacingOccurrences(of: "Q", with: "0")
        let scalars = upper.unicodeScalars.filter { !invalidChars.contains($0) }
        let cleaned = String(String.UnicodeScalarView(scalars))
        return cleaned.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// Pos-aware substitutions pro 7-char CZ SPZ ("NXX NNNN").
    /// Pos 0: digit → letter→digit subst
    /// Pos 1: letter → digit→letter subst (B vidí jako 8, S jako 5, atd.)
    /// Pos 2: alphanum — necháme jak Vision vidí
    /// Pos 3–6: digit → letter→digit subst
    ///
    /// **Guard**: raw musí obsahovat alespoň 1 písmeno. Jinak je input fragment/noise
    /// (např. "0000909" z misreadu suffixu) a pos-aware subst by ho nesprávně
    /// transformoval na fake plate "0D00909". Reálné CZ plates mají letters na pos 1.
    static func smartNormalizeCz(_ text: String) -> String {
        let raw = text.replacingOccurrences(of: " ", with: "")
        guard raw.count == 7 else { return text }
        // CZ plate MUSÍ mít alespoň 1 digit (typicky pos 0 + 4 digits na suffixu).
        // All-letter inputs jako "NPRBRAM" / "ZIMNSTA" (signboard text misread) nesmí
        // Pass 1 smart subst transformovat na fake plate. alphaToDigit[B]='8' by jinak
        // dalo "NP8RAM"-alike co pasuje vanity pattern.
        guard raw.contains(where: { $0.isNumber }) else { return text }
        // **Signboard anti-noise:** basicNormalize už O→0/Q→0 udělal,
        // takže "STADION" → "STADI0N". Pokud je digit JEDINÝ a vznikl O/Q/D → 0
        // subst (all-letters v raw kromě této pozice), je to pravděpodobně
        // signboard. Pravá plate má 4+ digits (suffix) nebo 2+ (EL + 3 digits).
        let digitCount = raw.filter { $0.isNumber }.count
        if digitCount < 2 {
            return text  // bail — real plates mají ≥ 2 digits
        }
        var chars = Array(raw)
        // CZ format: pos 1 MUSÍ být písmeno (letter slot).
        // - Pokud Vision přímo vrátil letter → necháme, subst na ostatních pozicích.
        // - Pokud Vision vrátil digit → try digitToAlpha subst (8→B, 0→D atd.)
        //   ALE jen pokud ostatní letter slot (pos 2) je taky valid, jinak bail
        //   (chráníme před fake rescue z noise jako "0000909").
        if !chars[1].isLetter {
            // Guard anti-noise: "0000909" všechny zeros → rescue by dalo fake "0D00909".
            // Heuristika: všechny plates se 7 chars by měly mít ≥ 4 unikátní chars.
            // Pravé plates typicky ~6-7 unikátních chars, noise má 1-2.
            let uniq = Set(chars).count
            guard uniq >= 4, let recovered = digitToAlpha[chars[1]] else { return text }
            chars[1] = recovered
        }
        var out = chars
        out[0] = alphaToDigit[out[0]] ?? out[0]
        for i in 3...6 {
            out[i] = alphaToDigit[out[i]] ?? out[i]
        }
        return "\(out[0])\(out[1])\(out[2]) \(out[3])\(out[4])\(out[5])\(out[6])"
    }

    /// Pos-aware normalizace pro CZ elektro SPZ ("EL/EV + 3 digits + 2 letters").
    /// Aplikuje se jen když raw začíná "EL" nebo "EV" a má 7 chars. Common misreads:
    ///  - Pos 2 (first digit): O→0, I→1, Z→2 (Vision často vrátí písmeno v digit slot)
    ///  - Pos 3,4 (digits): stejné subst
    ///  - Pos 5,6 (letters): digit→letter subst (8→B, 1→I, atd.)
    static func smartNormalizeCzElectric(_ text: String) -> String {
        let raw = text.replacingOccurrences(of: " ", with: "")
        guard raw.count == 7 else { return text }
        let chars = Array(raw)
        guard chars[0] == "E", chars[1] == "L" || chars[1] == "V" else { return text }
        var out = chars
        // Pos 2-4 = digits (apply letter→digit subst)
        for i in 2...4 {
            out[i] = alphaToDigit[out[i]] ?? out[i]
        }
        // Pos 5-6 = letters (apply digit→letter subst pro jistotu; u EL plates
        // jsou to typicky regional letters BJ/AM/CZ atd.)
        let digitToAlpha: [Character: Character] = [
            "0": "O", "1": "I", "5": "S", "6": "G", "8": "B", "2": "Z"
        ]
        for i in 5...6 {
            out[i] = digitToAlpha[out[i]] ?? out[i]
        }
        return String(out)
    }

    /// Vanity-aware normalizace — značka na přání (bez fixních pozic).
    /// Písmena G, O, Q, W jsou v CZ vanity plates ZAKÁZANÁ (kvůli záměně) →
    /// pokud je OCR vidí, jde téměř jistě o chybu; subst na nejpodobnější povolený znak.
    /// Bez mezery (vanity plate nemá group separator).
    static func smartNormalizeVanity(_ text: String) -> String {
        let raw = text.replacingOccurrences(of: " ", with: "")
        guard raw.count >= 5 && raw.count <= 8 else { return text }
        // G→6 subst NESMÍ existovat — V CZ vanity je G zakázané, takže plate
        // s G je neplatná. G→6 by transformovalo signboard "ABCDEFGH" na
        // "ABCDEF6H" co matchne vanity pattern → false accept. Pokud Vision
        // vidí G, necháme ho a vanity regex ho odmítne.
        // O→0 a Q→0 jsou legitimní OCR korekce pro digit slot.
        let vanitySubst: [Character: Character] = [
            "O": "0", "Q": "0",
        ]
        return String(raw.map { vanitySubst[$0] ?? $0 })
    }

    /// Hlavní entry — trojí pokus, každá větev vrací **kanonický formát pro svůj region**:
    ///   • CZ standard / SK → "5T2 3456" (s mezerou)
    ///   • CZ vanity → "ABCDEF12" (bez mezery — vanity nemá separator)
    ///   • Foreign → "B-AB 1234" (se zachovanou interpunkcí)
    ///
    /// Kanonizace je zásadní pro tracker: Vision v jednom framu vrátí "4BX 65E", v dalším
    /// "4BX65E". Bez kanonizace jsou to dva různé klíče hlasování → fragmented consensus
    /// → track nikdy nedosáhne minWinnerVotes. Po kanonizaci oba kolabují na "4BX65E"
    /// a hlasy se sečtou.
    /// Strip whitespaces — všechny canonical outputs jsou no-space, aby se Vision
    /// inkonzistentní detekce mezery ("5U6 0000" vs "5U60000") kolabovala na 1 text
    /// a tracker/cooldown viděly stejnou plate napříč framy.
    private static func stripSpaces(_ s: String) -> String {
        s.replacingOccurrences(of: " ", with: "")
    }

    static func process(_ raw: String) -> (text: String, valid: Bool, region: PlateRegion) {
        let basic = basicNormalize(raw)
        AppState.devLog("Normalizer.start raw=\"\(raw)\" basic=\"\(basic)\"")

        // Pass 0 — **raw (bez pos-aware subst) proti CZ/SK validaci**.
        // Důvod: pokud Vision přečte "5T2 1234" správně, nechceme subst T→1
        // transformovat T (které je LEGITIMNĚ na letter slot pos 1) na nic.
        // Smart subst se aplikuje AŽ když raw nepasuje na žádný validní formát.
        // Tím se chrání plates obsahující T/L/B/I/G/S/Z v platných pozicích
        // před zbytečnou auto-korekcí.
        let (validBasic, regionBasic) = PlateValidator.validate(basic)
        if validBasic && (regionBasic == .cz || regionBasic == .czElectric || regionBasic == .sk || regionBasic == .foreign) {
            return (stripSpaces(basic), true, regionBasic)
        }

        // Pass 0.5 — EL/EV elektro prefix. "ELO67BJ" → "EL067BJ" (O→0 na pos 2).
        let electric = smartNormalizeCzElectric(basic)
        let (validElectric, regionElectric) = PlateValidator.validate(electric)
        if validElectric && regionElectric == .czElectric {
            return (stripSpaces(electric), true, .czElectric)
        }

        // Pass 1 — smart pos-aware subst (fix OCR confusions I→1, T→1, B→8,
        // S→5, Z→2, G→6 atd. NA DIGIT POZICÍCH). Aplikuje se jen když raw fails.
        let smart = smartNormalizeCz(basic)
        let (validSmart, regionSmart) = PlateValidator.validate(smart)
        if validSmart && (regionSmart == .cz || regionSmart == .czElectric || regionSmart == .sk) {
            return (stripSpaces(smart), true, regionSmart)
        }

        // Pass 2 — vanity: už no-space.
        // **Anti-signboard:** real vanity plates jsou 1-2 tokens (e.g.
        // "SPZNEM42" nebo "4BX 65E"), NIKDY 3+ tokens. Signboard text jako
        // "VCHOD DO HALY" / "OR DO KAY" má 3 space-separated tokens → basicNormalize
        // zachová spaces → stripSpaces by to joinnul na "0RD0KAY" což pass vanity pattern.
        // Hard filter: pokud basic text má ≥3 tokens po split na space, vanity rejected.
        let basicTokens = basic.split(separator: " ", omittingEmptySubsequences: true).count
        if basicTokens <= 2 {
            let vanity = smartNormalizeVanity(basic)
            let (validVanity, regionVanity) = PlateValidator.validate(vanity)
            if validVanity && regionVanity == .czVanity {
                // **8-char edge-junk salvage:** Vision občas přilepí 1 extra char
                // na začátek nebo konec skutečné CZ plate (frame edge, dirt,
                // sticker, "Š/Ě" diakritika z VIN). Trim PŘED vanity acceptance:
                // pokud 8-char trimnutý form matchne CZ/CZ⚡/SK pattern, preferuj
                // striktní formát (jinak by se 8-char vanity + 7-char CZ ocitly
                // v různých trackerách → 2 commits za jedno auto).
                let vanityNoSpace = stripSpaces(vanity)
                if vanityNoSpace.count == 8 {
                    let trimFirst = String(vanityNoSpace.dropFirst())
                    let trimLast = String(vanityNoSpace.dropLast())
                    for candidate in [trimFirst, trimLast] {
                        let (tValid, tRegion) = PlateValidator.validate(candidate)
                        if tValid && (tRegion == .cz || tRegion == .czElectric || tRegion == .sk) {
                            return (candidate, true, tRegion)
                        }
                    }
                }
                return (vanityNoSpace, true, regionVanity)
            }
        }

        // Pass 3 — foreign strict.
        let foreignText = normalizeForeign(raw)
        let (validForeign, regionForeign) = PlateValidator.validate(foreignText)
        if validForeign && regionForeign == .foreign {
            return (stripSpaces(foreignText), true, regionForeign)
        }

        // Pass 4 — foreign extract (garbage-tolerant).
        if let extracted = tryExtractForeign(raw) {
            let (validE, regionE) = PlateValidator.validate(extracted)
            if validE && regionE == .foreign {
                return (stripSpaces(extracted), true, regionE)
            }
        }

        // Fallback — Pass 1 smart matchla ale region nebyl cz/sk/czElectric, typicky
        // .czVanity. Vrátíme Pass 1 text (smart result), NE Pass 2 (text/region
        // mismatch z různých pass transformations). Při invalid smart return full-fail.
        //
        // **Extra validation**: re-validate smart result aby se nezměklo. Předchozí
        // fallback nerespektoval že Pass 2 text mohl mít jinou region než Pass 1.
        if validSmart {
            let smartNoSpace = stripSpaces(smart)
            let (revalid, reregion) = PlateValidator.validate(smartNoSpace)
            if revalid && reregion != .unknown {
                // Anti-signboard: pokud source basic měl 3+ tokens, reject
                // czVanity v fallbacku (stejná logika jako Pass 2).
                if reregion == .czVanity && basicTokens > 2 {
                    return (smartNoSpace, false, .unknown)
                }
                return (smartNoSpace, true, reregion)
            }
        }
        return (stripSpaces(smart), false, .unknown)
    }

    /// Foreign plate normalize — zachovává mezery a pomlčky, jen uppercase + remove
    /// diakritiky/special chars (kromě "- " separátorů).
    static func normalizeForeign(_ raw: String) -> String {
        let upper = raw.uppercased()
        let allowed = CharacterSet.uppercaseLetters
            .union(.decimalDigits)
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: "-"))
        let scalars = upper.unicodeScalars.filter { allowed.contains($0) }
        let cleaned = String(String.UnicodeScalarView(scalars))
        return cleaned.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// Garbage-tolerant extraction pro DE-style foreign plates.
    /// Vision u foreign plates často insertuje 1–2 extra letters mezi skupinami
    /// (flag emblem misread jako G/S/…):
    ///   "WOBG ZK 295" → "WOB ZK 295"
    ///   "WOBS ZK 275" → "WOB ZK 275"
    ///   "WOBSZK 295"  → "WOB ZK 295"
    ///   "WOB ZKS 295" → "WOB ZK 295"
    ///
    /// Regex matchne první group 1–3 písmen, až 2 "garbage" písmena, pak 1–2 písmena,
    /// separátor optional, 1–4 čísel, volitelný E/H suffix. Canonicalizuje do
    /// "LLL LL DDDD[E]" formátu.
    /// `[A-Z]{0,2}?` je LAZY — regex preferuje MÉNĚ garbage letters aby `mid`
    /// skupina dostala plné 2 letters. Dřív greedy `{0,2}` pro "WOBSZK 295" snědl
    /// "SZ" jako garbage a mid = "K" → "WOBK295". Teď lazy nejprve zkusí 0 garbage
    /// → mid = "ZK" → "WOBZK295". Pro "WOBG ZK 295" backtrack najde garbage=1 ("G")
    /// a mid="ZK". Kanonický tvar je preferovaný pro oba cases.
    private static let foreignExtractRegex = try! NSRegularExpression(
        pattern: #"([A-Z]{1,3})[A-Z]{0,2}?[- ]?([A-Z]{1,2})[- ]?([0-9]{2,4})([EH]?)"#
    )

    static func tryExtractForeign(_ raw: String) -> String? {
        let upper = raw.uppercased()
        let r = NSRange(upper.startIndex..., in: upper)
        guard let m = foreignExtractRegex.firstMatch(in: upper, range: r),
              m.numberOfRanges >= 5,
              let r1 = Range(m.range(at: 1), in: upper),
              let r2 = Range(m.range(at: 2), in: upper),
              let r3 = Range(m.range(at: 3), in: upper) else { return nil }
        // Anchor: match MUSÍ začínat na pozici 0 (nebo po whitespace). Jinak
        // pro "1WW3456" (digit prefix + mixed) by extract vyrobil fake "G W 2345"
        // foreign plate. Reálné foreign plates začínají písmenem z pozice 0
        // nebo po separátoru.
        let matchStart = m.range.location
        if matchStart > 0 {
            let beforeIdx = upper.index(upper.startIndex, offsetBy: matchStart - 1)
            let beforeChar = upper[beforeIdx]
            if !beforeChar.isWhitespace && beforeChar != "-" {
                return nil
            }
        }
        let prefix = String(upper[r1])
        let mid = String(upper[r2])
        let digits = String(upper[r3])
        let suffix: String = {
            if m.numberOfRanges >= 5, let r4 = Range(m.range(at: 4), in: upper) {
                return String(upper[r4])
            }
            return ""
        }()
        // Sanity — musí existovat >= 1 digit a >= 2 letter chars total
        guard digits.count >= 1 else { return nil }
        guard (prefix.count + mid.count) >= 2 else { return nil }
        return "\(prefix) \(mid) \(digits)\(suffix)"
    }
}
