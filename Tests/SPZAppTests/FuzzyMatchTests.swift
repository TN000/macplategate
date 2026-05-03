import Testing
@testable import SPZApp

@Suite("FuzzyMatch")
struct FuzzyMatchTests {

    @Test func equalTexts_l1() {
        #expect(isLevenshtein1("ABC", "ABC"))
    }

    @Test func substitution_l1() {
        #expect(isLevenshtein1("ABC", "ADC"))
        #expect(isLevenshtein1("ABC", "ADD") == false)
    }

    @Test func insertion_l1() {
        #expect(isLevenshtein1("ABC", "ABXC"))
    }

    @Test func deletion_l1() {
        #expect(isLevenshtein1("ABXC", "ABC"))
    }

    @Test func lengthDiff_gt1_rejected() {
        #expect(isLevenshtein1("ABC", "ABCDE") == false)
    }

    @Test func realPlateVariants() {
        #expect(isLevenshtein1("WOBZK295", "WOBK295"))
        #expect(isLevenshtein1("WOBZK295", "WOBZK275"))
        #expect(isLevenshtein1("WOBZK295", "CAYMAN7") == false)
    }

    @Test func snap_exactMatch() {
        #expect(fuzzySnapToKnown("1A23456", known: ["1A23456", "5U60000"]) == "1A23456")
    }

    @Test func snap_oneCharOff() {
        #expect(fuzzySnapToKnown("1A23476", known: ["1A23456"]) == "1A23456")
    }

    @Test func snap_noMatch() {
        #expect(fuzzySnapToKnown("WXYZ123", known: ["1A23456"]) == "WXYZ123")
    }

    @Test func snap_emptyKnown() {
        #expect(fuzzySnapToKnown("1A23456", known: []) == "1A23456")
    }
}
