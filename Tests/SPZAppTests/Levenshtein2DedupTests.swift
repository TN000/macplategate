import Foundation
import Testing
@testable import SPZApp

/// Regression test pro L-2 low-conf dedup gate v `Pipeline.commit()`.
/// Misread typu F→1 + 8→0 (= Lev distance 2) by jinak vygeneroval druhý track
/// a druhý DB záznam pro stejné auto. L-1 fuzzy gate to nezachytí, low-conf
/// gate (best.meanConf < 0.7) ano. Risk: dvě reálná různá auta s plate L-2
/// v 25 s window je pravděpodobnost blízká nule.
struct Levenshtein2DedupTests {
    @Test func levenshtein2_sameLength_2subs() {
        // 6AF0842 vs 6A10042 — dvě substituce (pozice 2, 4).
        #expect(isLevenshtein2("6AF0842", "6A10042") == true)
    }

    @Test func levenshtein2_sameLength_3subs_rejected() {
        // 3 substitutions je už příliš.
        #expect(isLevenshtein2("ABCDEFG", "AXYZEFG") == false)
    }

    @Test func levenshtein2_sameLength_equal() {
        // 0 distance = within L-2.
        #expect(isLevenshtein2("ABCDEFG", "ABCDEFG") == true)
    }

    @Test func levenshtein2_sameLength_1sub() {
        // L-1 case taky valid v L-2 gate.
        #expect(isLevenshtein2("ABCDEFG", "ABCXEFG") == true)
    }

    @Test func levenshtein2_lengthDiff1_oneDelete() {
        // Insertion/deletion 1 — ABCD vs ABCXD.
        #expect(isLevenshtein2("ABCD", "ABCXD") == true)
    }

    @Test func levenshtein2_lengthDiff2_twoInserts() {
        // ABCD vs ABCXYD = 2 inserts.
        #expect(isLevenshtein2("ABCD", "ABCXYD") == true)
    }

    @Test func levenshtein2_lengthDiff3_rejected() {
        // ABC vs ABCXYZW = 4 inserts.
        #expect(isLevenshtein2("ABC", "ABCXYZW") == false)
    }

    @Test func levenshtein2_emptyPair() {
        #expect(isLevenshtein2("", "") == true)
        #expect(isLevenshtein2("", "AB") == true)   // Lev distance 2
        #expect(isLevenshtein2("", "ABC") == false) // Lev distance 3
    }

    @Test func levenshtein2_realWorldMisreads() {
        // Skutečné misreads pozorované v provozu.
        #expect(isLevenshtein2("6AF0842", "6A10042") == true)   // F→1 + 8→0
        #expect(isLevenshtein2("4ZD0172", "4Z00172") == true)   // D→0 (L-1)
        #expect(isLevenshtein2("2ZB5794", "2ZB5704") == true)   // 9→0 (L-1)
        #expect(isLevenshtein2("EL067BJ", "EL028DN") == false)  // 4 differences
    }
}
