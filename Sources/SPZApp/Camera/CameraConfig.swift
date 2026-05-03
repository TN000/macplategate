import Foundation

struct CameraConfig: Codable, Identifiable, Hashable {
    var name: String
    var label: String
    var rtspURL: String
    var detectFps: Double = 10.0
    var roi: RoiBox? = nil  // 640×640 v souřadnicích zdrojového framu
    var enabled: Bool = true
    /// Per-camera min velikost Vision observation (zlomek výšky cropu).
    /// Dřív bylo v AppState jako globální; teď per-camera pro vjezd/výjezd zvlášť.
    var ocrMinObsHeightFraction: Double = 0.05
    /// Per-camera delay (sekundy) mezi commity stejné SPZ. Zvláštní pro každou
    /// kameru — vjezd a výjezd mají typicky odlišné tempo opakovaných detekcí.
    var recommitDelaySec: Double = 15.0

    var id: String { name }

    /// Forward-compat Codable — nová pole chybí ve starých cameras.json, proto
    /// decodeIfPresent s fallbacky.
    enum CodingKeys: String, CodingKey {
        case name, label, rtspURL, detectFps, roi, enabled
        case ocrMinObsHeightFraction, recommitDelaySec
    }

    init(name: String, label: String, rtspURL: String,
         detectFps: Double = 10.0, roi: RoiBox? = nil, enabled: Bool = true,
         ocrMinObsHeightFraction: Double = 0.05, recommitDelaySec: Double = 15.0) {
        self.name = name; self.label = label; self.rtspURL = rtspURL
        self.detectFps = detectFps; self.roi = roi; self.enabled = enabled
        self.ocrMinObsHeightFraction = ocrMinObsHeightFraction
        self.recommitDelaySec = recommitDelaySec
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.label = try c.decode(String.self, forKey: .label)
        self.rtspURL = try c.decode(String.self, forKey: .rtspURL)
        self.detectFps = (try? c.decodeIfPresent(Double.self, forKey: .detectFps)) ?? 10.0
        self.roi = try? c.decodeIfPresent(RoiBox.self, forKey: .roi)
        self.enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        let rawMinObs = (try? c.decodeIfPresent(Double.self, forKey: .ocrMinObsHeightFraction)) ?? 0.05
        // Migration: bumpu down default-tier hodnoty (0.02/0.04/0.05) na nižší
        // floor pro fast-car detekce. Custom hodnoty jiné než tyto tři zůstávají
        // beze změny.
        let migrated: Double
        switch rawMinObs {
        case 0.02: migrated = 0.015
        case 0.04: migrated = 0.025
        case 0.05: migrated = 0.035
        default: migrated = rawMinObs
        }
        self.ocrMinObsHeightFraction = migrated
        self.recommitDelaySec = (try? c.decodeIfPresent(Double.self, forKey: .recommitDelaySec)) ?? 15.0
    }
}

struct RoiBox: Codable, Hashable {
    /// Pravoúhlá oblast v souřadnicích source framu (pixely).
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    /// Rotace ROI kolem jeho středu [stupně, -180..180]. 0 = žádná rotace.
    /// Použito pro natočení kosých plates (kamera pod úhlem) tak aby Vision
    /// dostal text ve svislé orientaci a lépe četl.
    var rotationDeg: Double = 0
    /// Volitelná perspektivní korekce aplikovaná PO rotaci. nil = bez korekce.
    var perspective: PerspectiveConfig? = nil
    /// Volitelná oblast detekce uvnitř perspektivně-korigovaného ROI — 4 body
    /// v normalized TL-origin [0,1] coords. OCR běží pouze v axis-aligned bbox
    /// těchto 4 bodů. nil = celý ROI (žádné další omezení).
    var detectionQuad: [CGPoint]? = nil
    /// Exclusion masks — seznam normalized rects ([0,1] TL-origin) uvnitř ROI
    /// které se mají při OCR IGNOROVAT. Use case: reklamní nápisy, loga, banner
    /// text nad bránou (např. "Generic Signboard Text") co Vision opakovaně misreadne
    /// jako fake plate. User je může nakreslit v Settings → ROI → Masks.
    /// Vision filter: text observations uvnitř jakékoliv mask rect se skipnou.
    var exclusionMasks: [CGRect] = []
    /// Volitelná interaktivní 4-bodová perspektivní kalibrace aplikovaná
    /// **POSLEDNÍ** ve stacku (rotace → existující perspective sliders →
    /// tato calibrace). Když je nastavena, runtime přidá 8-DOF homografii
    /// na výstup pre-OCR cropu. nil = bez calibrace.
    var perspectiveCalibration: PerspectiveCalibration? = nil

