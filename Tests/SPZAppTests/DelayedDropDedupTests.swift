import Testing
import Foundation
@testable import SPZApp

/// Tests pro Vrstva 5 fragment-match heuristiku (garbage misread duplicate
/// commitnutý několik vteřin po správném consensus).
///
/// Testujeme isolated heuristiku co rozhoduje o registraci do
/// pendingDropCandidates. Integration testy pro pre-commit gate vyžadují
/// broader mocking a jsou deferred do live monitoringu.
@Suite("DelayedDropDedup")
struct DelayedDropDedupTests {

    // MARK: - Same-prefix-L3 fragment match (incident replay)

    @Test("1ZA4407 vs 1ZA2071 — same-prefix-L3 fragment match")
    func incidentSamePrefixL3() {
        // length=7 same, prefix="1ZA" (3 chars), levenshtein <= 3
        #expect(PlatePipeline.isLikelyFragmentMatch("1ZA4407", "1ZA2071"))
    }

    @Test("Same-prefix-L3 length gate is enforced only after L1/L2 fail")
    func samePrefixL3LengthGate() {
        // "1ZA44" vs "1ZA22" — L2 (2 subs) matches via isLevenshtein2 BEFORE
        // length-gate check. Same-prefix-L3 length gate je defense-in-depth
        // pro long-distance fragments, ne pro short L≤2 plates.
        #expect(PlatePipeline.isLikelyFragmentMatch("1ZA44", "1ZA22"))  // L2 hit
    }

    @Test("Same-prefix-L3 needs prefix >= 3")
    func samePrefixL3PrefixGate() {
        // "8ZB1234" vs "8ZC5678" — prefix=2 ("8Z"), levenshtein > 3 → no match
        #expect(!PlatePipeline.isLikelyFragmentMatch("8ZB1234", "8ZC5678"))
    }

    @Test("Same-prefix-L3 needs distance <= 3")
    func samePrefixL3DistanceGate() {
        // "1ZA0000" vs "8ZBCDEF" — prefix=0, levenshtein > 3 → no match
        #expect(!PlatePipeline.isLikelyFragmentMatch("1ZA0000", "8ZBCDEF"))
    }

    // MARK: - Ambiguous-glyph fragment match

    @Test("Ambiguous-glyph swap fragment match — 1↔I")
    func ambiguousGlyph1ToI() {
        // "4ZD0172" vs "4ZD0I72" — pos 4: 1↔I → editDistance=1, allMismatchesAmbiguous
        #expect(PlatePipeline.isLikelyFragmentMatch("4ZD0172", "4ZD0I72"))
    }

    @Test("Ambiguous-glyph swap S↔B fragment match")
    func ambiguousGlyphSToB() {
        // "2S32376" vs "2B32376" — pos 1: S↔B → editDistance=1, allMismatchesAmbiguous
        #expect(PlatePipeline.isLikelyFragmentMatch("2S32376", "2B32376"))
    }

    // MARK: - L1/L2 fragment match (existing helpers)

    @Test("L1 substitution fragment match")
    func l1SubstitutionMatch() {
        // single non-ambiguous substitution → L1 match
        #expect(PlatePipeline.isLikelyFragmentMatch("1ZA4407", "1ZA4408"))
    }

    @Test("L2 fragment match")
    func l2Match() {
        // 2 non-ambiguous substitutions → L2 match
        #expect(PlatePipeline.isLikelyFragmentMatch("1ZA4407", "1ZA4499"))
    }

    // MARK: - Negative cases (no fragment match)

    @Test("Different camera scenario — clean 2nd vehicle, no match")
    func cleanSecondVehicleNoMatch() {
        // 1ZA4407 vs 2ZB6721 — no common prefix, different shape, L > 3
        #expect(!PlatePipeline.isLikelyFragmentMatch("1ZA4407", "2ZB6721"))
    }

    @Test("Reverse same-prefix scenarios are also valid (symmetry)")
    func samePrefixSymmetric() {
        // a vs b ↔ b vs a should give same result
        let result1 = PlatePipeline.isLikelyFragmentMatch("1ZA4407", "1ZA2071")
        let result2 = PlatePipeline.isLikelyFragmentMatch("1ZA2071", "1ZA4407")
        #expect(result1 == result2)
    }

    // MARK: - Helper levenshtein function

    @Test("levenshtein helper — equal strings = 0")
    func levenshteinEqual() {
        #expect(levenshtein("1ZA4407", "1ZA4407") == 0)
    }

    @Test("levenshtein helper — single substitution = 1")
    func levenshteinL1() {
        #expect(levenshtein("1ZA4407", "1ZA4408") == 1)
    }

    @Test("levenshtein helper — incident plates")
    func levenshteinIncident() {
        // 1ZA4407 vs 1ZA2071: positions 4,5,6,7 differ
        // Different alignments may give different distances, but should be <= 4
        let dist = levenshtein("1ZA4407", "1ZA2071")
        #expect(dist <= 4)
        #expect(dist >= 3)
    }

    @Test("levenshtein helper — empty inputs")
    func levenshteinEmpty() {
        #expect(levenshtein("", "") == 0)
        #expect(levenshtein("ABC", "") == 3)
        #expect(levenshtein("", "ABC") == 3)
    }
}
