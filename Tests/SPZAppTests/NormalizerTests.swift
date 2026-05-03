import Testing
@testable import SPZApp

@Suite("Normalizer")
struct NormalizerTests {

    @Test func basicNormalize_stripsInvalidChars() {
        #expect(CzNormalizer.basicNormalize("1A2!@#3456") == "1A23456")
    }

    @Test func basicNormalize_globalOQtoZero() {
        #expect(CzNormalizer.basicNormalize("5OO 3QQ4") == "500 3004")
    }

    @Test func basicNormalize_collapsesWhitespace() {
        #expect(CzNormalizer.basicNormalize("1A2   3456") == "1A2 3456")
    }

    @Test func czStandard_canonicalNoSpace() {
        let (t, v, r) = CzNormalizer.process("1A2 3456")
        #expect(v); #expect(r == .cz); #expect(t == "1A23456")
    }

    @Test func czStandard_posAwareLetterRecovery() {
        let (t, v, _) = CzNormalizer.process("182 3456")
        #expect(v); #expect(t == "1B23456")
    }

    @Test func czStandard_pos1DigitRejected() {
        let (_, v, _) = CzNormalizer.process("0000 909")
        #expect(v == false)
    }

    /// Regression: "NPRBRAM" (všechny letters, žádná digit) by jinak prošel
    /// jako falešný vanity commit s empty region (mismatch mezi Pass 2 vanity
    /// textem a Pass 1 smart region).
    @Test func allLettersNoDigit_rejected() {
        let (_, v, _) = CzNormalizer.process("NPRBRAM")
        #expect(v == false)
    }

    @Test func allLettersNoDigit_rejected_longer() {
        let (_, v, _) = CzNormalizer.process("ZIMNSTA")
        #expect(v == false)
    }

    /// Regression: "STADION" → basicNormalize → "STADI0N" (O→0). Je to signboard text
    /// z "Generic Signboard Text". Pouze 1 digit (0) z letter-subst → musí být rejected.
    @Test func signboard_STADION_rejected() {
        let (_, v, _) = CzNormalizer.process("STADION")
        #expect(v == false)
    }

    @Test func signboard_PONPBRAM_rejected() {
        // "POBHENT" / "PONHRAT" z "GenericLocation" signboard → basicNormalize → "P0NHRAT"
        let (_, v, _) = CzNormalizer.process("P0NHRAT")
        #expect(v == false)
    }

    /// Regression: "OR DO KAY" (Vision misread "VCHOD DO HALY" ENTRANCE sign)
    /// → basic "0R D0 KAY" → strip spaces → "0RD0KAY" matched vanity regex.
    /// Filter: 3+ space-separated tokens = not vanity (signboard scene text).
    @Test func signboard_3tokens_rejected() {
        #expect(CzNormalizer.process("OR DO KAY").valid == false)
        #expect(CzNormalizer.process("CHO GO HALY").valid == false)
        #expect(CzNormalizer.process("YOR GO KAY").valid == false)
        #expect(CzNormalizer.process("VCHO GO HALY").valid == false)
    }

    /// Legitimate vanity still passes (≤ 2 tokens).
    @Test func vanity_twoTokens_stillValid() {
        let (_, v, _) = CzNormalizer.process("4BX 65E")
        #expect(v)
    }

    @Test func vanity_eightChars() {
        // Vanity vyžaduje ≥2 digits (anti-signboard filter).
        let (t, v, r) = CzNormalizer.process("SPZNEM42")
        #expect(v); #expect(r == .czVanity); #expect(t == "SPZNEM42")
    }

    // 8-char edge-junk salvage: pokud trimnutí prvního/posledního znaku z 8-char
    // "vanity" dá CZ standard nebo CZ⚡ formát, preferuj 7-char strict tvar
    // (Vision občas přilepí extra char z frame edge / dirt).
    @Test func eightCharVanity_dropFirst_recoversCZ() {
        let (t, v, r) = CzNormalizer.process("13ZD8175")
        #expect(v); #expect(r == .cz); #expect(t == "3ZD8175")
    }

    @Test func eightCharVanity_dropLast_recoversCZ() {
        let (t, v, r) = CzNormalizer.process("6ZE79311")
        #expect(v); #expect(r == .cz); #expect(t == "6ZE7931")
    }

    @Test func eightCharVanity_dropLast_recoversCzElectric() {
        let (t, v, r) = CzNormalizer.process("EL328DNI")
        #expect(v); #expect(r == .czElectric); #expect(t == "EL328DN")
    }

    @Test func eightCharVanity_dropFirst_recoversCZ_letter() {
        let (t, v, r) = CzNormalizer.process("E8ZH4204")
        #expect(v); #expect(r == .cz); #expect(t == "8ZH4204")
    }

    @Test func vanity_sixChars() {
        let (t, v, r) = CzNormalizer.process("4BX 65E")
        #expect(v); #expect(r == .czVanity); #expect(t == "4BX65E")
    }

    @Test func vanity_allDigitsRejected() {
        #expect(CzNormalizer.process("12345678").valid == false)
    }

    @Test func vanity_allLettersRejected() {
        #expect(CzNormalizer.process("ABCDEFGH").valid == false)
    }

    @Test func vanity_forbidsG_O_Q_W() {
        #expect(CzNormalizer.process("1GW2345").valid == false)
    }

    @Test func foreignDE_clean() {
        let (t, v, r) = CzNormalizer.process("WOB ZK 295")
        #expect(v); #expect(r == .foreign); #expect(t == "WOBZK295")
    }

    @Test func foreignDE_garbageLetter() {
        let (t, v, _) = CzNormalizer.process("WOBG ZK 295")
        #expect(v); #expect(t == "WOBZK295")
    }

    @Test func foreignDE_noSpaceJoined_lazyRegex() {
        let (t, v, _) = CzNormalizer.process("WOBSZK 295")
        #expect(v); #expect(t == "WOBZK295")
    }

    @Test func foreignIT_style() {
        let (t, v, r) = CzNormalizer.process("AB 123 CD")
        #expect(v); #expect(r == .foreign); #expect(t == "AB123CD")
    }

    @Test func foreignES_style() {
        let (t, v, r) = CzNormalizer.process("1234 BCD")
        #expect(v); #expect(r == .foreign); #expect(t == "1234BCD")
    }

    @Test func allOutputsNoSpace() {
        #expect(CzNormalizer.process("1A2 3456").text.contains(" ") == false)
        #expect(CzNormalizer.process("WOB ZK 295").text.contains(" ") == false)
        #expect(CzNormalizer.process("SPZ NEM4M").text.contains(" ") == false)
    }
}