    init(x: Int, y: Int, width: Int, height: Int, rotationDeg: Double = 0,
         perspective: PerspectiveConfig? = nil, detectionQuad: [CGPoint]? = nil,
         exclusionMasks: [CGRect] = [],
         perspectiveCalibration: PerspectiveCalibration? = nil) {
        self.x = x; self.y = y; self.width = width; self.height = height
        self.rotationDeg = rotationDeg
        self.perspective = perspective
        self.detectionQuad = detectionQuad
        self.exclusionMasks = exclusionMasks
        self.perspectiveCalibration = perspectiveCalibration
    }

    init(rect: CGRect, rotationDeg: Double = 0,
         perspective: PerspectiveConfig? = nil, detectionQuad: [CGPoint]? = nil,
         exclusionMasks: [CGRect] = [],
         perspectiveCalibration: PerspectiveCalibration? = nil) {
        self.x = Int(rect.origin.x.rounded())
        self.y = Int(rect.origin.y.rounded())
        self.width = Int(rect.size.width.rounded())
        self.height = Int(rect.size.height.rounded())
        self.rotationDeg = rotationDeg
        self.perspective = perspective
        self.detectionQuad = detectionQuad
        self.exclusionMasks = exclusionMasks
        self.perspectiveCalibration = perspectiveCalibration
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    var rotationRadians: CGFloat { CGFloat(rotationDeg) * .pi / 180.0 }

    /// Forward-compat Codable — nové pole `perspective` chybí ve starých
    /// cameras.json, proto decodeIfPresent + default nil.
    enum CodingKeys: String, CodingKey {
        case x, y, width, height, rotationDeg, perspective, detectionQuad
        case exclusionMasks, perspectiveCalibration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.x = try c.decode(Int.self, forKey: .x)
        self.y = try c.decode(Int.self, forKey: .y)
        self.width = try c.decode(Int.self, forKey: .width)
        self.height = try c.decode(Int.self, forKey: .height)
        self.rotationDeg = (try? c.decodeIfPresent(Double.self, forKey: .rotationDeg)) ?? 0
        self.perspective = try? c.decodeIfPresent(PerspectiveConfig.self, forKey: .perspective)
        self.detectionQuad = try? c.decodeIfPresent([CGPoint].self, forKey: .detectionQuad)
        self.exclusionMasks = (try? c.decodeIfPresent([CGRect].self, forKey: .exclusionMasks)) ?? []
        self.perspectiveCalibration = try? c.decodeIfPresent(PerspectiveCalibration.self, forKey: .perspectiveCalibration)
    }
}

/// Interaktivní 4-bodová perspektivní kalibrace — uživatel označí 4 rohy
/// referenční SPZ v ROI cropu (`sourceQuad`, fáze A "free"), pak je přesune
/// kam mají skutečně vést (`destinationQuad`, fáze B "locked"). Runtime
/// spočítá 8-DOF homografii a aplikuje na celý ROI crop.
///
/// Souřadnice obou quadů jsou normalized [0,1] v ROI cropu PO rotaci +
/// existing perspective sliders. Pořadí bodů: TL, TR, BR, BL.
struct PerspectiveCalibration: Codable, Hashable {
    var sourceQuad: [CGPoint]      // 4 body, kde JE referenční plate v cropu
    var destinationQuad: [CGPoint] // 4 body, kam má plate vyrovnaně vést
    /// Doladění výsledné homografie — scale kolem středu cropu (X, Y nezávisle)
    /// + translace celého výstupu. Range scale 0.5..2.0, offset −0.5..+0.5
    /// (normalized vůči šířce/výšce cropu).
    var scaleX: Double = 1.0
    var scaleY: Double = 1.0
    var offsetX: Double = 0.0
    var offsetY: Double = 0.0

    enum CodingKeys: String, CodingKey {
        case sourceQuad, destinationQuad, scaleX, scaleY, offsetX, offsetY
    }

