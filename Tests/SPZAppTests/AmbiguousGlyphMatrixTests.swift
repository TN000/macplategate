import Testing
import Foundation
@testable import SPZApp

@Suite("AmbiguousGlyphMatrix")
struct AmbiguousGlyphMatrixTests {

    @Test("Classic incident: 2S32376 vs 2B32376 — L1 ambiguous (S↔B)")
    func classicIncident() {
        let r = AmbiguousGlyphMatrix.compareWithAmbiguous("2S32376", "2B32376")
        #expect(r.editDistance == 1)
        #expect(r.allMismatchesAmbiguous == true)
        #expect(r.ambiguousMismatchCount == 1)
    }

    @Test("Non-ambiguous mismatch: 2S32376 vs 2X32376 — L1 not ambiguous")
    func nonAmbiguousMismatch() {
        let r = AmbiguousGlyphMatrix.compareWithAmbiguous("2S32376", "2X32376")
        #expect(r.editDistance == 1)
        #expect(r.allMismatchesAmbiguous == false)
        #expect(r.ambiguousMismatchCount == 0)
    }

    @Test("Multi-position all-ambiguous: 1AB000 vs IAB0OO — L3 all ambiguous")
    func multiAmbiguous() {
        let r = AmbiguousGlyphMatrix.compareWithAmbiguous("1AB000", "IAB0OO")
        #expect(r.editDistance == 3)
        #expect(r.allMismatchesAmbiguous == true)  // 1↔I, 0↔O, 0↔O
        #expect(r.ambiguousMismatchCount == 3)
    }

    @Test("Mixed ambiguous + non-ambiguous: not allMismatchesAmbiguous")
    func mixedMismatch() {
        // 8↔B (ambiguous), X↔Y (not): editDistance=2, ambiguous=1, all=false
        let r = AmbiguousGlyphMatrix.compareWithAmbiguous("8XBC", "BYBC")
        #expect(r.editDistance == 2)
        #expect(r.allMismatchesAmbiguous == false)
        #expect(r.ambiguousMismatchCount == 1)
    }

    @Test("Identical strings: editDistance=0, allMismatchesAmbiguous=false")
    func identical() {
        let r = AmbiguousGlyphMatrix.compareWithAmbiguous("2S32376", "2S32376")
        #expect(r.editDistance == 0)
        #expect(r.allMismatchesAmbiguous == false)  // requires editDistance>=1
        #expect(r.ambiguousMismatchCount == 0)
    }

    @Test("Symmetry: compareWithAmbiguous(a,b) == compareWithAmbiguous(b,a)")
    func symmetric() {
        let cases = [("2S32376", "2B32376"), ("ABCDEF", "QBCDEF"), ("8XBC", "BYBC")]
        for (a, b) in cases {
            let ab = AmbiguousGlyphMatrix.compareWithAmbiguous(a, b)
            let ba = AmbiguousGlyphMatrix.compareWithAmbiguous(b, a)
            #expect(ab.editDistance == ba.editDistance)
            #expect(ab.allMismatchesAmbiguous == ba.allMismatchesAmbiguous)
            #expect(ab.ambiguousMismatchCount == ba.ambiguousMismatchCount)
        }
    }

    @Test("Length mismatch — returns .unequalLength sentinel")
    func unequalLength() {
        let r = AmbiguousGlyphMatrix.compareWithAmbiguous("ABC", "ABCD")
        #expect(r.editDistance == Int.max)
        #expect(r.allMismatchesAmbiguous == false)
    }

    @Test("Empty strings")
    func emptyStrings() {
        let r = AmbiguousGlyphMatrix.compareWithAmbiguous("", "")
        #expect(r.editDistance == 0)
        #expect(r.allMismatchesAmbiguous == false)
    }

    @Test("isAmbiguousSwap individual char pairs")
    func individualSwaps() {
        // Symmetric assertions
        #expect(AmbiguousGlyphMatrix.isAmbiguousSwap("S", "B"))
        #expect(AmbiguousGlyphMatrix.isAmbiguousSwap("B", "S"))
        #expect(AmbiguousGlyphMatrix.isAmbiguousSwap("8", "B"))
        #expect(AmbiguousGlyphMatrix.isAmbiguousSwap("0", "O"))
        #expect(AmbiguousGlyphMatrix.isAmbiguousSwap("5", "S"))
        // Same char — false (no swap)
        #expect(!AmbiguousGlyphMatrix.isAmbiguousSwap("S", "S"))
        // Non-ambiguous — false
        #expect(!AmbiguousGlyphMatrix.isAmbiguousSwap("X", "Y"))
        #expect(!AmbiguousGlyphMatrix.isAmbiguousSwap("A", "Z"))
    }
}
