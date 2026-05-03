import Foundation
import CoreImage
import CoreGraphics
import Accelerate

/// 8-DOF perspektivní transformace přes 4-bodovou korespondenci.
///
/// Hlavní use case: interaktivní kalibrace v `PerspectiveCalibrationView` —
/// uživatel označí 4 rohy referenční SPZ (sourceQuad) a kam je přesunout
/// (destinationQuad). Tento helper spočítá homografii H tak, že
/// `H * source[i] = destination[i]` pro i = 0..3, a aplikuje ji na celý
/// CIImage skrz CIPerspectiveTransform (kterému spočítáme, kam se mají
/// přemapovat 4 rohy obrazu).
enum PerspectiveTransform {

    /// Aplikuj 8-DOF perspektivní transformaci na image. `source` a
    /// `destination` jsou 4 odpovídající body v souřadnicích image extentu.
    /// Pořadí: TL, TR, BR, BL (CIImage souřadnice — origin BOTTOM-LEFT).
    /// Vrací nil pokud DLT solver selže (singulární systém / kolineární body).
    static func apply(_ image: CIImage,
                      source: [CGPoint],
                      destination: [CGPoint]) -> CIImage? {
        guard source.count == 4, destination.count == 4 else { return nil }
        guard let H = homography(source: source, destination: destination) else { return nil }
        // Spočítáme, kam se mapují 4 rohy obrazu pod H. CIPerspectiveTransform
        // pak dostane tyto 4 body jako "kam se mají přemapovat rohy extentu".
        let extent = image.extent
        let corners = [
            CGPoint(x: extent.minX, y: extent.maxY),  // TL
            CGPoint(x: extent.maxX, y: extent.maxY),  // TR
            CGPoint(x: extent.maxX, y: extent.minY),  // BR
            CGPoint(x: extent.minX, y: extent.minY),  // BL
        ]
        let mapped = corners.map { applyHomography(H, to: $0) }
        let f = CIFilter(name: "CIPerspectiveTransform")
        f?.setValue(image, forKey: kCIInputImageKey)
        f?.setValue(CIVector(cgPoint: mapped[0]), forKey: "inputTopLeft")
        f?.setValue(CIVector(cgPoint: mapped[1]), forKey: "inputTopRight")
        f?.setValue(CIVector(cgPoint: mapped[2]), forKey: "inputBottomRight")
        f?.setValue(CIVector(cgPoint: mapped[3]), forKey: "inputBottomLeft")
        return f?.outputImage
    }

    /// Spočítá homografii H jako 3×3 matici z 4-bodové korespondence
    /// pomocí Direct Linear Transformation (DLT). Vrací row-major [Double; 9]
    /// s předpokladem H[8] = 1. Nil pokud solver selže.
    static func homography(source: [CGPoint], destination: [CGPoint]) -> [Double]? {
        guard source.count == 4, destination.count == 4 else { return nil }
        // Linear system: pro každý korespondenční pár (s.x, s.y) → (d.x, d.y):
        //   d.x = (h11*s.x + h12*s.y + h13) / (h31*s.x + h32*s.y + 1)
        //   d.y = (h21*s.x + h22*s.y + h23) / (h31*s.x + h32*s.y + 1)
        // Přepsáno do lineární formy (h33 = 1):
        //   h11*s.x + h12*s.y + h13           - h31*s.x*d.x - h32*s.y*d.x = d.x
        //                       h21*s.x + h22*s.y + h23 - h31*s.x*d.y - h32*s.y*d.y = d.y
        // 4 páry → 8 rovnic → 8 neznámých (h11..h32). LAPACK dgesv.
        var A = [Double](repeating: 0, count: 64)  // 8×8 column-major
        var b = [Double](repeating: 0, count: 8)
        for i in 0..<4 {
            let sx = Double(source[i].x), sy = Double(source[i].y)
            let dx = Double(destination[i].x), dy = Double(destination[i].y)
            // Rovnice 1 (řádek 2*i):
            // [sx, sy, 1, 0, 0, 0, -sx*dx, -sy*dx] · h = dx
            let row1 = 2 * i
            setColMajor(&A, rows: 8, row: row1, col: 0, val: sx)
            setColMajor(&A, rows: 8, row: row1, col: 1, val: sy)
            setColMajor(&A, rows: 8, row: row1, col: 2, val: 1.0)
            setColMajor(&A, rows: 8, row: row1, col: 6, val: -sx * dx)
            setColMajor(&A, rows: 8, row: row1, col: 7, val: -sy * dx)
            b[row1] = dx
            // Rovnice 2 (řádek 2*i+1):
            // [0, 0, 0, sx, sy, 1, -sx*dy, -sy*dy] · h = dy
            let row2 = 2 * i + 1
            setColMajor(&A, rows: 8, row: row2, col: 3, val: sx)
            setColMajor(&A, rows: 8, row: row2, col: 4, val: sy)
            setColMajor(&A, rows: 8, row: row2, col: 5, val: 1.0)
            setColMajor(&A, rows: 8, row: row2, col: 6, val: -sx * dy)
            setColMajor(&A, rows: 8, row: row2, col: 7, val: -sy * dy)
            b[row2] = dy
        }
        // LAPACK: dgesv_ řeší AX = B in-place. b se přepíše řešením.
        var n: Int32 = 8
        var nrhs: Int32 = 1
        var lda: Int32 = 8
        var ldb: Int32 = 8
        var ipiv = [Int32](repeating: 0, count: 8)
        var info: Int32 = 0
        dgesv_(&n, &nrhs, &A, &lda, &ipiv, &b, &ldb, &info)
        guard info == 0 else { return nil }
        // h = [h11, h12, h13, h21, h22, h23, h31, h32]; doplnit h33 = 1.
        return [b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], 1.0]
    }

    /// Aplikuj homografii (3×3 row-major) na bod. Vrací CGPoint v eulidovských
    /// souřadnicích (po dělení W).
    static func applyHomography(_ H: [Double], to p: CGPoint) -> CGPoint {
        let x = Double(p.x), y = Double(p.y)
        let w = H[6] * x + H[7] * y + H[8]
        guard abs(w) > 1e-9 else { return p }
        let nx = (H[0] * x + H[1] * y + H[2]) / w
        let ny = (H[3] * x + H[4] * y + H[5]) / w
        return CGPoint(x: nx, y: ny)
    }

    private static func setColMajor(_ A: inout [Double], rows: Int,
                                    row: Int, col: Int, val: Double) {
        A[col * rows + row] = val
    }
}
