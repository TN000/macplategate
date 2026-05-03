import Foundation

/// Páry znaků které OCR engines (Vision .accurate + FastPlateOCR cct-xs)
/// běžně zaměňují u low-resolution plate textů. Symetric — A↔B implies B↔A.
/// Single source-of-truth pro fuzzy plate-text equivalence napříč Tracker /
/// PlatePipeline / Mark Wrong, aby nevznikaly paralelní tracky pro stejné auto
/// při swap typu S↔B / 0↔O / 8↔B atd.
enum AmbiguousGlyphMatrix {

    /// Symetric pair — A↔B equiv B↔A. Storage normalizes order (smaller first).
    struct UnorderedPair: Hashable {
        let a: Character
        let b: Character

        init(_ x: Character, _ y: Character) {
            if x <= y { self.a = x; self.b = y }
            else { self.a = y; self.b = x }
        }
    }

    /// Ambiguous swap pairs known to fire across both OCR engines.
    static let pairs: Set<UnorderedPair> = [
        // Number ↔ alpha glyph swaps (most common):
        UnorderedPair("8", "B"), UnorderedPair("0", "O"), UnorderedPair("0", "D"),
        UnorderedPair("5", "S"), UnorderedPair("1", "I"), UnorderedPair("1", "L"),
        UnorderedPair("2", "Z"), UnorderedPair("6", "G"), UnorderedPair("9", "g"),
        // Pure alpha confusions:
        UnorderedPair("S", "B"),
        UnorderedPair("O", "Q"), UnorderedPair("U", "V"), UnorderedPair("M", "N"),
        UnorderedPair("E", "F"), UnorderedPair("P", "R"), UnorderedPair("C", "G"),
        UnorderedPair("D", "B"), UnorderedPair("H", "N"),
    ]

    /// True pokud (a, b) je ambiguous-glyph swap.
    static func isAmbiguousSwap(_ a: Character, _ b: Character) -> Bool {
        if a == b { return false }
        return pairs.contains(UnorderedPair(a, b))
    }
}

/// Result struktura pro `compareWithAmbiguous` — quantitative + qualitative.
struct AmbiguousMatchResult {
    /// Hamming-distance number of mismatched positions (assumes equal length).
    /// For unequal lengths returns `Int.max` — caller should treat jako "no match".
    let editDistance: Int

    /// True pokud editDistance >= 1 a všechny mismatched positions jsou
    /// `AmbiguousGlyphMatrix.isAmbiguousSwap`. Pro identical strings false
    /// (žádná ambiguity to handle).
    let allMismatchesAmbiguous: Bool

    /// Počet mismatched pozic které jsou v matrix. <= editDistance.
    let ambiguousMismatchCount: Int

    static let unequalLength = AmbiguousMatchResult(
        editDistance: Int.max,
        allMismatchesAmbiguous: false,
        ambiguousMismatchCount: 0
    )
}

extension AmbiguousGlyphMatrix {

    /// Position-by-position comparison s ambiguous-glyph awareness.
    /// Strings musí mít stejnou délku (Hamming, ne full Levenshtein s indels).
    /// Pro plate canonicalized text (no spaces) je equal-length nejčastější
    /// případ — tracker už canonicalizuje text před clustering.
    ///
    /// Rationale: full L2 s indels by mohlo merge `ABC123` a `AABC123` (insert)
    /// což pro plate variants není user expectation — chceme jen substituce.
    static func compareWithAmbiguous(_ a: String, _ b: String) -> AmbiguousMatchResult {
        let aChars = Array(a)
        let bChars = Array(b)
        guard aChars.count == bChars.count else {
            return .unequalLength
        }
        var editDistance = 0
        var ambiguousCount = 0
        for i in 0..<aChars.count {
            if aChars[i] != bChars[i] {
                editDistance += 1
                if AmbiguousGlyphMatrix.isAmbiguousSwap(aChars[i], bChars[i]) {
                    ambiguousCount += 1
                }
            }
        }
        let allAmbiguous = editDistance >= 1 && ambiguousCount == editDistance
        return AmbiguousMatchResult(
            editDistance: editDistance,
            allMismatchesAmbiguous: allAmbiguous,
            ambiguousMismatchCount: ambiguousCount
        )
    }
}
