import Testing
import CoreGraphics
@testable import SPZApp

@Suite("PlateValidator")
struct ValidatorTests {

    @Test func czStandard_noSpace() {
        let (v, r) = PlateValidator.validate("1A23456")
        #expect(v); #expect(r == .cz)
    }

    @Test func czStandard_withSpace() {
        let (v, r) = PlateValidator.validate("1A2 3456")
        #expect(v); #expect(r == .cz)
    }

    @Test func czVanity_8chars() {
        // Vyžaduje ≥2 digits (anti-signboard).
        let (v, r) = PlateValidator.validate("SPZNEM42")
        #expect(v); #expect(r == .czVanity)
    }

    @Test func czVanity_6chars() {
        let (v, r) = PlateValidator.validate("4BX65E")
        #expect(v); #expect(r == .czVanity)
    }

    @Test func sk() {
        let (v, r) = PlateValidator.validate("BA123XY")
        #expect(v); #expect(r == .sk)
    }

    @Test func foreignDE() {
        let (v, r) = PlateValidator.validate("WOB ZK 295")
        #expect(v); #expect(r == .foreign)
    }

    @Test func foreignIT() {
        let (v, r) = PlateValidator.validate("AB 123 CD")
        #expect(v); #expect(r == .foreign)
    }

    @Test func foreignES() {
        let (v, r) = PlateValidator.validate("1234 ABC")
        #expect(v); #expect(r == .foreign)
    }

    @Test func empty() {
        #expect(PlateValidator.validate("").valid == false)
    }

    @Test func garbage() {
        #expect(PlateValidator.validate("HELLO").valid == false)
        #expect(PlateValidator.validate("12345").valid == false)
        #expect(PlateValidator.validate("ABCDEFGH").valid == false)
    }

    @Test func vanityForbiddenLetters() {
        #expect(PlateValidator.validate("1GW2345").valid == false)
        #expect(PlateValidator.validate("1OQ2345").valid == false)
    }

    @Test func aspectMatches() {
        #expect(PlateValidator.aspectMatches(CGRect(x: 0, y: 0, width: 300, height: 100)))
        #expect(PlateValidator.aspectMatches(CGRect(x: 0, y: 0, width: 100, height: 100)) == false)
        #expect(PlateValidator.aspectMatches(CGRect(x: 0, y: 0, width: 1000, height: 100)) == false)
    }
}