    init(sourceQuad: [CGPoint], destinationQuad: [CGPoint],
         scaleX: Double = 1.0, scaleY: Double = 1.0,
         offsetX: Double = 0.0, offsetY: Double = 0.0) {
        self.sourceQuad = sourceQuad
        self.destinationQuad = destinationQuad
        self.scaleX = scaleX; self.scaleY = scaleY
        self.offsetX = offsetX; self.offsetY = offsetY
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sourceQuad = try c.decode([CGPoint].self, forKey: .sourceQuad)
        self.destinationQuad = try c.decode([CGPoint].self, forKey: .destinationQuad)
        self.scaleX = (try? c.decodeIfPresent(Double.self, forKey: .scaleX)) ?? 1.0
        self.scaleY = (try? c.decodeIfPresent(Double.self, forKey: .scaleY)) ?? 1.0
        self.offsetX = (try? c.decodeIfPresent(Double.self, forKey: .offsetX)) ?? 0.0
        self.offsetY = (try? c.decodeIfPresent(Double.self, forKey: .offsetY)) ?? 0.0
    }
}

/// Perspektivní korekce aplikovaná na rotovaný ROI crop PŘED Vision.
///
/// **Souřadnice 4 rohů v normalized [0,1] prostoru ROI cropu** (po rotaci),
/// kde (0,0) = levý horní roh, (1,1) = pravý dolní. Default (identity) = rohy
/// na (0,0), (1,0), (1,1), (0,1) → CIPerspectiveCorrection je no-op.
///
/// Uživatel v kalibračním overlayi přetáhne rohy na skutečné rohy referenční
/// SPZ v záběru. App pak každý frame aplikuje reverzní homografii → dostává
/// SPZ v čelním pohledu.
///
/// `scaleX`, `scaleY` (0.5–2.0) jsou jemné doladění výstupního obdélníku —
/// umožňují natáhnout/zkrátit korigovaný výsledek po ose.
struct PerspectiveConfig: Codable, Hashable {
    var topLeft: CGPoint      // (0,0) identity
    var topRight: CGPoint     // (1,0) identity
    var bottomRight: CGPoint  // (1,1) identity
    var bottomLeft: CGPoint   // (0,1) identity
    var scaleX: Double = 1.0
    var scaleY: Double = 1.0
    /// Síla korekce (0.0 = bez korekce, 1.0 = full homography, 1.5 = overcorrect).
    /// Interpoluje mezi identitou a plnou korekcí — user může ladit pokud je
    /// 100 % příliš agresivní (např. 0.85 = 15 % méně korekce).
    var strength: Double = 1.0
    /// Posun celého výstupu ve 2D po X/Y osách, normalized -1..+1 vůči ROI šířce/výšce.
    /// Používá se pro dorovnání po scaleX/Y, kdy content vyjede mimo ROI rámec.
    var offsetX: Double = 0.0
    var offsetY: Double = 0.0

    static let identity = PerspectiveConfig(
        topLeft: CGPoint(x: 0, y: 0),
        topRight: CGPoint(x: 1, y: 0),
        bottomRight: CGPoint(x: 1, y: 1),
        bottomLeft: CGPoint(x: 0, y: 1)
    )

    enum CodingKeys: String, CodingKey {
        case topLeft, topRight, bottomRight, bottomLeft, scaleX, scaleY, strength, offsetX, offsetY
    }

    init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint,
         scaleX: Double = 1.0, scaleY: Double = 1.0, strength: Double = 1.0,
         offsetX: Double = 0.0, offsetY: Double = 0.0) {
        self.topLeft = topLeft; self.topRight = topRight
        self.bottomRight = bottomRight; self.bottomLeft = bottomLeft
        self.scaleX = scaleX; self.scaleY = scaleY
        self.strength = strength
        self.offsetX = offsetX; self.offsetY = offsetY
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.topLeft = try c.decode(CGPoint.self, forKey: .topLeft)
        self.topRight = try c.decode(CGPoint.self, forKey: .topRight)
        self.bottomRight = try c.decode(CGPoint.self, forKey: .bottomRight)
        self.bottomLeft = try c.decode(CGPoint.self, forKey: .bottomLeft)
        self.scaleX = (try? c.decodeIfPresent(Double.self, forKey: .scaleX)) ?? 1.0
        self.scaleY = (try? c.decodeIfPresent(Double.self, forKey: .scaleY)) ?? 1.0
        self.strength = (try? c.decodeIfPresent(Double.self, forKey: .strength)) ?? 1.0
        self.offsetX = (try? c.decodeIfPresent(Double.self, forKey: .offsetX)) ?? 0.0
        self.offsetY = (try? c.decodeIfPresent(Double.self, forKey: .offsetY)) ?? 0.0
    }

    /// True pokud je konfigurace no-op.
    var isIdentity: Bool {
        let eps = 0.001
        return abs(topLeft.x) < eps && abs(topLeft.y) < eps &&
               abs(topRight.x - 1) < eps && abs(topRight.y) < eps &&
               abs(bottomRight.x - 1) < eps && abs(bottomRight.y - 1) < eps &&
               abs(bottomLeft.x) < eps && abs(bottomLeft.y - 1) < eps &&
               abs(scaleX - 1) < eps && abs(scaleY - 1) < eps &&
               abs(offsetX) < eps && abs(offsetY) < eps
    }
}
