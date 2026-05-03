import Testing
@testable import SPZApp

@Suite("CZ Electric plate format")
struct CzElectricTests {

    @Test func validate_EL067BJ_isCzElectric() {
        let (valid, region) = PlateValidator.validate("EL067BJ")
        #expect(valid)
        #expect(region == .czElectric)
    }

    @Test func validate_EV123AB_isCzElectric() {
        let (valid, region) = PlateValidator.validate("EV123AB")
        #expect(valid)
        #expect(region == .czElectric)
    }

    @Test func validate_BA123XY_stillSlovak() {
        // Slovak format nesmí být hijacknutý naším EL/EV patternem.
        let (valid, region) = PlateValidator.validate("BA123XY")
        #expect(valid)
        #expect(region == .sk)
    }

    @Test func normalize_ELO67BJ_toEL067BJ() {
        // OCR common misread: O (letter) místo 0 (digit) na pozici 2.
        let (text, valid, region) = CzNormalizer.process("ELO67BJ")
        #expect(valid)
        #expect(region == .czElectric)
        #expect(text == "EL067BJ")
    }

    @Test func normalize_EL067BJ_unchanged() {
        // Already correct — žádná subst, region czElectric.
        let (text, valid, region) = CzNormalizer.process("EL067BJ")
        #expect(valid)
        #expect(region == .czElectric)
        #expect(text == "EL067BJ")
    }

    @Test func normalize_ELI67BJ_toEL167BJ() {
        // OCR misread: I (letter) místo 1 (digit) na pozici 2.
        let (text, valid, region) = CzNormalizer.process("ELI67BJ")
        #expect(valid)
        #expect(region == .czElectric)
        #expect(text == "EL167BJ")
    }

    @Test func normalize_EL067B0_toEL067BO() {
        // OCR misread: 0 (digit) na letter slot (pos 6) → D→ letter O.
        // digitToAlpha: 0→O. Ale pozice 5 je B, 6 je 0 → smartElectric: B remains, 0→O.
        let (text, valid, region) = CzNormalizer.process("EL067B0")
        #expect(valid)
        #expect(region == .czElectric)
        #expect(text == "EL067BO")
    }
}
