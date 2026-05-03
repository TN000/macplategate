import Foundation
import Vision
import CoreImage
import CoreVideo
import CoreGraphics
import Accelerate

enum PlateOCRReadingOrigin: String, Codable, Equatable {
    case passOneRaw
    case passTwoEnhanced
    case weakTrackletMerged
    case crossValidatedFuzzy
    case crossValidated
}

struct ToneMeta: Codable, Equatable {
    let mean: Float
    let std: Float
    let p05: Float
    let p95: Float
    let darkness: Double
    let upscale: Double
    let backlightFired: Bool
    let source: String

    var payload: [String: Any] {
        [
            "mean": Double(mean),
            "std": Double(std),
            "p05": Double(p05),
            "p95": Double(p95),
            "darkness": darkness,
            "upscale": upscale,
            "backlightFired": backlightFired,
            "source": source
        ]
    }
}

struct PlateOCRReading {
    let text: String
    /// Apple Vision per-observation vrací top-N kandidátů. `text` je top-1 (nejvyšší
    /// conf), `altTexts` nese další (top-2, top-3) pokud jsou neprázdné a odlišné.
    /// Pipeline použije multi-candidate rescue: pokud primary neprojde validátorem,
    /// zkusí alty — foreign/vanity plates často skončí na pozici #2 nebo #3
    /// (např. "B" vs "8" confusion u CZ plate, nebo celé "WOB" vs "W08").
    let altTexts: [String]
    let confidence: Float
    let bbox: CGRect       // pixel coords v native source frame (po inverse rotaci), top-left origin
    let workBox: CGRect    // pixel coords v rotated crop (to co Vision viděl), top-left origin
    let workSize: CGSize   // (workW, workH) — rozměr rotated cropu, pro commit thumbnail reconstruction
    let region: String?
    /// Workspace CGImage (post-ROI, post-rotate, post-perspective, post-detectionQuad)
    /// už rendrovaný pro Vision. Tracker ho dále použije pro stacking composite a
    /// commit crop — workBox je v této workspace souřadnicích, takže crop je
    /// deterministicky správně bez re-transformace raw framu.
    let workspaceImage: CGImage?
    /// Raw workspace jako CIImage PŘED `preprocessForOCR` (contrast stretch +
    /// gamma + unsharp). **Lazy:** držíme CIImage reference (žádný GPU render),
    /// PlatePipeline.commit() renderuje CGImage až při skutečném commit-u. Šetří
    /// ~3 ms / tick per camera pro neuvěřitelné většina OCR ticků co nečastí
    /// do commitu (motion noise, signboards, filtered small-plates).
    let rawWorkspaceImage: CIImage?

    /// Který OCR průchod text vyrobil. Tracker to používá pro vážené hlasování:
    /// pass 1 lokalizuje, pass 2 čte tight enhanced crop.
    let origin: PlateOCRReadingOrigin
    /// True jen pro enhanced čtení, které projde striktní CZ/CZ-EV/SK validací.
    /// Tracker tomu dá absolutní tie-break před běžnou váhou.
    let isStrictValidCz: Bool

    /// Text z **sekundárního OCR engine** (FastPlateOCR ONNX) pro tuto observaci.
    /// Nil pokud secondary nebyl volán nebo nevrátil plausible text. Pokud non-nil,
    /// tracker počítá secondary jako **další hlas** (per-obs 2 votes: vision + secondary)
    /// — implementace majority-vote přes oba enginy, fix pro Vision misread cases
    /// kde secondary konzistentně vrací správný text (např. 4CD3456 → 2CD3456).
    let secondaryText: String?
    /// Confidence sekundárního engine. Default 1.0 (FastPlateOCR vrací implicit
    /// high-conf pro plausible reads). Tracker použije pro vážené hlasování.
    let secondaryConfidence: Float
    /// Plate-local tone metadata for audit analytics. Raw pass-one reads include
    /// measured stats, but `backlightFired` is false unless an enhancement path
    /// actually applied the backlight correction.
    let toneMeta: ToneMeta?

    init(text: String,
         altTexts: [String],
         confidence: Float,
         bbox: CGRect,
         workBox: CGRect,
         workSize: CGSize,
         region: String?,
         workspaceImage: CGImage?,
         rawWorkspaceImage: CIImage?,
         origin: PlateOCRReadingOrigin = .passOneRaw,
         isStrictValidCz: Bool = false,
         secondaryText: String? = nil,
         secondaryConfidence: Float = 1.0,
         toneMeta: ToneMeta? = nil) {
        self.text = text
        self.altTexts = altTexts
        self.confidence = confidence
        self.bbox = bbox
        self.workBox = workBox
        self.workSize = workSize
        self.region = region
        self.workspaceImage = workspaceImage
        self.rawWorkspaceImage = rawWorkspaceImage
        self.origin = origin
        self.isStrictValidCz = isStrictValidCz
        self.secondaryText = secondaryText
        self.secondaryConfidence = secondaryConfidence
        self.toneMeta = toneMeta
    }
}

enum PlateOCR {
    /// Absolutní floor výšky textu v source pixelech (Vision-level filter).
    /// Vision .accurate na M4 ANE rozezná text už od ~10 px výšky. Floor 12 dává
    /// safety margin pro motion blur/jitter, ale umožňuje detekci plate když
    /// auto je dál v frame (rychlé průjezdy = plate menší při prvním detekci).
    private static let minTextHeightPx: CGFloat = 12
    /// Post-Vision filter: bbox každého observation musí být vyšší než tento zlomek
    /// workspace height.
    /// 5 % — empiricky naměřeno u reálných ROI workH ≈ 1000–1200 px, plate znaky
    /// mají 60–90 px výšky (5.5–8 %). 8 % bylo moc přísné, filtrovalo legitimní reads.
    /// 5 % pustí plate (≥ 55 px) a většinu webových textů stále škrtne (které mívají
    /// 2–3 %). Jemnější filter zajistí aspect ratio + max aspect check.
    /// Default hodnota; runtime hodnota přichází jako parametr do `recognize(...)`
    /// z AppState (user-nastavitelné v horním banneru).
    private static let defaultMinObsHeightFraction: CGFloat = 0.05
    /// Post-Vision aspect filter.
    private static let maxObsAspect: CGFloat = 15.0
    /// Minimální workW/H pro Vision vstup — pod tím Vision ztrácí přesnost, zvlášť
    /// u stylizovaných fontů (foreign plates). Pokud je rotated crop menší, upscalnem
    /// CoreImage scale transformem, Vision tak dostane víc
    /// pixel detailu a čte stabilněji.
    private static let minVisionInputWidth: CGFloat = 800
    private static let maxUpscaleFactor: CGFloat = 2.5
    /// Kolik top kandidátů vzít z každé Vision observation pro rescue.
    private static let topCandidateCount: Int = 3

    private static var sharedCIContext: CIContext { SharedCIContext.shared }

    /// OCR preprocessing — robustní jas/kontrast pro low-resolution 2.8mm plates.
    ///
    /// **Pipeline:** histogram luminance → mean/std + p5/p95 → jemný EV posun
    /// k midgray + kontrast podle robustního rozsahu. Min/max stretch a agresivní
    /// gamma jsou záměrně pryč: jedna reflexe nebo tmavý rámeček nesmí přepálit
    /// celý crop. Unsharp běží jen u opravdu nízkého kontrastu.
    ///
    /// Skipped pro crops <100 px (Vision dostane raw — na malých cropech halo noise).
    /// Public wrapper pro preprocessForOCR — použito v PlatePipeline fallback
    /// reconstruction path, aby snapshot matchl OCR pipeline stejně jako fast path.
    /// Vrátí jen enhanced crop kolem plate (bez kompozice zpět do workspace).
    /// Použito pro snapshot photo: snapshot ukáže přesně to, co Vision vidí v
    /// pass 2 (`tightEnhancedRetry`) — adaptive tone + conservative bicubic
    /// upscale pro malé tight cropy + jemný/žádný unsharp. Žádný kontext kolem
    /// plate, jen ten výřez.
    /// Pokud crop je menší než guard threshold (30×12), vrátí nil → caller
    /// může fallbacknout na plný workspace.
    static func enhancedCropForSnapshot(workspace: CGImage, plateBoxTL: CGRect, workSize: CGSize) -> CGImage? {
        guard plateBoxTL.width >= 30, plateBoxTL.height >= 12 else { return nil }
        let workspaceCI = CIImage(cgImage: workspace)
        let pxW = CGFloat(workspace.width)
        let pxH = CGFloat(workspace.height)
        // Scale plateBox z workSize coords (kde Vision normalized bbox byl
        // promítnut) do skutečných CGImage pixel coords. Pro downscaled
        // workspace ratio < 1.0.
        let sx: CGFloat = workSize.width > 0 ? pxW / workSize.width : 1.0
        let sy: CGFloat = workSize.height > 0 ? pxH / workSize.height : 1.0
        let scaledBoxTL = CGRect(
            x: plateBoxTL.minX * sx,
            y: plateBoxTL.minY * sy,
            width: plateBoxTL.width * sx,
            height: plateBoxTL.height * sy
        )
        // 8 px pad kolem plate, then BL-flip pro CIImage coords.
        let pad: CGFloat = 8
        let cropRectBL = CGRect(
            x: max(0, scaledBoxTL.minX - pad),
            y: max(0, pxH - scaledBoxTL.maxY - pad),
            width: min(pxW, scaledBoxTL.width + 2 * pad),
            height: min(pxH, scaledBoxTL.height + 2 * pad)
        ).intersection(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        guard cropRectBL.width >= 30, cropRectBL.height >= 12 else { return nil }

        var enhanced = workspaceCI.cropped(to: cropRectBL)
            .transformed(by: CGAffineTransform(translationX: -cropRectBL.minX, y: -cropRectBL.minY))

        enhanced = denoiseForPlateUpscaleIfNeeded(enhanced, sourceHeight: cropRectBL.height)

        let extent = CGRect(x: 0, y: 0, width: cropRectBL.width, height: cropRectBL.height)

        // **Auto white balance:** PRVNÍ krok chain — eliminuje modrofialový cast
        // (camera WB / sensor IR cut filter bias). Bez něj by adaptive tone
        // amplifikoval cast do final output.
        enhanced = applyGrayWorldWhiteBalance(enhanced, extent: extent)

        // **Backlight pre-pass:** pokud scene tmavá (mean < 0.32), aplikuj
        // HighlightShadowAdjust + ExposureAdjust + Contrast PŘED standard
        // adaptive tone. Plate v hluboké stínu se zviditelní bez přepálení
        // světlometů. Skip pro normálně osvětlené plates.
        if let preStats = measureLumaStats(enhanced, extent: extent) {
            enhanced = applyBacklightCorrectionIfNeeded(enhanced, stats: preStats)
        }

        // Stejná tone enhancement chain jako tightEnhancedRetry — luma stats
        // na crop, adaptive gamma + brightness/contrast. Měřeno znova
        // protože backlight pass mohl změnit luminance distribuci.
        if let stats = measureLumaStats(enhanced, extent: extent),
           let toned = applyAdaptiveEnhancement(enhanced, stats: stats) {
            enhanced = toned
        }

        // **Plate super-resolution (Swin2SR):** pokud master toggle a snapshot
        // branch ON, zkusíme ML 4× upscale místo classical Lanczos.
        // Snapshot path je default ON, ale engine sám vrátí .skipped pokud crop
        // nesplňuje policy gates (too small, low conf, already sharp atd.) →
        // fallback na existing Lanczos chain.
        let cropTL = CGRect(x: 0, y: 0, width: cropRectBL.width, height: cropRectBL.height)
        let masterEnabled = AppState.usePlateSuperResolutionFlag.withLock { $0 }
        let snapshotEnabled = AppState.usePlateSRForSnapshotsFlag.withLock { $0 }
        if masterEnabled, snapshotEnabled,
           let snapshotCG = sharedCIContext.createCGImage(enhanced, from: extent) {
            let policyDecision = PlateSRPolicy.decide(
                crop: snapshotCG,
                purpose: .snapshot,
                metadata: PlateCropMetadata(
                    cameraID: "snapshot",
                    trackID: nil,
                    cropRect: cropRectBL,
                    detectionConfidence: 1.0
                ),
                userMasterEnabled: true,  // already gated above
                userPurposeEnabled: true
            )
            if policyDecision.shouldApply {
                let result = PlateSREngine.shared.upscale4x(
                    snapshotCG, purpose: .snapshot,
                    metadata: PlateCropMetadata(
                        cameraID: "snapshot", trackID: nil,
                        cropRect: cropRectBL, detectionConfidence: 1.0
                    )
                )
                if case .applied(let srCG, _) = result {
                    // Post-SR tone enhancement: adaptive gamma (target luma mean 0.45),
                    // S-curve mid-contrast boost, bilateral denoise (edges preserved),
                    // micro-unsharp pro detail recovery. Targets low-contrast aged
                    // plates, JPEG-like SR artefakty, weak character edges.
                    return applyPostSREnhancement(srCG) ?? srCG
                }
            } else if let reason = policyDecision.reason {
                Audit.event("super_resolution_skipped", [
                    "purpose": "snapshot",
                    "reason": reason.rawValue,
                ])
            }
        }

        // Snapshot path je konzervativnější než OCR retry: max 2× a plynulý
        // target-height scale. Tím se potlačí halo/ringing v uložených cropech.
        let upscale = snapshotUpscaleFactor(for: cropTL)
        enhanced = scalePlateCrop(enhanced, factor: upscale)

        // Tiny crops už prošly denoise + bicubic; další sharpen by znovu kreslil
        // halo a blokový šum. Větším cropům stačí jemnější unsharp.
        if cropRectBL.height >= 50, let sharpen = CIFilter(name: "CIUnsharpMask") {
            sharpen.setValue(enhanced, forKey: kCIInputImageKey)
            sharpen.setValue(1.0, forKey: kCIInputRadiusKey)
            sharpen.setValue(0.2, forKey: kCIInputIntensityKey)
            enhanced = sharpen.outputImage ?? enhanced
        }

        let outRect = CGRect(x: 0, y: 0, width: cropRectBL.width * upscale, height: cropRectBL.height * upscale)
        guard let scaledCG = sharedCIContext.createCGImage(enhanced, from: outRect) else {
            return nil
        }
        // Post-tone enhancement i v Plan B path (bez SR): adaptive gamma + S-curve
        // + edge-preserving denoise + micro-unsharp. Targets žlutý/teplý cast
        // a slabý kontrast — AWB sám eliminuje barevný cast, ale luma distribution
        // stále potřebuje gamma lift + S-curve mid-contrast.
        return applyPostSREnhancement(scaledCG) ?? scaledCG
    }

    /// Vyrenderuje kopii `cg` se exclusion-mask obdélníky vyplněnými neutrální
    /// střední šedou. Vstup je TL-origin normalized [0,1] mask (CGRect.origin
    /// je TL roh, size je w×h) — interně se převede na BL-origin pixel rect
    /// (CGContext default coord systém).
    /// Šedá místo černé záměrně — sharp black/white kontrastní edge by Vision
    /// občas misread jako text. Solid mid-gray = no edge = no detection.
    static func paintMasksOver(_ cg: CGImage, masks: [CGRect]) -> CGImage {
        let w = cg.width, h = cg.height
        let cs = cg.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: bitmapInfo) else {
            return cg
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1.0))
        let pxW = CGFloat(w), pxH = CGFloat(h)
        for m in masks {
            // TL-origin → BL-origin (CGContext y-axis is bottom-up).
            let yBL = (1.0 - m.origin.y - m.size.height) * pxH
            let rect = CGRect(x: m.origin.x * pxW, y: yBL,
                              width: m.size.width * pxW,
                              height: m.size.height * pxH)
            ctx.fill(rect)
        }
        return ctx.makeImage() ?? cg
    }

    static func applyOCRPreprocess(_ image: CIImage) -> CIImage {
        preprocessForOCR(image)
    }

    /// Composite plate-region enhanced (gamma + contrast + unsharp) zpět do
    /// workspace snapshotu. Volá PlatePipeline.commit() PŘED uložením `.heic`.
    /// `plateBoxTL` je bbox plate v workspace coords (TL origin) — z `track.bestWorkBox`.
    /// `workSize` je dimenze workspace ve které byl plateBox naměřen — `workspace`
    /// CGImage může být downscalovaný (`renderForVisionWithRaw` snižuje 604px+
    /// výšku na 500px), takže plateBox musíme pomocí ratio scale přepočítat na
    /// CGImage pixel coords. Bez toho se enhancement region kreslí nad/pod
    /// skutečnou plate (systematický offset).
    ///
    /// Použité tone params shodné s tightEnhancedRetry (robustní p5/p95 luma
    /// stats → jemný EV posun + kontrast podle plate-local rozsahu). Border
    /// feather 5px aby hrana plate-region neukázala viditelný step.
    static func compositeEnhancedPlateInSnapshot(workspace: CGImage, plateBoxTL: CGRect, workSize: CGSize) -> CGImage? {
        guard plateBoxTL.width >= 30, plateBoxTL.height >= 12 else { return workspace }
        let workspaceCI = CIImage(cgImage: workspace)
        let pxW = CGFloat(workspace.width)
        let pxH = CGFloat(workspace.height)
        // Scale plateBox z workSize coords (kde Vision normalized bbox byl
        // promítnut — line 772-777 recognize) do skutečných CGImage pixel coords.
        // Pro ne-downscaled workspace ratio = 1.0, pro downscaled (1474×604 →
        // 1220×500) ratio ≈ 0.83. Bez scale-fix box by ležel cca 17 % nad plate.
        let sx: CGFloat = workSize.width > 0 ? pxW / workSize.width : 1.0
        let sy: CGFloat = workSize.height > 0 ? pxH / workSize.height : 1.0
        let scaledBoxTL = CGRect(
            x: plateBoxTL.minX * sx,
            y: plateBoxTL.minY * sy,
            width: plateBoxTL.width * sx,
            height: plateBoxTL.height * sy
        )
        // workBox je TL origin (top-left), CIImage je BL — flip Y.
        let pad: CGFloat = 8
        let plateRectBL = CGRect(
            x: max(0, scaledBoxTL.minX - pad),
            y: max(0, pxH - scaledBoxTL.maxY - pad),
            width: min(pxW, scaledBoxTL.width + 2 * pad),
            height: min(pxH, scaledBoxTL.height + 2 * pad)
        ).intersection(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        guard plateRectBL.width >= 30, plateRectBL.height >= 12 else { return workspace }
        // Crop, enhance, translate back to plate position.
        var enhanced = workspaceCI.cropped(to: plateRectBL)
            .transformed(by: CGAffineTransform(translationX: -plateRectBL.minX, y: -plateRectBL.minY))
        enhanced = denoiseForPlateUpscaleIfNeeded(enhanced, sourceHeight: plateRectBL.height)
        let extent = CGRect(x: 0, y: 0, width: plateRectBL.width, height: plateRectBL.height)
        if let stats = measureLumaStats(enhanced, extent: extent),
           let toned = applyAdaptiveEnhancement(enhanced, stats: stats) {
            enhanced = toned
        }
        if plateRectBL.height >= 50, let sharpen = CIFilter(name: "CIUnsharpMask") {
            sharpen.setValue(enhanced, forKey: kCIInputImageKey)
            sharpen.setValue(1.0, forKey: kCIInputRadiusKey)
            sharpen.setValue(0.18, forKey: kCIInputIntensityKey)
            enhanced = sharpen.outputImage ?? enhanced
        }
        // Composite: enhanced (na původní pozici) over workspace
        let positioned = enhanced.transformed(by: CGAffineTransform(translationX: plateRectBL.minX, y: plateRectBL.minY))
        let composite = positioned.composited(over: workspaceCI)
        let workspaceRect = CGRect(x: 0, y: 0, width: pxW, height: pxH)
        return sharedCIContext.createCGImage(composite, from: workspaceRect)
    }

    /// Adaptive tone pass 2 OCR — re-Vision na enhanced plate-region crop.
    ///
    /// **Pipeline:**
    /// 1. Crop visionCI na plateRect (bbox z pass 1 + 5px pad).
    /// 2. measureLumaStats na TÉTO PLATE-LOCAL oblasti (nikoliv whole workspace).
    /// 3. Apply robustní EV/contrast podle p5/p95 local stats.
    /// 4. Render CGImage + VNRecognizeTextRequest.
    /// 5. Vrátí top-1 result (text + confidence) nebo nil.
    ///
    /// Per-plate adaptive lighting eliminuje problém že whole-frame mean/range
    /// "absorbuje" plate-local stats v rámci dark-hood + bright-grass scén.
    private static func adaptiveTonePass2OCR(
        visionCI: CIImage,
        plateRect: CGRect,
        customWords: [String]
    ) -> (text: String, confidence: Float, toneMeta: ToneMeta)? {
        // Crop CIImage na plate region (BL coords). Translate to origin.
        var enhanced = visionCI.cropped(to: plateRect)
            .transformed(by: CGAffineTransform(translationX: -plateRect.minX, y: -plateRect.minY))
        enhanced = denoiseForPlateUpscaleIfNeeded(enhanced, sourceHeight: plateRect.height)
        let extent = CGRect(origin: .zero, size: plateRect.size)
        // Auto white balance PŘED tone passes — eliminuje color cast do Vision OCR.
        enhanced = applyGrayWorldWhiteBalance(enhanced, extent: extent)
        // Backlight pre-pass — tmavá scéna (mean < 0.32) aktivuje shadow lift
        // + highlight compress. Vision OCR pak dostane stabilnější input.
        var toneMeta: ToneMeta?
        if let preStats = measureLumaStats(enhanced, extent: extent) {
            let darkness = backlightDarkness(for: preStats)
            enhanced = applyBacklightCorrectionIfNeeded(enhanced, stats: preStats)
            toneMeta = ToneMeta(
                mean: preStats.mean,
                std: preStats.std,
                p05: preStats.p05,
                p95: preStats.p95,
                darkness: darkness,
                upscale: Double(ocrUpscaleFactor(forSourceHeight: plateRect.height)),
                backlightFired: darkness > 0.10,
                source: "adaptiveTonePass2OCR"
            )
        }
        if let stats = measureLumaStats(enhanced, extent: extent),
           let toned = applyAdaptiveEnhancement(enhanced, stats: stats) {
            enhanced = toned
        }
        let upscale = ocrUpscaleFactor(forSourceHeight: plateRect.height)
        let renderSize = CGSize(width: plateRect.width * upscale, height: plateRect.height * upscale)
        if upscale > 1.0 {
            enhanced = scalePlateCrop(enhanced, factor: upscale)
        }
        let renderRect = CGRect(origin: .zero, size: renderSize)
        guard let cg = sharedCIContext.createCGImage(enhanced, from: renderRect) else { return nil }
        // Vision pass 2 na enhanced crop.
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false
        req.recognitionLanguages = []
        if !customWords.isEmpty { req.customWords = Array(customWords.prefix(50)) }
        // Min text height relative to rendered crop; upscale lowers this ratio
        // intentionally so distant plates do not vanish on the second read.
        req.minimumTextHeight = max(Float(minTextHeightPx / renderSize.height), 0.02)
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([req]) } catch { return nil }
        guard let results = req.results, let obs = results.first,
              let top = obs.topCandidates(1).first else { return nil }
        return (top.string, top.confidence, toneMeta ?? ToneMeta(
            mean: 0, std: 0, p05: 0, p95: 0,
            darkness: 0,
            upscale: Double(ocrUpscaleFactor(forSourceHeight: plateRect.height)),
            backlightFired: false,
            source: "adaptiveTonePass2OCR"
        ))
    }

    private static func preprocessForOCR(_ image: CIImage) -> CIImage {
        guard image.extent.width >= 100 else { return image }

        var processed = image
        if let stats = measureLumaStats(image, extent: image.extent) {
            AppState.devLog("PlateOCR.preprocess: \(Int(image.extent.width))×\(Int(image.extent.height)) mean=\(String(format: "%.2f", stats.mean)) std=\(String(format: "%.2f", stats.std)) p05=\(String(format: "%.2f", stats.p05)) p95=\(String(format: "%.2f", stats.p95))")
            if let enhanced = applyAdaptiveEnhancement(processed, stats: stats) {
                processed = enhanced
            }
        }
        return processed
    }

    /// Vision OCR. Pokud je `roiInPixels` set, manuálně CROPNEME pixel buffer na ROI
    /// a předáme Vision jen tu oblast.
    ///
    /// `customWords` — seznam known plates jako hint pro Vision language model.
    /// Boost probability těchto sekvencí → lepší recognition repeat plates.
    static func recognize(in pixelBuffer: CVPixelBuffer,
                          roiInPixels: CGRect? = nil,
                          rotationRadians: CGFloat = 0,
                          perspective: PerspectiveConfig? = nil,
                          detectionQuad: [CGPoint]? = nil,
                          exclusionMasks: [CGRect] = [],
                          perspectiveCalibration: PerspectiveCalibration? = nil,
                          customWords: [String] = [],
                          minObsHeightFraction: CGFloat = defaultMinObsHeightFraction,
                          fastMode: Bool = false,
                          dualPass: Bool = false,
                          enhancedRetryEnabled: Bool = true,
                          enhancedRetryThreshold: Float = 0.95,
                          maxRetryBoxes: Int = 2,
                          auditCamera: String? = nil,
                          auditFrameIdx: Int? = nil) -> [PlateOCRReading] {
        let signpost = SPZSignposts.signposter.beginInterval(SPZSignposts.Name.visionOCR)
        defer { SPZSignposts.signposter.endInterval(SPZSignposts.Name.visionOCR, signpost) }
        return autoreleasepool { () -> [PlateOCRReading] in
            recognizeImpl(in: pixelBuffer, roiInPixels: roiInPixels,
                          rotationRadians: rotationRadians,
                          perspective: perspective,
                          detectionQuad: detectionQuad,
                          exclusionMasks: exclusionMasks,
                          perspectiveCalibration: perspectiveCalibration,
                          customWords: customWords,
                          minObsHeightFraction: minObsHeightFraction,
                          fastMode: fastMode,
                          dualPass: dualPass,
                          enhancedRetryEnabled: enhancedRetryEnabled,
                          enhancedRetryThreshold: enhancedRetryThreshold,
                          maxRetryBoxes: maxRetryBoxes,
                          auditCamera: auditCamera,
                          auditFrameIdx: auditFrameIdx)
        }
    }

    private static func recognizeImpl(in pixelBuffer: CVPixelBuffer,
                                      roiInPixels: CGRect? = nil,
                                      rotationRadians: CGFloat = 0,
                                      perspective: PerspectiveConfig? = nil,
                                      detectionQuad: [CGPoint]? = nil,
                                      exclusionMasks: [CGRect] = [],
                                      perspectiveCalibration: PerspectiveCalibration? = nil,
                                      customWords: [String] = [],
                                      minObsHeightFraction: CGFloat = defaultMinObsHeightFraction,
                                      fastMode: Bool = false,
                                      dualPass: Bool = false,
                                      enhancedRetryEnabled: Bool = true,
                                      enhancedRetryThreshold: Float = 0.95,
                                      maxRetryBoxes: Int = 2,
                                      auditCamera: String? = nil,
                                      auditFrameIdx: Int? = nil) -> [PlateOCRReading] {
        let imgW = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let imgH = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        guard imgW > 0, imgH > 0 else { return [] }

        // workW/workH je ORIGINAL rotated-crop velikost (používá se pro bbox mapping
        // do source frame i pro output workBox). Pro Vision dodáme potenciálně
        // UPSCALED obraz — Vision bounding boxy jsou normalized [0,1], takže
        // násobení originálními workW/workH dá workBox v původních souřadnicích.
        // Při aktivní perspektivní korekci se workW/workH přepíší na výstupní
        // rozměr corrected image a mapBBox zjednoduší na ROI rect.
        var workW: CGFloat = 0
        var workH: CGFloat = 0
        let visionInputImage: CGImage
        /// Raw workspace CIImage (pre-preprocess). Lazy reference — CGImage se
        /// rendruje až v PlatePipeline.commit().
        var rawWorkspaceCI: CIImage? = nil
        var mapBBox: (CGRect) -> CGRect = { _ in .zero }
        // Post-quad / post-rotate / post-perspective CIImage, referenční pro
        // tight-crop enhanced retry. V obou větvích (ROI-path i full-image) se
        // nastaví před Vision call, aby druhý průchod mohl ořezat přímo z ní.
        var sourceForRetry: CIImage? = nil

        // Metal fast-path — fúzuje ROI crop + rotace + detectionQuad do jednoho
        // Metal compute dispatch místo 3-4 CIImage passů. Gated AppState.useMetalKernel
        // (default false). Fallback na CI chain pokud perspective non-identity,
        // ROI je nil, nebo kernel selže.
        var metalFastPath: CGImage? = nil
        if AppState.useMetalKernelFlag.withLock({ $0 }),
           let roi = roiInPixels,
           (perspective?.isIdentity ?? true),
           let kernel = PlateTransformKernel.shared {
            let clamped = roi.intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))
            if !clamped.isNull, clamped.width >= 32, clamped.height >= 16 {
                let cosT = abs(cos(rotationRadians))
                let sinT = abs(sin(rotationRadians))
                let rotW = clamped.width * cosT + clamped.height * sinT
                let rotH = clamped.width * sinT + clamped.height * cosT
                var outW = rotW, outH = rotH
                if let dq = detectionQuad, dq.count == 4 {
                    let xs = dq.map { $0.x }, ys = dq.map { $0.y }
                    let nMinX = max(0, min(1, xs.min() ?? 0))
                    let nMaxX = max(0, min(1, xs.max() ?? 1))
                    let nMinY = max(0, min(1, ys.min() ?? 0))
                    let nMaxY = max(0, min(1, ys.max() ?? 1))
                    let isFull = nMinX < 0.01 && nMaxX > 0.99 && nMinY < 0.01 && nMaxY > 0.99
                    if !isFull, nMaxX > nMinX + 0.02, nMaxY > nMinY + 0.02 {
                        outW = (nMaxX - nMinX) * rotW
                        outH = (nMaxY - nMinY) * rotH
                    }
                }
                if outW >= 32, outH >= 16,
                   let H = PlateTransformHomography.compose(
                       roi: clamped,
                       rotationRadians: rotationRadians,
                       perspectiveIsIdentity: true,
                       detectionQuadNormalized: detectionQuad,
                       workspaceSize: CGSize(width: rotW, height: rotH),
                       outputSize: CGSize(width: outW, height: outH)),
                   let cg = kernel.transform(
                       pixelBuffer: pixelBuffer, homography: H,
                       outputSize: (width: Int(outW.rounded()), height: Int(outH.rounded()))),
                   let rendered = renderForVision(CIImage(cgImage: cg), origW: outW, origH: outH) {
                    workW = outW; workH = outH
                    let roiRect = clamped
                    mapBBox = { _ in roiRect }
                    sourceForRetry = CIImage(cgImage: cg)
                    metalFastPath = rendered
                }
            }
        }

        if let mfp = metalFastPath {
            visionInputImage = mfp
        } else if let roi = roiInPixels {
            let clamped = roi.intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))
            guard !clamped.isNull, clamped.width >= 32, clamped.height >= 16 else { return [] }
            let cropW = clamped.width, cropH = clamped.height
            let ci = CIImage(cvPixelBuffer: pixelBuffer)
            let ciRect = CGRect(x: clamped.minX, y: imgH - clamped.maxY, width: cropW, height: cropH)
            var cropped = ci.cropped(to: ciRect)
                .transformed(by: CGAffineTransform(translationX: -ciRect.minX, y: -ciRect.minY))

            if abs(rotationRadians) < 0.001 {
                // No rotation path.
                workW = cropW; workH = cropH
                let offX = clamped.minX, offY = clamped.minY
                mapBBox = { nbb in
                    CGRect(
                        x: offX + nbb.origin.x * workW,
                        y: offY + (1.0 - nbb.origin.y - nbb.size.height) * workH,
                        width: nbb.size.width * workW,
                        height: nbb.size.height * workH
                    )
                }
            } else {
                let cx = cropW / 2, cy = cropH / 2
                let t = CGAffineTransform(translationX: -cx, y: -cy)
                    .concatenating(CGAffineTransform(rotationAngle: rotationRadians))
                cropped = cropped.transformed(by: t)
                let rotExtent = cropped.extent
                cropped = cropped.transformed(by: CGAffineTransform(translationX: -rotExtent.minX, y: -rotExtent.minY))
                let rotW = rotExtent.width, rotH = rotExtent.height
                workW = rotW; workH = rotH
                let offX = clamped.minX, offY = clamped.minY
                let cs = cos(-rotationRadians), sn = sin(-rotationRadians)
                let halfRW = rotW / 2, halfRH = rotH / 2
                let halfCW = cropW / 2, halfCH = cropH / 2
                mapBBox = { nbb in
                    let px = nbb.origin.x * rotW
                    let py = (1.0 - nbb.origin.y - nbb.size.height) * rotH
                    let pw = nbb.size.width * rotW
                    let ph = nbb.size.height * rotH
                    let corners = [
                        CGPoint(x: px, y: py),
                        CGPoint(x: px + pw, y: py),
                        CGPoint(x: px + pw, y: py + ph),
                        CGPoint(x: px, y: py + ph),
                    ]
                    var minX = CGFloat.infinity, minY = CGFloat.infinity
                    var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
                    for c in corners {
                        let dx = c.x - halfRW
                        let dy = c.y - halfRH
                        let ox = cs * dx - sn * dy + halfCW + offX
                        let oy = sn * dx + cs * dy + halfCH + offY
                        if ox < minX { minX = ox }; if ox > maxX { maxX = ox }
                        if oy < minY { minY = oy }; if oy > maxY { maxY = oy }
                    }
                    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                }
            }

            // Perspektivní korekce — user-drawn z ROI editoru. (AutoPerspective
            // přes VNDetectRectangles měla 100% skip rate na user cameras
            // a byla redundantní s detectionQuad.)
            if let pc = perspective, !pc.isIdentity {
                if let corrected = applyPerspective(cropped, width: workW, height: workH, perspective: pc) {
                    cropped = corrected
                    workW = corrected.extent.width
                    workH = corrected.extent.height
                    let roiRect = clamped
                    mapBBox = { _ in roiRect }
                }
            }

            // 8-DOF interaktivní kalibrace — POSLEDNÍ ve stacku (po rotaci +
            // existing perspective). Source/destination quady jsou normalized
            // [0,1] TL-origin → konvert do CIImage BL-origin pixel coords.
            // Po homografii aplikuj scale (kolem středu) + translaci ze sliderů.
            if let calib = perspectiveCalibration,
               calib.sourceQuad.count == 4, calib.destinationQuad.count == 4 {
                let toCi = { (p: CGPoint) -> CGPoint in
                    CGPoint(x: p.x * workW, y: (1 - p.y) * workH)
                }
                let src = calib.sourceQuad.map(toCi)
                let dst = calib.destinationQuad.map(toCi)
                if let warped = PerspectiveTransform.apply(cropped, source: src, destination: dst) {
                    let cx = workW / 2, cy = workH / 2
                    let sx = CGFloat(max(0.05, calib.scaleX))
                    let sy = CGFloat(max(0.05, calib.scaleY))
                    let tx = CGFloat(calib.offsetX) * workW
                    let ty = -CGFloat(calib.offsetY) * workH
                    let affine = CGAffineTransform(translationX: -cx, y: -cy)
                        .concatenating(CGAffineTransform(scaleX: sx, y: sy))
                        .concatenating(CGAffineTransform(translationX: cx + tx, y: cy + ty))
                    let transformed = warped.transformed(by: affine)
                    let outRect = CGRect(x: 0, y: 0, width: workW, height: workH)
                    cropped = transformed.cropped(to: outRect)
                    // Translate cropped extent zpět na origin (jako
                    // RoiTransformRenderer.applyPerspectiveCalibration dělá).
                    // Bez toho `cropped.extent.origin != (0,0)` → Vision normalized
                    // bbox * workH dává pixel coords s offsetem oproti display
                    // workspace → bbox overlay misplaced.
                    let ext = cropped.extent
                    if abs(ext.minX) > 0.001 || abs(ext.minY) > 0.001 {
                        cropped = cropped.transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
                    }
                    workW = cropped.extent.width
                    workH = cropped.extent.height
                }
            }

            // Detection quad — crop do axis-aligned bboxu uvnitř corrected ROI.
            // OCR poběží jen v této oblasti (uspora CPU + snížení false-positives
            // z okolí plate). Default nil = bez omezení.
            if let dq = detectionQuad, dq.count == 4 {
                let xs = dq.map { $0.x }, ys = dq.map { $0.y }
                let nMinX = max(0, min(1, xs.min() ?? 0))
                let nMaxX = max(0, min(1, xs.max() ?? 1))
                let nMinY = max(0, min(1, ys.min() ?? 0))
                let nMaxY = max(0, min(1, ys.max() ?? 1))
                // Skip pokud quad ≈ full ROI (žádný efekt).
                let isFull = nMinX < 0.01 && nMaxX > 0.99 && nMinY < 0.01 && nMaxY > 0.99
                if !isFull, nMaxX > nMinX + 0.02, nMaxY > nMinY + 0.02 {
                    // Normalized TL → pixel BL.
                    let pxMinX = nMinX * workW
                    let pxMaxX = nMaxX * workW
                    let pxMinYBL = (1 - nMaxY) * workH  // nMaxY (bottom in TL) → low Y in BL
                    let pxMaxYBL = (1 - nMinY) * workH
                    let cropRect = CGRect(x: pxMinX, y: pxMinYBL,
                                          width: pxMaxX - pxMinX,
                                          height: pxMaxYBL - pxMinYBL)
                    cropped = cropped.cropped(to: cropRect)
                        .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
                    workW = cropRect.width
                    workH = cropRect.height
                }
            }

            // Perf safety: pokud workspace je velmi široký (> 1800 px) a už **není
            // plate-shape** (aspect < 3 — takže má významnou non-plate vertikální
            // oblast), downscale pro rychlejší Vision. Žádný destruktivní crop —
            // Vision musí vidět celou ROI protože plate může být kdekoli vertikálně
            // (kapota / nárazník / čelní sklo při kamera-výše záběru).
            //
            // Tight-crop (bottom-N%) jsme zkoušeli, ale řezal skrz plate v
            // plate-shape workspacech (aspect ≥ 3 → plate plní skoro celou výšku).
            // Vision na 1642×391 běží 15-30 ms — downscale stačí.
            let workAspect = workW / max(workH, 1)
            if workW > 1800 && workAspect < 3.0 {
                let scale: CGFloat = 1800.0 / workW
                cropped = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let newExt = cropped.extent
                workW = newExt.width
                workH = newExt.height
                AppState.devLog("PlateOCR.perf: large non-plate workspace, downscale → \(Int(workW))×\(Int(workH))")
            }

            // Adaptive světelná normalizace se NEAPLIKUJE na post-quad crop —
            // korekce na celý quad zesílila by i okolní nápisy (VCHOD, FASE)
            // a Vision by je mylně četla jako plate. Místo toho se filter
            // aplikuje až v druhém Vision průchodu na tight bbox + 8px pad,
            // pokud první průchod má confidence < 0.85 (raw-first strategy).
            sourceForRetry = cropped
            let pair = renderForVisionWithRaw(cropped, origW: workW, origH: workH)
            guard let cg = pair.processed else { return [] }
            visionInputImage = cg
            rawWorkspaceCI = pair.raw
        } else {
            // Full image path — Vision dostane celý frame.
            workW = imgW; workH = imgH
            mapBBox = { nbb in
                CGRect(
                    x: nbb.origin.x * imgW,
                    y: (1.0 - nbb.origin.y - nbb.size.height) * imgH,
                    width: nbb.size.width * imgW,
                    height: nbb.size.height * imgH
                )
            }
            let ci = CIImage(cvPixelBuffer: pixelBuffer)
            sourceForRetry = ci
            let pair = renderForVisionWithRaw(ci, origW: imgW, origH: imgH)
            guard let cg = pair.processed else { return [] }
            visionInputImage = cg
            rawWorkspaceCI = pair.raw
        }

        // **Pre-Vision mask paint:** exclusion masky aplikujeme PŘED Vision
        // request, ne až po. Vision tu plochu vůbec neuvidí → žádný OCR na
        // statický signboard text → úspora ANE času + clean dev log.
        // Downstream mask check zůstává jako safety-net pro corner cases.
        let cgForVision: CGImage = exclusionMasks.isEmpty
            ? visionInputImage
            : Self.paintMasksOver(visionInputImage, masks: exclusionMasks)

        let handler = VNImageRequestHandler(cgImage: cgForVision, options: [:])

        let request = VNRecognizeTextRequest()
        // `.fast` režim = ~2× rychlejší ANE inference (~60 ms vs ~140 ms na M4),
        // ale ~10–15 % nižší accuracy na stylizovaných plate fontech. Pro clean
        // situace (dobré světlo, rovná plate) prakticky nerozeznatelné od .accurate;
        // pro dirty/tilted mírně horší. User toggle v Settings → Detekce.
        request.recognitionLevel = fastMode ? .fast : .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = []
        if !customWords.isEmpty {
            // Known plates + top-history jako Vision language-model hint. Boost
            // pravděpodobnost těchto sekvencí → lepší recognition u repeat plates.
            // Max 50 entries — Vision safe limit (testováno: 100 entries blokovalo
            // perform() >5s → pipeline stuck, RTSP watchdog force-reconnect loop).
            request.customWords = Array(customWords.prefix(50))
        }
        request.minimumTextHeight = max(Float(minTextHeightPx / workH), 0.02)

        // Dual-pass: pustí druhý VNRecognizeTextRequest se starší revizí 2.
        // Revision3 (default) a revision2 mají různě trénované modely — občas
        // jedna chytne co druhá miss (rev2 lepší na stylizované fonty, rev3
        // lepší na noisy pozadí). Kombinace observations do tracker voting
        // dává +2–4% accuracy na marginal plates za cenu 2× ANE load.
        // Jen pro .accurate režim — .fast už má nižší accuracy jako cíl.
        var requests: [VNRequest] = [request]
        var req2: VNRecognizeTextRequest? = nil
        if dualPass && !fastMode {
            let r2 = VNRecognizeTextRequest()
            r2.recognitionLevel = .accurate
            // revision2 — deterministický starší model. Apple doc: VNRecognizeTextRequestRevision2
            // je supported na macOS 12+. Každá revize má svoje miss patterns,
            // voting přes obě zvyšuje recall na okrajových case.
            r2.revision = VNRecognizeTextRequestRevision2
            r2.usesLanguageCorrection = false
            r2.recognitionLanguages = []
            if !customWords.isEmpty {
                r2.customWords = Array(customWords.prefix(50))
            }
            r2.minimumTextHeight = request.minimumTextHeight
            requests.append(r2)
            req2 = r2
        }

        let visionT0 = Date()
        do { try handler.perform(requests) } catch {
            AppState.devLog("PlateOCR.Vision: handler.perform threw: \(error)")
            return []
        }
        let visionMs = Date().timeIntervalSince(visionT0) * 1000
        var observations: [VNRecognizedTextObservation] = request.results ?? []
        AppState.devLog("PlateOCR.Vision: obs=\(observations.count) workW=\(Int(workW)) workH=\(Int(workH)) \(String(format: "%.0f", visionMs))ms")
        for (i, obs) in observations.prefix(5).enumerated() {
            if let top = obs.topCandidates(1).first {
                AppState.devLog("  obs[\(i)] text=\"\(top.string)\" conf=\(String(format: "%.2f", top.confidence)) bbox=\(String(format: "%.2f,%.2f %.2f×%.2f", obs.boundingBox.minX, obs.boundingBox.minY, obs.boundingBox.width, obs.boundingBox.height))")
            }
        }
        if let r2 = req2 {
            observations.append(contentsOf: r2.results ?? [])
        }

        // **Adaptive tone pass 2:** pro každou low-conf obs (< 0.85) vyrobíme
        // tight crop kolem její bbox, aplikujeme tone correction založenou na
        // PLATE-LOCAL luminance (mean/range plate-region only — neabsorbuje
        // hood / sky / asphalt) a re-Vision na enhanced crop. Pokud nový conf >
        // original + 0.10 margin, nahradíme top candidate.
        //
        // Triggers jen na ~10–20% obs (low-conf cases). High-conf (1.00) pass 2
        // skipnut. Cost ~20 ms per fired pass; skip-rate 80% → ~4 ms/s extra CPU.
        var enhancedTopByObsIdx: [Int: (text: String, confidence: Float, toneMeta: ToneMeta?)] = [:]
        let visionCI = CIImage(cgImage: visionInputImage)
        let visionPxW = CGFloat(visionInputImage.width)
        let visionPxH = CGFloat(visionInputImage.height)
        // **Trigger gate:** whole-frame preprocess je minimal — odpovědnost
        // za plate-local tone leží zde. Fire ALWAYS pro plausible plate
        // observations (text length 4–11 chars po normalize). Pass 2 měří
        // plate-region luma a aplikuje gamma podle toho — žádný vliv na
        // background. Anti-hallucination L-1 guard zachytí false enhanced text.
        // Signboard substrings — billboard text který víme že není plate. Skip pass 2
        // pro tyto observations (CPU + log noise saving). Match je case-insensitive
        // contains. Stejný seznam by měl být v PlateNormalizer signboard reject —
        // tady jen předbíháme pass 2 stage.
        let signboardSubstrings: [String] = [
            "ZIMN", "STADION", "PRIBR", "PRBR", "PŘÍBR", "VCHOD", "VCHO", "HALY",
            "FASE", "ARMATUR", "ENERGY", "GROUP", "SKUPIN", "NPRBR", "SPZ"
        ]
        for (idx, obs) in observations.enumerated() {
            guard let top1 = obs.topCandidates(1).first else { continue }
            // Plausibility gate: pass 2 jen pro text length 4–11 (před norm) — billboard
            // signs typicky 8+ slov, plates 5–9 chars. Drobný overhead vs filtering noise.
            let textLen = top1.string.unicodeScalars.filter { $0.properties.isAlphabetic || $0.properties.numericType != .none }.count
            guard textLen >= 4 && textLen <= 11 else { continue }
            // Signboard early-reject — nepouštět pass 2 pro známý billboard text.
            let upperText = top1.string.uppercased()
            if signboardSubstrings.contains(where: { upperText.contains($0) }) { continue }
            let bb = obs.boundingBox
            // Bbox normalized [0,1] BL origin → pixel rect BL pro CIImage crop
            let pad: CGFloat = 5
            let bx = bb.origin.x * visionPxW - pad
            let bw = bb.size.width * visionPxW + 2 * pad
            let bh = bb.size.height * visionPxH + 2 * pad
            let by = bb.origin.y * visionPxH - pad
            let rectBL = CGRect(x: max(0, bx),
                                y: max(0, by),
                                width: min(visionPxW - max(0, bx), bw),
                                height: min(visionPxH - max(0, by), bh))
            guard rectBL.width >= 30, rectBL.height >= 12 else { continue }
            if let enhanced = adaptiveTonePass2OCR(
                visionCI: visionCI, plateRect: rectBL, customWords: customWords
            ) {
                // **Anti-hallucination guard:** Vision na enhanced crop často
                // vrátí ÚPLNĚ JINÝ TEXT s conf=1.00 (nikoli lepší čtení původního).
                // Příklad z logu: 'OLE'→'DUE', 'кт 02 colat'→'VOHOO
                // BO HAIY'. Pass 2 hallucinated random words polluted tracker voting.
                //
                // Nový gate: enhanced text musí být SIMILAR (Levenshtein ≤ 2) k pass 1
                // textu A v délce 5–10 znaků (plausible plate length po norm). Jinak
                // ignore — to není enhancement, to je nový text.
                let p1Norm = normalize(top1.string)
                let p2Norm = normalize(enhanced.text)
                // L-1 (Tracker.PlateTrack helper) + retry s 1 char rozdílem délky:
                // pokud délky se liší o 1, zkusit insert/delete.
                let similar = PlateTrack.isL1(p1Norm, p2Norm)
                    || (abs(p1Norm.count - p2Norm.count) == 1
                        && (p1Norm.contains(p2Norm) || p2Norm.contains(p1Norm)))
                let plausibleLen = p2Norm.count >= 5 && p2Norm.count <= 10
                if enhanced.confidence > top1.confidence + 0.10, similar, plausibleLen {
                    enhancedTopByObsIdx[idx] = enhanced
                    AppState.devLog("PlateOCR.adaptiveTone: obs[\(idx)] '\(top1.string)' conf=\(String(format: "%.2f", top1.confidence)) → '\(enhanced.text)' conf=\(String(format: "%.2f", enhanced.confidence))")
                }
            }
        }

        // Multi-candidate expansion — pro každou Vision obs vezmeme top-3 kandidáty,
        // normalizujeme, unique. První je primary `text`, zbytek jde do `altTexts`.
        let minObsH = workH * minObsHeightFraction
        var workItems: [WorkObs] = []
        var filterStats = (small: 0, aspect: 0, empty: 0)
        var rawAuditItems: [RawCandidateAuditItem] = []
        var smallRescueSeeds: [RawCandidate] = []
        func appendRawAudit(text: String, confidence: Float, workBox: CGRect, action: String) {
            let heightFraction = workBox.height / max(workH, 1)
            let aspect = workBox.width / max(workBox.height, 1)
            rawAuditItems.append(RawCandidateAuditItem(text: text,
                                                       confidence: confidence,
                                                       heightFraction: heightFraction,
                                                       aspect: aspect,
                                                       action: action))
        }
        // Fáze 2.1: VNDetectRectanglesRequest pre-filter. Před zařazením text observation
        // do workItems zkontrolujeme, zda její bbox spadá do nějakého plate-shape rectangle
        // (aspect ratio 2.5:1 – 6:1, typical pro EU plates). Pokud kamera vidí nápis
        // "VCHOD" nebo "FASE" nad bránou, Vision ho čte, ale není to rectangle s plate
        // shape → filtrujeme ven.
        //
        // Opt-in via AppState.useRectanglePrefilter. Default OFF — current pipeline
        // funguje dobře i bez, tohle je extra accuracy layer pro noisy backgrounds.
        var plateRects: [CGRect] = []
        if AppState.useRectanglePrefilterFlag.withLock({ $0 }) {
            let rectReq = VNDetectRectanglesRequest()
            rectReq.minimumAspectRatio = 2.5   // EU plate ~4.7:1, být tolerantní
            rectReq.maximumAspectRatio = 7.0
            rectReq.minimumSize = 0.05          // min 5% šířky workspace
            rectReq.maximumObservations = 8
            rectReq.minimumConfidence = 0.5
            try? handler.perform([rectReq])
            if let rects = rectReq.results {
                for r in rects {
                    let b = r.boundingBox
                    plateRects.append(CGRect(
                        x: b.origin.x * workW,
                        y: (1.0 - b.origin.y - b.size.height) * workH,
                        width: b.size.width * workW,
                        height: b.size.height * workH
                    ))
                }
                if plateRects.count > 0 {
                    FileHandle.safeStderrWrite(
                        "[PlateOCR] rect-prefilter: \(plateRects.count) candidates\n"
                            .data(using: .utf8)!)
                }
            }
        }

        for (idx, obs) in observations.enumerated() {
            let nbb = obs.boundingBox
            let wbox = CGRect(
                x: nbb.origin.x * workW,
                y: (1.0 - nbb.origin.y - nbb.size.height) * workH,
                width: nbb.size.width * workW,
                height: nbb.size.height * workH
            )
            let candidates = obs.topCandidates(topCandidateCount)
            guard let top = candidates.first else {
                filterStats.empty += 1
                appendRawAudit(text: "", confidence: 0, workBox: wbox, action: "emptyFiltered")
                continue
            }
            var normSeq: [String] = []
            // Adaptive tone pass 2 winner — pokud nahradil top1, prepend.
            if let enhanced = enhancedTopByObsIdx[idx] {
                let n = normalize(enhanced.text)
                if !n.isEmpty { normSeq.append(n) }
            }
            for c in candidates {
                let n = normalize(c.string)
                if !n.isEmpty && !normSeq.contains(n) { normSeq.append(n) }
            }
            guard let primary = normSeq.first else {
                filterStats.empty += 1
                appendRawAudit(text: top.string, confidence: top.confidence, workBox: wbox,
                               action: "emptyFiltered")
                continue
            }
            let alts = Array(normSeq.dropFirst())
            // Confidence — pokud adaptive-tone fired, použij enhanced conf.
            let effectiveConf: Float = enhancedTopByObsIdx[idx]?.confidence ?? top.confidence
            let toneMeta = enhancedTopByObsIdx[idx]?.toneMeta
                ?? toneMetaForObservation(visionCI: visionCI,
                                          workBoxTL: wbox,
                                          workHeight: workH,
                                          source: "passOneRaw")

            if wbox.height < minObsH {
                filterStats.small += 1
                appendRawAudit(text: primary, confidence: effectiveConf, workBox: wbox,
                               action: "smallFiltered")
                if isUsefulRetrySeedText(primary) {
                    smallRescueSeeds.append(RawCandidate(text: primary,
                                                         altTexts: alts,
                                                         confidence: effectiveConf,
                                                         workBox: wbox))
                    emitSmallCandidateAudit(camera: auditCamera, frameIdx: auditFrameIdx,
                                            text: primary, confidence: effectiveConf,
                                            workBox: wbox, workW: workW, workH: workH)
                }
                continue
            }
            let aspect = wbox.width / max(wbox.height, 1)
            if aspect > maxObsAspect {
                filterStats.aspect += 1
                appendRawAudit(text: primary, confidence: effectiveConf, workBox: wbox,
                               action: "aspectFiltered")
                continue
            }
            // Fáze 2.1: pokud máme rectangle candidates a observation je mimo, skip.
            // `plateRects.isEmpty` = pre-filter nepoužit nebo nenašel rectangles → pass all.
            if !plateRects.isEmpty {
                let centerX = wbox.midX, centerY = wbox.midY
                let inside = plateRects.contains { r in r.contains(CGPoint(x: centerX, y: centerY)) }
                if !inside {
                    filterStats.empty += 1  // reuse empty bucket for "out of plate rect"
                    appendRawAudit(text: primary, confidence: effectiveConf, workBox: wbox,
                                   action: "rectFiltered")
                    continue
                }
            }
            // Exclusion masks — user-drawn rectangles inside ROI kde se má OCR ignorovat.
            // Use case: permanent signboard text (např. "Generic Signboard Text") nad bránou
            // co opakovaně misreads jako fake plate. Mask coords jsou normalized TL-origin
            // [0,1] relative k workspace — po ROI crop + rotate + perspective + quad.
            //
            // **Any-overlap check:** jakýkoli pozitivní overlap mezi obs bbox
            // a mask drop-uje observation. User explicitně označil area jako
            // "no plate possible here" → observation co tam zasahuje je garbage.
            // Threshold based check (50% area / center-only) propouštěl banner
            // observations když user nakreslil jen úzkou masku přes část.
            if !exclusionMasks.isEmpty {
                // `wbox` je už TL-origin pixel coords (BL→TL flip se dělal při
                // tvorbě z Vision normalized bbox). Mask coords jsou TL [0,1]
                // z UI editoru, takže stačí scale na [0,1] bez další flipu.
                let bboxNormTL = CGRect(
                    x: wbox.minX / workW,
                    y: wbox.minY / workH,
                    width: wbox.width / workW,
                    height: wbox.height / workH
                )
                let intersectsAnyMask = exclusionMasks.contains { mask in
                    let inter = bboxNormTL.intersection(mask)
                    return !inter.isNull && !inter.isEmpty
                        && inter.width > 0 && inter.height > 0
                }
                if intersectsAnyMask {
                    filterStats.empty += 1
                    appendRawAudit(text: primary, confidence: effectiveConf, workBox: wbox,
                                   action: "maskFiltered")
                    continue
                }
            }
            appendRawAudit(text: primary, confidence: effectiveConf, workBox: wbox,
                           action: "passed")
            workItems.append(WorkObs(text: primary, altTexts: alts,
                                     confidence: effectiveConf, workBox: wbox,
                                     toneMeta: toneMeta))
        }

        // Small-candidate rescue (zero silent drop phase 1): observations that look
        // plate-like but fail the min-height filter get a synchronous tight enhanced
        // retry before we give up. This keeps tracker continuity for distant plates
        // without relaxing the final commit gates.
        let rescueSource = sourceForRetry ?? CIImage(cvPixelBuffer: pixelBuffer)
        if enhancedRetryEnabled, !smallRescueSeeds.isEmpty, workW > 32, workH > 16 {
            let workspaceRect = CGRect(x: 0, y: 0, width: workW, height: workH)
            let seeds = smallRescueSeeds
                .filter { seed in
                    seed.workBox.height >= 16
                        && seed.workBox.height <= 80
                        && seed.allTexts.contains(where: isUsefulRetrySeedText)
                }
                .sorted {
                    if abs($0.confidence - $1.confidence) > 0.001 {
                        return $0.confidence > $1.confidence
                    }
                    return $0.workBox.height > $1.workBox.height
                }
                .prefix(3)
            for seed in seeds {
                let pad: CGFloat = 12
                let padded = seed.workBox.insetBy(dx: -pad, dy: -pad).intersection(workspaceRect)
                guard !padded.isNull, !padded.isEmpty else { continue }
                let retryItems = Self.tightEnhancedRetry(
                    source: rescueSource,
                    sourceRect: padded,
                    sourceW: workW, sourceH: workH,
                    minObsHeightFraction: minObsHeightFraction,
                    customWords: customWords,
                    exclusionMasks: exclusionMasks,
                    expectedTexts: seed.allTexts
                )
                if auditCamera != nil || auditFrameIdx != nil {
                    Audit.event("small_rescue_attempt", [
                        "camera": auditCamera ?? "",
                        "frame": auditFrameIdx ?? -1,
                        "text": seed.text,
                        "conf": Double(seed.confidence),
                        "h": Double(seed.workBox.height / max(workH, 1)),
                        "rect": [
                            "x": Double(seed.workBox.minX),
                            "y": Double(seed.workBox.minY),
                            "w": Double(seed.workBox.width),
                            "h": Double(seed.workBox.height)
                        ],
                        "yield": retryItems.count,
                        "rescued": retryItems.first?.text ?? ""
                    ])
                }
                workItems.append(contentsOf: retryItems)
            }
        }

        // Enhanced Vision retry — pass 1 lokalizuje textové kandidáty, pass 2 čte
        // tight enhanced výřezy. Nejedeme už jeden union box přes všechny low-conf
        // observations; clusterujeme po Y ose, aby dvě SPZ / signboard+SPZ neslily
        // "tight" crop do půlky scény. Default threshold 0.95 úmyslně zachytí i
        // sebevědomé Vision omyly (0↔3, B↔8, S↔5), ale cap maxRetryBoxes drží ANE load.
        let retryThreshold = min(max(enhancedRetryThreshold, 0.50), 0.99)
        if enhancedRetryEnabled, !workItems.isEmpty, workW > 32, workH > 16 {
            let candidateIndices = workItems.indices.filter { idx in
                let item = workItems[idx]
                let texts = [item.text] + item.altTexts
                if item.confidence < retryThreshold {
                    return texts.contains(where: isUsefulRetrySeedText)
                }
                return texts.contains(where: isPlausiblePlateText)
            }
            if !candidateIndices.isEmpty {
                let source = sourceForRetry ?? CIImage(cvPixelBuffer: pixelBuffer)
                let workspaceRect = CGRect(x: 0, y: 0, width: workW, height: workH)
                let retryGroups = clusterByYAxis(items: workItems, indices: candidateIndices)
                    .sorted { lhs, rhs in
                        let lMin = lhs.map { workItems[$0].confidence }.min() ?? 1
                        let rMin = rhs.map { workItems[$0].confidence }.min() ?? 1
                        if abs(lMin - rMin) > 0.001 { return lMin < rMin }
                        let lArea = lhs.reduce(CGFloat(0)) { $0 + workItems[$1].workBox.width * workItems[$1].workBox.height }
                        let rArea = rhs.reduce(CGFloat(0)) { $0 + workItems[$1].workBox.width * workItems[$1].workBox.height }
                        return lArea > rArea
                    }
                    .prefix(max(0, maxRetryBoxes))
                var allRetryItems: [WorkObs] = []
                for group in retryGroups {
                    guard let firstIdx = group.first else { continue }
                    let union = group.dropFirst().reduce(workItems[firstIdx].workBox) {
                        $0.union(workItems[$1].workBox)
                    }
                    let pad: CGFloat = 12
                    let padded = union.insetBy(dx: -pad, dy: -pad).intersection(workspaceRect)
                    let frac = (padded.width * padded.height) / max(workW * workH, 1)
                    guard !padded.isNull, !padded.isEmpty, frac > 0.003, frac < 0.70 else {
                        continue
                    }
                    let expectedTexts = group.flatMap { idx -> [String] in
                        [workItems[idx].text] + workItems[idx].altTexts
                    }
                    let retryItems = Self.tightEnhancedRetry(
                        source: source,
                        sourceRect: padded,
                        sourceW: workW, sourceH: workH,
                        minObsHeightFraction: minObsHeightFraction,
                        customWords: customWords,
                        exclusionMasks: exclusionMasks,
                        expectedTexts: expectedTexts
                    )
                    let base = expectedTexts.first ?? "-"
                    let enhanced = retryItems.first?.text ?? "nil"
                    AppState.devLog("PlateOCR.retry reason=conf<\(String(format: "%.2f", retryThreshold)) boxes=\(retryGroups.count) base=\(base) enhanced=\(enhanced) rect=\(Int(padded.minX)),\(Int(padded.minY)) \(Int(padded.width))×\(Int(padded.height)) yield=\(retryItems.count)")
                    allRetryItems.append(contentsOf: retryItems)
                }
                workItems.append(contentsOf: allRetryItems)
            }
        }
        emitRawCandidateTickAudit(camera: auditCamera,
                                  frameIdx: auditFrameIdx,
                                  workW: workW,
                                  workH: workH,
                                  rawCount: observations.count,
                                  smallFiltered: filterStats.small,
                                  aspectFiltered: filterStats.aspect,
                                  emptyFiltered: filterStats.empty,
                                  toTracker: workItems.count,
                                  topCandidates: rawAuditItems)

        // Diagnostic log: pokud Vision něco viděl (observations.count > 0) ale
        // všechno bylo odfiltrováno (workItems empty), zaloguj filter breakdown.
        // Critical pro user debugging "tracker viděl plate ale nic necommit".
        if !observations.isEmpty, workItems.isEmpty {
            FileHandle.safeStderrWrite(
                "[PlateOCR] all-filtered obs=\(observations.count) small=\(filterStats.small) aspect=\(filterStats.aspect) empty=\(filterStats.empty)\n"
                    .data(using: .utf8)!)
        }

        let mergedWork = mergeInWorkSpace(workItems)

        let workSize = CGSize(width: workW, height: workH)
        var results: [PlateOCRReading] = []
        for w in mergedWork {
            let nbb = CGRect(
                x: w.workBox.minX / workW,
                y: 1.0 - (w.workBox.minY + w.workBox.height) / workH,
                width: w.workBox.width / workW,
                height: w.workBox.height / workH
            )
            let pixelBox = mapBBox(nbb)
            results.append(PlateOCRReading(text: w.text, altTexts: w.altTexts,
                                           confidence: w.confidence,
                                           bbox: pixelBox, workBox: w.workBox, workSize: workSize,
                                           region: nil,
                                                   workspaceImage: visionInputImage,
                                                   rawWorkspaceImage: rawWorkspaceCI,
                                                   origin: w.origin,
                                                   isStrictValidCz: w.isStrictValidCz,
                                                   toneMeta: w.toneMeta))
        }
        return results
    }

    /// Aplikuje perspektivní korekci na CIImage.
    ///
    /// **Matematika:** uživatel označí 4 rohy kosého objektu (např. SPZ) — tj.
    /// vstupní „quad" Q. Cíl = obdélník R (plný ROI). Spočteme **homografii
    /// H_qr: Q → R** (DLT, solve 8×8 linear system) a aplikujeme H_qr na CELÝ
    /// ROI (nejen na quad). Výstup = scéna warpnutá tak, že quad je obdélníkový,
    /// ale okolní content (auto, brána, …) zůstává viditelný — jen se natočí.
    ///
    /// `CIPerspectiveTransform` požaduje 4 cílové body pro rohy vstupního obrazu.
    /// My mu dáme H_qr(R_corner_i) — kde se rohy obrazu ocitnou po aplikaci H_qr.
    /// Výstup pak ořízneme na ROI extent pro pipeline konzistenci.
    ///
    /// Identity (TL=0,0 / TR=1,0 / BR=1,1 / BL=0,1) → H_qr = I → bez změny.
    /// Aplikuje perspektivní korekci jako přímou manipulaci rohů obrazu.
    ///
    /// **Sémantika:** user's 4 body (topLeft, topRight, bottomRight, bottomLeft)
    /// v normalized [0,1] ROI prostoru jsou **destinace, kam se posunou rohy
    /// výstupního obrazu**. Default (identity) = (0,0)/(1,0)/(1,1)/(0,1) →
    /// bez korekce. Přetažení bodu napříč ROI rozpostáhne/natočí obraz přesně
    /// v té části.
    ///
    /// `CIPerspectiveTransform` dělá přesně tohle — mapuje rohy input obrazu
    /// na 4 user-specified destinace. Žádná homografie-z-plate, žádné bbox
    /// výpočty, žádný fit. User vidí přesně to, kam roh posunul.
    ///
    /// Strength: lineární blend mezi identity (rohy ROI) a user-specified.
    /// Scale X/Y: post-affine natažení.
    static func applyPerspective(_ image: CIImage, width w: CGFloat, height h: CGFloat,
                                 perspective p: PerspectiveConfig) -> CIImage? {
        // TL-normalized [0,1] → BL-pixel coords v image extent.
        func toPixel(_ pt: CGPoint) -> CGPoint {
            CGPoint(x: pt.x * w, y: (1.0 - pt.y) * h)
        }
        // User's destinace pro rohy obrazu.
        var dst: [CGPoint] = [
            toPixel(p.topLeft),      // kam půjde TL roh input obrazu
            toPixel(p.topRight),     // TR
            toPixel(p.bottomRight),  // BR
            toPixel(p.bottomLeft)    // BL
        ]
        // Identity = rohy ROI (pro strength blend).
        let rect: [CGPoint] = [
            CGPoint(x: 0, y: h),  // TL in BL coords
            CGPoint(x: w, y: h),  // TR
            CGPoint(x: w, y: 0),  // BR
            CGPoint(x: 0, y: 0)   // BL
        ]
        // Strength blend: interpoluj mezi identity a user destinací.
        let s = CGFloat(max(0, min(4, p.strength)))
        if abs(s - 1.0) > 0.001 {
            for i in 0..<4 {
                dst[i] = CGPoint(
                    x: rect[i].x + s * (dst[i].x - rect[i].x),
                    y: rect[i].y + s * (dst[i].y - rect[i].y)
                )
            }
        }

        // Scale X/Y ve SVĚTOVÝCH osách (horizontální / vertikální směr výstupního
        // obrazu na obrazovce). Aplikuje se na dst body škálováním kolem jejich
        // centroidu — nezávislé na orientaci plate uvnitř ROI.
        let sx = CGFloat(p.scaleX), sy = CGFloat(p.scaleY)
        if abs(sx - 1.0) > 0.001 || abs(sy - 1.0) > 0.001 {
            let cx = (dst[0].x + dst[1].x + dst[2].x + dst[3].x) / 4
            let cy = (dst[0].y + dst[1].y + dst[2].y + dst[3].y) / 4
            for i in 0..<4 {
                let dx = (dst[i].x - cx) * sx
                let dy = (dst[i].y - cy) * sy
                dst[i] = CGPoint(x: cx + dx, y: cy + dy)
            }
        }

        // CIPerspectiveTransform s user destinacemi.
        guard let filter = CIFilter(name: "CIPerspectiveTransform") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: dst[0]), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: dst[1]), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: dst[2]), forKey: "inputBottomRight")
        filter.setValue(CIVector(cgPoint: dst[3]), forKey: "inputBottomLeft")
        guard var out = filter.outputImage else { return nil }
        // Offset X/Y — čistá translace výstupu (před cropem). Pure pixel shift,
        // žádné scale side-effecty. offsetY pozitivní = posun dolů v UI → v
        // BL-coords = nižší y, takže aplikujeme −offsetY.
        let ox = CGFloat(p.offsetX) * w
        let oy = -CGFloat(p.offsetY) * h
        if abs(ox) > 0.5 || abs(oy) > 0.5 {
            out = out.transformed(by: CGAffineTransform(translationX: ox, y: oy))
        }

        // Crop na ROI rozměry.
        out = out.cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        let ext = out.extent
        if ext.width < 1 || ext.height < 1 { return nil }
        if ext.minX != 0 || ext.minY != 0 {
            out = out.transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
        }
        return out
    }

    /// Render CIImage → CGImage s volitelným up/downscale pro optimal Vision perf.
    /// Vision na `.accurate` radikálně lépe čte při min ~800 px šířce (upscale +2.5×).
    /// Také zpomaluje na velkém image (>1200×800 → 150-300 ms místo 50-80 ms).
    ///
    /// **Downscale heuristika:** pokud workspace aspect < 3 (= car+plate)
    /// a origH > 500 px, scale-down aby target height = 500. Plate při výstupu zůstane
    /// ~200 px → znaky ~60 px → Vision čte bez ztráty accuracy. 2-3× faster Vision.
    /// Pokud aspect >= 3 (plate-shape, rectified), neshrnkám — každý pixel plate counts.
    private static func renderForVision(_ source: CIImage, origW: CGFloat, origH: CGFloat,
                                        allowAutoScale: Bool = true) -> CGImage? {
        renderForVisionWithRaw(source, origW: origW, origH: origH,
                               allowAutoScale: allowAutoScale).processed
    }

    /// Vrátí processed CGImage (pro Vision) + raw CIImage (lazy — render na CGImage
    /// až při commit time). Raw CIImage je lightweight reference bez GPU renderu,
    /// neblokuje per-tick OCR path. PlatePipeline.commit() renderuje CIImage →
    /// CGImage jen pro commity co se ukládají.
    ///
    /// Lazy raw rendering eliminuje per-tick CGImage allocation pro
    /// non-committing ticks (většina ticků — 30-50 commits / 3000+ ticků =
    /// <2 % committing).
    private static func renderForVisionWithRaw(_ source: CIImage, origW: CGFloat, origH: CGFloat,
                                               allowAutoScale: Bool = true) -> (raw: CIImage, processed: CGImage?) {
        let aspect = origW / max(origH, 1)
        let factor: CGFloat
        if allowAutoScale, origW < minVisionInputWidth {
            factor = min(maxUpscaleFactor, minVisionInputWidth / origW)
        } else if allowAutoScale, aspect < 3.0 && origH > 500 {
            // Non-plate-shape (car+plate workspace) + velká výška → downscale.
            factor = 500.0 / origH
            AppState.devLog("PlateOCR.render: downscale \(Int(origW))×\(Int(origH)) → \(Int(origW*factor))×\(Int(origH*factor)) (factor=\(String(format: "%.2f", factor)))")
        } else {
            factor = 1.0
        }
        let targetW = origW * factor
        let targetH = origH * factor
        var scaled: CIImage = source
        if abs(factor - 1.0) > 0.001 {
            scaled = scaled.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        }
        let renderRect = CGRect(x: 0, y: 0, width: targetW, height: targetH)
        // Processed: render sync — Vision ho potřebuje jako CGImage.
        let processedCI = preprocessForOCR(scaled)
        let processedCG = sharedCIContext.createCGImage(processedCI, from: renderRect)
        // Raw: vracíme CIImage reference (žádný createCGImage). PlatePipeline
        // commit() zavolá `sharedCIContext.createCGImage(raw, from: raw.extent)`
        // jen při commit time.
        return (scaled, processedCG)
    }

    fileprivate struct WorkObs {
        var text: String
        var altTexts: [String]
        var confidence: Float
        var workBox: CGRect
        var origin: PlateOCRReadingOrigin = .passOneRaw
        var isStrictValidCz: Bool = false
        var toneMeta: ToneMeta? = nil
    }

    private struct RawCandidateAuditItem {
        let text: String
        let confidence: Float
        let heightFraction: CGFloat
        let aspect: CGFloat
        let action: String

        var payload: [String: Any] {
            [
                "text": text,
                "conf": Double(confidence),
                "h": Double(heightFraction),
                "aspect": Double(aspect),
                "action": action
            ]
        }
    }

    private struct RawCandidate {
        let text: String
        let altTexts: [String]
        let confidence: Float
        let workBox: CGRect

        var allTexts: [String] { [text] + altTexts }
    }

    private static func emitRawCandidateTickAudit(camera: String?,
                                                  frameIdx: Int?,
                                                  workW: CGFloat,
                                                  workH: CGFloat,
                                                  rawCount: Int,
                                                  smallFiltered: Int,
                                                  aspectFiltered: Int,
                                                  emptyFiltered: Int,
                                                  toTracker: Int,
                                                  topCandidates: [RawCandidateAuditItem]) {
        guard camera != nil || frameIdx != nil else { return }
        // **Audit log spam reduction:** emit jen když:
        //   - tracker dostal aspoň 1 reading (toTracker > 0), OR
        //   - top candidate má plate-like text (≥ 5 chars), OR
        //   - aspect/empty filter měl >0 hits (něco zajímavého filter cycle)
        let topText = topCandidates.first?.text.replacingOccurrences(of: " ", with: "") ?? ""
        let hasUsefulSignal = toTracker > 0
            || topText.count >= 5
            || aspectFiltered > 0
        guard hasUsefulSignal else { return }
        var fields: [String: Any] = [
            "raw": rawCount,
            "smallFiltered": smallFiltered,
            "aspectFiltered": aspectFiltered,
            "emptyFiltered": emptyFiltered,
            "toTracker": toTracker,
            "workW": Int(workW.rounded()),
            "workH": Int(workH.rounded()),
            "topCandidates": topCandidates
                .sorted {
                    if abs($0.confidence - $1.confidence) > 0.001 {
                        return $0.confidence > $1.confidence
                    }
                    return $0.heightFraction > $1.heightFraction
                }
                .prefix(3)
                .map { $0.payload }
        ]
        if let camera { fields["camera"] = camera }
        if let frameIdx { fields["frame"] = frameIdx }
        Audit.event("raw_candidate_tick", fields)
    }

    private static func emitSmallCandidateAudit(camera: String?,
                                                frameIdx: Int?,
                                                text: String,
                                                confidence: Float,
                                                workBox: CGRect,
                                                workW: CGFloat,
                                                workH: CGFloat) {
        guard camera != nil || frameIdx != nil else { return }
        var fields: [String: Any] = [
            "text": text,
            "conf": Double(confidence),
            "h": Double(workBox.height / max(workH, 1)),
            "w": Double(workBox.width / max(workW, 1)),
            "x": Double(workBox.minX),
            "y": Double(workBox.minY),
            "bw": Double(workBox.width),
            "bh": Double(workBox.height)
        ]
        if let camera { fields["camera"] = camera }
        if let frameIdx { fields["frame"] = frameIdx }
        Audit.event("small_candidate", fields)
    }

    static func clusterByYAxis(boxes: [CGRect]) -> [[Int]] {
        guard !boxes.isEmpty else { return [] }
        var groups: [[Int]] = []
        let sortedIdx = boxes.indices.sorted { boxes[$0].midY < boxes[$1].midY }
        for i in sortedIdx {
            if var last = groups.last, let repr = last.first {
                let rbox = boxes[repr]
                if abs(boxes[i].midY - rbox.midY) < max(rbox.height, boxes[i].height) * 0.5 {
                    last.append(i)
                    groups[groups.count - 1] = last
                    continue
                }
            }
            groups.append([i])
        }
        return groups
    }

    private static func clusterByYAxis(items: [WorkObs], indices: [Int]) -> [[Int]] {
        let boxes = indices.map { items[$0].workBox }
        return clusterByYAxis(boxes: boxes).map { group in group.map { indices[$0] } }
    }

    private static func isObviousSignboard(_ text: String) -> Bool {
        let upper = text.uppercased()
        let signboardSubstrings: [String] = [
            "ZIMN", "STADION", "PRIBR", "PRBR", "PŘÍBR", "VCHOD", "VCHO", "HALY",
            "FASE", "ARMATUR", "ENERGY", "GROUP", "SKUPIN", "NPRBR", "SPZ"
        ]
        return signboardSubstrings.contains { upper.contains($0) }
    }

    private static func compactPlateText(_ text: String) -> String {
        normalize(text).replacingOccurrences(of: " ", with: "")
    }

    private static func isPlausiblePlateText(_ text: String) -> Bool {
        let compact = compactPlateText(text)
        guard compact.count >= 5, compact.count <= 10 else { return false }
        return compact.contains(where: { $0.isNumber })
            && compact.contains(where: { $0.isLetter })
            && !isObviousSignboard(text)
    }

    private static func isUsefulRetrySeedText(_ text: String) -> Bool {
        let compact = compactPlateText(text)
        guard compact.count >= 3, compact.count <= 10 else { return false }
        guard !isObviousSignboard(text) else { return false }
        // Low-confidence pass 1 often splits plates into fragments ("EL3" + "28DN").
        // Keep alnum fragments, but skip all-letter signboard chunks like "VCHOD".
        return compact.contains(where: { $0.isNumber })
            && compact.contains(where: { $0.isLetter })
    }

    private static func boundedLevenshtein(_ a: String, _ b: String, maxDistance: Int) -> Bool {
        let a = Array(a), b = Array(b)
        if abs(a.count - b.count) > maxDistance { return false }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            var rowMin = current[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowMin = min(rowMin, current[j])
            }
            if rowMin > maxDistance { return false }
            previous = current
        }
        return previous[b.count] <= maxDistance
    }

    private static func isSimilarPlateText(_ lhs: String, _ rhs: String) -> Bool {
        let a = compactPlateText(lhs)
        let b = compactPlateText(rhs)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return boundedLevenshtein(a, b, maxDistance: 2)
    }

    private static func isStrictValidCzCandidate(_ text: String, alts: [String] = []) -> Bool {
        for candidate in [text] + alts {
            let (_, valid, region) = CzNormalizer.process(candidate)
            if valid, region == .cz || region == .czElectric || region == .sk {
                return true
            }
        }
        return false
    }

    private static func originRank(_ origin: PlateOCRReadingOrigin) -> Int {
        switch origin {
        case .passOneRaw: return 0
        case .weakTrackletMerged: return 0
        case .passTwoEnhanced: return 1
        case .crossValidatedFuzzy: return 2
        case .crossValidated: return 3
        }
    }

    /// Smooth upscale pro OCR retry. Target height ~120 px drží Vision `.accurate`
    /// ve stabilní oblasti, cap 2.5× brání přefouknutí šumu z tiny cropů.
    static func ocrUpscaleFactor(forSourceHeight height: CGFloat) -> CGFloat {
        guard height > 0 else { return 1.0 }
        return min(2.5, max(1.0, 120.0 / height))
    }

    static func ocrUpscaleFactor(for sourceRect: CGRect) -> CGFloat {
        ocrUpscaleFactor(forSourceHeight: sourceRect.height)
    }

    /// Konzervativnější upscale pro uložený snapshot crop. Snapshot má být lidsky
    /// čitelný a bez halo; nepotřebuje maximum ostrosti pro OCR.
    /// Target 120 px (cap 2.5×) — bicubic bez ringingu i při 2.5× scale.
    static func snapshotUpscaleFactor(forSourceHeight height: CGFloat) -> CGFloat {
        guard height > 0 else { return 1.0 }
        return min(2.5, max(1.0, 120.0 / height))
    }

    static func snapshotUpscaleFactor(for sourceRect: CGRect) -> CGFloat {
        snapshotUpscaleFactor(forSourceHeight: sourceRect.height)
    }

    static func ocrRetryRenderSize(for sourceRect: CGRect) -> CGSize {
        let scale = ocrUpscaleFactor(for: sourceRect)
        return CGSize(width: sourceRect.width * scale, height: sourceRect.height * scale)
    }

    static func snapshotRenderSize(for sourceRect: CGRect) -> CGSize {
        let scale = snapshotUpscaleFactor(for: sourceRect)
        return CGSize(width: sourceRect.width * scale, height: sourceRect.height * scale)
    }

    private static func denoiseForPlateUpscaleIfNeeded(_ image: CIImage, sourceHeight: CGFloat) -> CIImage {
        guard sourceHeight < 50, let f = CIFilter(name: "CINoiseReduction") else { return image }
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(NSNumber(value: 0.02), forKey: "inputNoiseLevel")
        f.setValue(NSNumber(value: 0.4), forKey: "inputSharpness")
        return f.outputImage ?? image
    }

    /// Gray-world auto white balance — odstrani color cast (modrofialový tón)
    /// z plate cropu. Cíl: plate background by měl být ~neutral white, ne modrý.
    /// Bez WB by color cast kontaminoval OCR i secondary engine vstup.
    ///
    /// Algoritmus:
    ///   1. Sample mean R/G/B z celého cropu (CIAreaAverage, 1×1 pixel result)
    ///   2. Per-channel gain: `gain[c] = mean_luma / mean[c]`
    ///   3. Aplikuj `CIColorMatrix` s diagonálním gain matrix (R=gainR, G=gainG, B=gainB)
    ///   4. Skip pokud max(gain)/min(gain) < 1.05 (image je už neutral, no-op)
    ///
    /// **Post-SR enhancement:** adaptive gamma (auto-target luma mean 0.45)
    /// + S-curve mid-contrast boost + bilateral denoise (preserves character
    /// edges, smooths JPEG-like artefakty z SR upscaling) + micro-unsharp.
    /// Targets low-contrast aged plates, bicubic ringing v SR outputu, weak
    /// character edges. Cost ~5-15 ms M4 GPU pro 4× upscaled CGImage.
    /// Snapshot path only — nepoužívat na hot OCR path.
    static func applyPostSREnhancement(_ cg: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: cg)
        let extent = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)

        // 1. Adaptive gamma — measure luma mean, gamma s.t. mean^(1/g) = 0.45
        var current = ci
        if let stats = measureLumaStats(current, extent: extent) {
            let mean = Double(stats.mean)
            if mean > 0.05 && mean < 0.95 {
                let target = 0.45
                let gamma = log(max(mean, 1e-6)) / log(target)
                let cappedGamma = max(0.5, min(2.0, gamma))
                if abs(cappedGamma - 1.0) > 0.05,
                   let gammaFilter = CIFilter(name: "CIGammaAdjust") {
                    gammaFilter.setValue(current, forKey: kCIInputImageKey)
                    gammaFilter.setValue(NSNumber(value: 1.0 / cappedGamma), forKey: "inputPower")
                    if let out = gammaFilter.outputImage { current = out }
                }
            }
        }

        // 2. S-curve tone — boost mid-contrast bez crush blacks/whites.
        // CIToneCurve s 5 control points: (0,0), (0.25, 0.20), (0.5, 0.5), (0.75, 0.80), (1,1)
        if let toneCurve = CIFilter(name: "CIToneCurve") {
            toneCurve.setValue(current, forKey: kCIInputImageKey)
            toneCurve.setValue(CIVector(x: 0.0, y: 0.0), forKey: "inputPoint0")
            toneCurve.setValue(CIVector(x: 0.25, y: 0.20), forKey: "inputPoint1")
            toneCurve.setValue(CIVector(x: 0.5, y: 0.5), forKey: "inputPoint2")
            toneCurve.setValue(CIVector(x: 0.75, y: 0.80), forKey: "inputPoint3")
            toneCurve.setValue(CIVector(x: 1.0, y: 1.0), forKey: "inputPoint4")
            if let out = toneCurve.outputImage { current = out }
        }

        // 3. Bilateral-style denoise. CINoiseReduction edge-preserving smoothing —
        // CIBilateralFilter neexistuje v public CI API, NoiseReduction
        // s noiseLevel 0.02 + sharpness 0.4 dělá podobnou práci.
        if let nr = CIFilter(name: "CINoiseReduction") {
            nr.setValue(current, forKey: kCIInputImageKey)
            nr.setValue(NSNumber(value: 0.02), forKey: "inputNoiseLevel")
            nr.setValue(NSNumber(value: 0.40), forKey: "inputSharpness")
            if let out = nr.outputImage { current = out }
        }

        // 4. Micro-unsharp na detail recovery (small radius targeting char edges).
        if let unsharp = CIFilter(name: "CIUnsharpMask") {
            unsharp.setValue(current, forKey: kCIInputImageKey)
            unsharp.setValue(NSNumber(value: 0.8), forKey: kCIInputRadiusKey)
            unsharp.setValue(NSNumber(value: 0.35), forKey: kCIInputIntensityKey)
            if let out = unsharp.outputImage { current = out }
        }

        return sharedCIContext.createCGImage(current, from: extent)
    }

    /// Cost: 1× CIAreaAverage GPU pass + 1× CIColorMatrix = ~0.3 ms M4 GPU.
    /// Žádný ML, žádné ANE. Aplikuje se PŘED adaptive tone aby tone curve
    /// pracoval na neutralizovaných datech.
    static func applyGrayWorldWhiteBalance(_ image: CIImage, extent: CGRect) -> CIImage {
        let avg = image.applyingFilter("CIAreaAverage", parameters: [
            kCIInputExtentKey: CIVector(cgRect: extent)
        ])
        var pixel = [UInt8](repeating: 0, count: 4)
        sharedCIContext.render(avg, toBitmap: &pixel, rowBytes: 4,
                               bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                               format: .RGBA8, colorSpace: nil)
        let r = Double(pixel[0]) / 255.0
        let g = Double(pixel[1]) / 255.0
        let b = Double(pixel[2]) / 255.0
        // Skip pokud channel je near-black (avoid divide-by-near-zero amplification noise)
        guard r > 0.05, g > 0.05, b > 0.05 else { return image }
        let lum = 0.299 * r + 0.587 * g + 0.114 * b
        let gainR = lum / r
        let gainG = lum / g
        let gainB = lum / b
        let maxGain = max(gainR, gainG, gainB)
        let minGain = min(gainR, gainG, gainB)
        // Skip pokud image je už neutral (no perceptible cast).
        guard maxGain / minGain > 1.05 else { return image }
        // Cap gain abychom neexpodovali noise v dark channels.
        let cappedR = min(2.0, max(0.5, gainR))
        let cappedG = min(2.0, max(0.5, gainG))
        let cappedB = min(2.0, max(0.5, gainB))
        guard let f = CIFilter(name: "CIColorMatrix") else { return image }
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(CIVector(x: CGFloat(cappedR), y: 0, z: 0, w: 0), forKey: "inputRVector")
        f.setValue(CIVector(x: 0, y: CGFloat(cappedG), z: 0, w: 0), forKey: "inputGVector")
        f.setValue(CIVector(x: 0, y: 0, z: CGFloat(cappedB), w: 0), forKey: "inputBVector")
        f.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        return f.outputImage ?? image
    }

    /// Backlit scene tone-mapping pre-pass — **scaled intensity podle darkness**.
    /// Aplikuje se PŘED standard adaptive tone. Apple-native HDR techniky.
    ///
    /// **Scaling (smooth ramp):**
    ///   `darkness = max(0, min(1, (0.20 - mean) / 0.20))`
    ///   - mean = 0.00  → darkness = 1.0  (full chain pro extreme backlight)
    ///   - mean = 0.05  → darkness = 0.75 (strong)
    ///   - mean = 0.10  → darkness = 0.5  (half intensity)
    ///   - mean = 0.15  → darkness = 0.25 (mild)
    ///   - mean ≥ 0.20  → darkness = 0.0  (skip)
    ///
    /// Cutoff 0.20 — striktnější než 0.40, jen reálně backlit dostává
    /// enhancement (mean 0.30+ scény by 0.40 přepalovalo).
    ///
    /// Parametry chain násobí darkness:
    ///   - Shadow lift: 0.9 × darkness
    ///   - Highlight compress: -0.7 × darkness
    ///   - Exposure boost: 0.8 EV × darkness
    ///   - Contrast: 1.0 + 0.25 × darkness
    ///
    /// Smooth ramp brání over-exposure pro hraniční scény (mean 0.30-0.40)
    /// kde binary threshold by aplikoval plný chain.
    fileprivate static func backlightDarkness(for stats: LumaStats) -> Double {
        max(0, min(1, (0.20 - Double(stats.mean)) / 0.20))
    }

    fileprivate static func toneMetaForObservation(visionCI: CIImage,
                                                    workBoxTL: CGRect,
                                                    workHeight: CGFloat,
                                                    source: String,
                                                    backlightFired: Bool = false) -> ToneMeta? {
        let rectBL = CGRect(x: workBoxTL.minX,
                            y: max(0, workHeight - workBoxTL.maxY),
                            width: workBoxTL.width,
                            height: workBoxTL.height)
            .intersection(visionCI.extent)
        guard !rectBL.isNull, rectBL.width >= 1, rectBL.height >= 1 else { return nil }
        let crop = visionCI.cropped(to: rectBL)
            .transformed(by: CGAffineTransform(translationX: -rectBL.minX, y: -rectBL.minY))
        let extent = CGRect(origin: .zero, size: rectBL.size)
        guard let stats = measureLumaStats(crop, extent: extent) else { return nil }
        let darkness = backlightDarkness(for: stats)
        return ToneMeta(mean: stats.mean,
                        std: stats.std,
                        p05: stats.p05,
                        p95: stats.p95,
                        darkness: darkness,
                        upscale: 1.0,
                        backlightFired: backlightFired,
                        source: source)
    }

    fileprivate static func applyBacklightCorrectionIfNeeded(_ image: CIImage,
                                                              stats: LumaStats) -> CIImage {
        let darkness = backlightDarkness(for: stats)
        guard darkness > 0.10 else { return image }  // skip pokud effect < 10%
        var v = image
        if let f = CIFilter(name: "CIHighlightShadowAdjust") {
            f.setValue(v, forKey: kCIInputImageKey)
            f.setValue(NSNumber(value: 0.0), forKey: "inputRadius")
            f.setValue(NSNumber(value: 0.9 * darkness), forKey: "inputShadowAmount")
            f.setValue(NSNumber(value: -0.7 * darkness), forKey: "inputHighlightAmount")
            if let out = f.outputImage { v = out }
        }
        if let f = CIFilter(name: "CIExposureAdjust") {
            f.setValue(v, forKey: kCIInputImageKey)
            f.setValue(NSNumber(value: 0.8 * darkness), forKey: kCIInputEVKey)
            if let out = f.outputImage { v = out }
        }
        if let f = CIFilter(name: "CIColorControls") {
            f.setValue(v, forKey: kCIInputImageKey)
            f.setValue(NSNumber(value: 1.0 + 0.25 * darkness), forKey: kCIInputContrastKey)
            f.setValue(NSNumber(value: 1.0 - 0.4 * darkness), forKey: kCIInputSaturationKey)
            f.setValue(NSNumber(value: 0.02 * darkness), forKey: kCIInputBrightnessKey)
            if let out = f.outputImage { v = out }
        }
        return v
    }

    /// vImage Lanczos 3-lobe upscale (default flag, ne kvImageHighQualityResampling=5-lobe).
    /// Sharper než Mitchell-Netravali bicubic, méně ringingu než 5-lobe Lanczos.
    /// CPU-only, bez GPU roundtripu uvnitř vImage; jen 1× CI→CG na vstupu a CG→CI na výstupu.
    private static func scalePlateCrop(_ image: CIImage, factor: CGFloat) -> CIImage {
        guard factor > 1.001 else { return image }
        let srcExtent = image.extent
        guard srcExtent.width >= 1, srcExtent.height >= 1,
              let srcCG = sharedCIContext.createCGImage(image, from: srcExtent) else {
            return image.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: factor,
                kCIInputAspectRatioKey: 1.0
            ])
        }

        let dstWidth = max(1, Int((srcExtent.width * factor).rounded()))
        let dstHeight = max(1, Int((srcExtent.height * factor).rounded()))

        guard var format = vImage_CGImageFormat(cgImage: srcCG) else {
            return image.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: factor,
                kCIInputAspectRatioKey: 1.0
            ])
        }

        var srcBuf = vImage_Buffer()
        guard vImageBuffer_InitWithCGImage(&srcBuf, &format, nil, srcCG,
                                           vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
            return image.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: factor,
                kCIInputAspectRatioKey: 1.0
            ])
        }
        defer { srcBuf.free() }

        var dstBuf = vImage_Buffer()
        guard vImageBuffer_Init(&dstBuf, vImagePixelCount(dstHeight), vImagePixelCount(dstWidth),
                                32, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
            return image.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: factor,
                kCIInputAspectRatioKey: 1.0
            ])
        }
        defer { dstBuf.free() }

        let scaleErr = vImageScale_ARGB8888(&srcBuf, &dstBuf, nil,
                                            vImage_Flags(kvImageNoFlags))
        guard scaleErr == kvImageNoError,
              let dstCG = vImageCreateCGImageFromBuffer(&dstBuf, &format, nil, nil,
                                                        vImage_Flags(kvImageNoFlags),
                                                        nil)?.takeRetainedValue() else {
            return image.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: factor,
                kCIInputAspectRatioKey: 1.0
            ])
        }

        let outImage = CIImage(cgImage: dstCG)
        let originX = srcExtent.origin.x * factor
        let originY = srcExtent.origin.y * factor
        if originX != 0 || originY != 0 {
            return outImage.transformed(by: CGAffineTransform(translationX: originX, y: originY))
        }
        return outImage
    }

    /// Merge adjacent fragments. Chain > 1 emituje **jen merged** (fragmenty zahozeny),
    /// jinak foreign plate "WOB ZK 295" skončí 2× (fragment "ZK295" czVanity + merged
    /// foreign). Single-item lines projdou beze změny.
    private static func mergeInWorkSpace(_ items: [WorkObs]) -> [WorkObs] {
        guard items.count > 1 else { return items }
        var groups: [[Int]] = []
        let sortedIdx = items.indices.sorted { items[$0].workBox.midY < items[$1].workBox.midY }
        for i in sortedIdx {
            if var last = groups.last, let repr = last.first {
                let rbox = items[repr].workBox
                if abs(items[i].workBox.midY - rbox.midY) < rbox.height * 0.5 {
                    last.append(i)
                    groups[groups.count - 1] = last
                    continue
                }
            }
            groups.append([i])
        }

        var result: [WorkObs] = []
        for line in groups {
            if line.count == 1 {
                result.append(items[line[0]])
                continue
            }
            let sortedLine = line.sorted { items[$0].workBox.midX < items[$1].workBox.midX }
            var current = items[sortedLine[0]]
            for idx in sortedLine.dropFirst() {
                let next = items[idx]
                let gap = next.workBox.minX - current.workBox.maxX
                let avgCharW = max(current.workBox.width / max(CGFloat(current.text.count), 1),
                                   next.workBox.width / max(CGFloat(next.text.count), 1))
                let h1 = current.workBox.height, h2 = next.workBox.height
                let heightRatio = max(h1, h2) / max(min(h1, h2), 1)
                let combinedNoSpace = (current.text + next.text).replacingOccurrences(of: " ", with: "")
                // Overlap guard: pokud next bbox OVERLAP s current (záporný gap),
                // je to pravděpodobně stejný text detekovaný 2× (dual-pass rev2/rev3)
                // nebo Vision dvou-observation split duplicate. NEKOKATENOVAT.
                // Bez tohoto vznikají "6S2 6S2 6003".
                let overlapping = gap < -avgCharW * 0.3  // >30% char width overlap
                if overlapping {
                    // Prefer LONGER text (fuller detekce) — dual-pass rev2 často
                    // vrátí celý plate "5U6 0000" zatímco rev3 split na "5U6" + "0000",
                    // partials mohou mít vyšší confidence ale ztratíme půl plate.
                    // Až při stejné délce rozhoduje confidence.
                    let curLen = current.text.replacingOccurrences(of: " ", with: "").count
                    let nextLen = next.text.replacingOccurrences(of: " ", with: "").count
                    if next.isStrictValidCz, !current.isStrictValidCz {
                        current = next
                    } else if nextLen > curLen {
                        current = next
                    } else if nextLen == curLen,
                              originRank(next.origin) > originRank(current.origin) {
                        current = next
                    } else if nextLen == curLen && next.confidence > current.confidence {
                        current = next
                    }
                    continue
                }
                let mergeable = gap < avgCharW * 2.0 && heightRatio < 1.5 && combinedNoSpace.count <= 10
                if mergeable {
                    let combinedText = current.text + " " + next.text
                    // Pokus merge alts: kartézský součin top-2 × top-2 = až 4 alty.
                    // Keep top 2 nejlepších by length-match (vanity/cz candidates).
                    var combinedAlts: [String] = []
                    let cAlts = [current.text] + current.altTexts.prefix(1)
                    let nAlts = [next.text] + next.altTexts.prefix(1)
                    for a in cAlts {
                        for b in nAlts {
                            let t = a + " " + b
                            if t != combinedText && !combinedAlts.contains(t) {
                                combinedAlts.append(t)
                                if combinedAlts.count >= 2 { break }
                            }
                        }
                        if combinedAlts.count >= 2 { break }
                    }
                    let combinedBox = current.workBox.union(next.workBox)
                    let combinedConf = (current.confidence * Float(current.text.count) +
                                        next.confidence * Float(next.text.count)) /
                                       Float(current.text.count + next.text.count)
                    let combinedOrigin = originRank(current.origin) >= originRank(next.origin)
                        ? current.origin : next.origin
                    let combinedStrict = current.isStrictValidCz
                        || next.isStrictValidCz
                        || isStrictValidCzCandidate(combinedText, alts: combinedAlts)
                    current = WorkObs(text: combinedText, altTexts: combinedAlts,
                                      confidence: combinedConf, workBox: combinedBox,
                                      origin: combinedOrigin,
                                      isStrictValidCz: combinedStrict,
                                      toneMeta: current.toneMeta ?? next.toneMeta)
                } else {
                    result.append(current)
                    current = next
                }
            }
            result.append(current)
        }
        return result
    }

    private static let validChars = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ")

    static func normalize(_ raw: String) -> String {
        let upper = raw.uppercased()
        let scalars = upper.unicodeScalars.filter { validChars.contains($0) }
        let cleaned = String(String.UnicodeScalarView(scalars))
        return cleaned.split(separator: " ").joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Adaptive světelná normalizace
    //
    // Dvoustupňová strategie per-frame:
    //  1. `measureLumaStats` — z 256-bin histogramu spočítá mean/std + robustní
    //     p5/p95 luminance (0–1 škála). Histogram běží na GPU přes CIAreaHistogram,
    //     parse na CPU je pouze 256 iterací.
    //  2. `applyAdaptiveEnhancement` — EV shift počítá ze středu p5/p95, kontrast
    //     z p5/p95 rozsahu. Robustní p5/p95 (vs min/max) brání outliers (jedna
    //     reflexe / černý okraj) v dominaci. Unsharp je mírný a jen pro měkké
    //     low-contrast cropy.

    fileprivate struct LumaStats {
        let mean: Float
        let std: Float
        let p05: Float
        let p95: Float

        var robustRange: Float { max(0, p95 - p05) }
        var robustMid: Float { (p05 + p95) * 0.5 }
    }

    /// Naměří průměr, std a robustní p5/p95 luminance v daném extent. Vrací 0–1 škálu.
    /// GPU hot path — `CIAreaHistogram` dá 256 binů, na CPU sečteme E[X], E[X²].
    fileprivate static func measureLumaStats(_ ci: CIImage, extent: CGRect) -> LumaStats? {
        // Extract luma (Rec. 709) do jednokanálového obrazu.
        guard let lumaFilter = CIFilter(name: "CIColorMatrix") else { return nil }
        lumaFilter.setValue(ci, forKey: kCIInputImageKey)
        let lumaVec = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        lumaFilter.setValue(lumaVec, forKey: "inputRVector")
        lumaFilter.setValue(lumaVec, forKey: "inputGVector")
        lumaFilter.setValue(lumaVec, forKey: "inputBVector")
        lumaFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        guard let luma = lumaFilter.outputImage else { return nil }

        // 256-bin histogram luminance v extent. `inputScale` vysoká aby byly counts
        // reprezentovatelné v RGBAf float; renderujeme jako float pro přesnost.
        guard let histFilter = CIFilter(name: "CIAreaHistogram") else { return nil }
        histFilter.setValue(luma, forKey: kCIInputImageKey)
        histFilter.setValue(CIVector(cgRect: extent), forKey: "inputExtent")
        histFilter.setValue(256, forKey: "inputCount")
        histFilter.setValue(1.0, forKey: "inputScale")
        guard let hist = histFilter.outputImage else { return nil }

        var pixels = [Float](repeating: 0, count: 256 * 4)
        let rowBytes = 256 * 4 * MemoryLayout<Float>.size
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        sharedCIContext.render(hist, toBitmap: &pixels, rowBytes: rowBytes,
                               bounds: CGRect(x: 0, y: 0, width: 256, height: 1),
                               format: .RGBAf, colorSpace: colorSpace)

        // R kanál každého binu = count fraction. Mean + std v 0–255 škále, pak normalize.
        var total: Float = 0
        var weighted: Float = 0
        var bins = [Float](repeating: 0, count: 256)
        for i in 0..<256 {
            let v = max(0, pixels[i * 4])  // defenze proti zápornym float artefaktum
            bins[i] = v
            total += v
            weighted += v * Float(i)
        }
        guard total > 0 else { return nil }
        let mean = weighted / total
        var variance: Float = 0
        for i in 0..<256 {
            let diff = Float(i) - mean
            variance += bins[i] * diff * diff
        }
        variance /= total
        let std = sqrt(variance)
        func percentile(_ fraction: Float) -> Float {
            let target = total * fraction
            var acc: Float = 0
            for i in 0..<256 {
                acc += bins[i]
                if acc >= target {
                    return Float(i) / 255.0
                }
            }
            return 1.0
        }
        return LumaStats(mean: mean / 255.0,
                         std: std / 255.0,
                         p05: percentile(0.05),
                         p95: percentile(0.95))
    }

    /// Per-frame adaptive filter chain. Vrací `nil` pokud obraz nepotřebuje úpravu
    /// (robustní mid poblíž 0.5 a dostatečný p5/p95 rozsah) → caller keep original.
    fileprivate static func applyAdaptiveEnhancement(_ ci: CIImage, stats: LumaStats) -> CIImage? {
        let mean = stats.mean
        let std = stats.std
        let robustMid = stats.robustMid
        let robustRange = stats.robustRange
        let needsExposure = abs(robustMid - 0.5) > 0.10 || mean < 0.30 || mean > 0.70
        let needsContrast = robustRange < 0.52 || std < 0.14
        if !needsExposure && !needsContrast { return nil }

        var img = ci
        // EV shift směrem k midgray podle p5/p95 středu, ne podle raw mean.
        // Jedna bílá reflexe nebo tmavý rámeček tak nerozhodí celý crop.
        if needsExposure {
            let clampedMid = min(0.92, max(0.08, robustMid))
            var ev = log2f(0.5 / clampedMid) * 0.55
            ev = min(1.2, max(-1.2, ev))
            if let f = CIFilter(name: "CIExposureAdjust") {
                f.setValue(img, forKey: kCIInputImageKey)
                f.setValue(ev, forKey: "inputEV")
                if let o = f.outputImage { img = o }
            }
        }
        // Kontrast podle robustního p5/p95 rozsahu. Min/max stretch je příliš
        // tvrdý pro IR/reflexy; tady nezvedáme výš než 1.65× a při už
        // roztaženém histogramu necháme crop být.
        if needsContrast {
            let clampedRange = max(robustRange, 0.24)
            var gain = 0.58 / clampedRange
            gain = min(1.65, max(1.0, gain))
            if stats.p05 < 0.04 && stats.p95 > 0.96 {
                gain = min(gain, 1.12)
            }
            if let f = CIFilter(name: "CIColorControls") {
                f.setValue(img, forKey: kCIInputImageKey)
                f.setValue(NSNumber(value: gain), forKey: "inputContrast")
                f.setValue(NSNumber(value: 1.0), forKey: "inputSaturation")
                if let o = f.outputImage { img = o }
            }
        }
        // Doostření jen pro opravdu měkký low-contrast crop. Nižší intensity
        // záměrně chrání proti halo/ringing kolem znaků po upscale.
        if std < 0.075 && robustRange < 0.45 {
            if let f = CIFilter(name: "CIUnsharpMask") {
                f.setValue(img, forKey: kCIInputImageKey)
                f.setValue(NSNumber(value: 1.1), forKey: "inputRadius")
                f.setValue(NSNumber(value: 0.18), forKey: "inputIntensity")
                if let o = f.outputImage { img = o }
            }
        }
        return img
    }

    /// **Physics-Informed Motion-Tracked Plate Stacking** — volá se z `PlatePipeline.commit`
    /// jakmile track má ≥ 2 frames v stack buffer. Postupuje:
    /// 1. Warpuje každý stack frame do kanonického plate-coord system (scale workBox
    ///    do fixní velikosti 600×130, CZ plate aspect 4.6:1).
    /// 2. Confidence-weighted temporal mean přes všechny frames →
    ///    √N sensor noise reduction + motion blur averaging.
    /// 3. Spustí single Vision request na composite → single-shot result má vyšší
    ///    confidence než per-frame voting, protože noise floor klesl.
    /// Vrací `(text, confidence)?` — `nil` pokud composite OCR selhal / extrémně
    /// nízká conf; caller pak fallbackuje na tracker winner vote.
    static func ocrOnStackedComposite(frames: [PlateTrack.StackFrame],
                                      customWords: [String]) -> (text: String, confidence: Float)? {
        guard frames.count >= 2 else { return nil }

        // Kanonická plate velikost — CZ plate 520×110 mm aspect 4.73:1. Trochu větší
        // pro headroom. Vision ANE preferuje ~600 px width pro text recognition.
        let canonicalW: CGFloat = 600
        let canonicalH: CGFloat = 130

        // Warp každý frame do canonical space (crop workBox + scale to canonical).
        var aligned: [CIImage] = []
        var weights: [Float] = []
        for f in frames {
            guard f.workBox.width > 4, f.workBox.height > 4,
                  f.workSize.width > 0, f.workSize.height > 0 else { continue }
            let ci = CIImage(cgImage: f.cgImage)
            // workBox je TL-origin (Vision observation space), CIImage BL → flip Y.
            let cropRect = CGRect(x: f.workBox.minX,
                                  y: f.workSize.height - f.workBox.maxY,
                                  width: f.workBox.width,
                                  height: f.workBox.height)
            var cropped = ci.cropped(to: cropRect)
                .transformed(by: CGAffineTransform(translationX: -cropRect.minX,
                                                    y: -cropRect.minY))
            // Scale na canonical size (bilinear default, postačí pro stacking).
            let sx = canonicalW / f.workBox.width
            let sy = canonicalH / f.workBox.height
            cropped = cropped.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            // Clamp extent na canonical rect (po scale může být drobný off-by-one).
            cropped = cropped.cropped(to: CGRect(x: 0, y: 0, width: canonicalW, height: canonicalH))
            aligned.append(cropped)
            weights.append(f.confidence)
        }
        guard aligned.count >= 2 else { return nil }

        // Confidence-weighted mean: accumuluj normalized alpha per frame.
        // Použití CIColorMatrix s variable alpha + CISourceOverCompositing.
        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0.01 else { return nil }
        var composite: CIImage? = nil
        var accumulatedWeight: Float = 0
        for (img, w) in zip(aligned, weights) {
            let incomingShare = w / (accumulatedWeight + w)
            accumulatedWeight += w
            if composite == nil {
                composite = img
                continue
            }
            // incoming alpha = share of total so far. compose over existing.
            guard let colorFilter = CIFilter(name: "CIColorMatrix") else { continue }
            colorFilter.setValue(img, forKey: kCIInputImageKey)
            colorFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: CGFloat(incomingShare)),
                                 forKey: "inputAVector")
            guard let fore = colorFilter.outputImage else { continue }
            composite = fore.composited(over: composite!)
        }
        guard let finalComposite = composite else { return nil }

        // Render composite → CGImage pro Vision.
        guard let cg = sharedCIContext.createCGImage(finalComposite,
                                                     from: CGRect(x: 0, y: 0,
                                                                  width: canonicalW,
                                                                  height: canonicalH)) else {
            return nil
        }

        // Single Vision request na composite — single-shot confidence with √N noise.
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false
        req.recognitionLanguages = []
        if !customWords.isEmpty { req.customWords = Array(customWords.prefix(50)) }
        req.minimumTextHeight = max(Float(minTextHeightPx / canonicalH), 0.1)
        do { try handler.perform([req]) } catch { return nil }

        guard let observations = req.results, !observations.isEmpty else { return nil }
        var bestText: String = ""
        var bestConf: Float = 0
        for obs in observations {
            guard let top = obs.topCandidates(1).first else { continue }
            let norm = normalize(top.string)
            if norm.isEmpty { continue }
            if top.confidence > bestConf {
                bestConf = top.confidence
                bestText = norm
            }
        }

        // Fáze 2.2 enhancement: pokud base composite má slabou confidence (< 0.85),
        // zkusíme dva enhanced variants (brightness + contrast boost) a vezmeme best.
        // Multi-frame stitching benefit jde nad rámec jednoho raw compositu — každá
        // filtr kombinace může lépe zvýraznit text podle lighting conditions.
        if bestConf < 0.85 {
            let variants: [(name: String, filter: (CIImage) -> CIImage?)] = [
                ("brightness+0.1", { img in
                    let f = CIFilter(name: "CIColorControls")
                    f?.setValue(img, forKey: kCIInputImageKey)
                    f?.setValue(0.1, forKey: kCIInputBrightnessKey)
                    f?.setValue(1.2, forKey: kCIInputContrastKey)
                    return f?.outputImage
                }),
                ("gamma+1.3", { img in
                    let f = CIFilter(name: "CIGammaAdjust")
                    f?.setValue(img, forKey: kCIInputImageKey)
                    f?.setValue(1.3, forKey: "inputPower")
                    return f?.outputImage
                })
            ]
            for variant in variants {
                guard let enhanced = variant.filter(finalComposite),
                      let cgEnh = sharedCIContext.createCGImage(enhanced,
                          from: CGRect(x: 0, y: 0, width: canonicalW, height: canonicalH)) else { continue }
                let handlerEnh = VNImageRequestHandler(cgImage: cgEnh, options: [:])
                let reqEnh = VNRecognizeTextRequest()
                reqEnh.recognitionLevel = .accurate
                reqEnh.usesLanguageCorrection = false
                reqEnh.recognitionLanguages = []
                if !customWords.isEmpty { reqEnh.customWords = Array(customWords.prefix(50)) }
                reqEnh.minimumTextHeight = req.minimumTextHeight
                do { try handlerEnh.perform([reqEnh]) } catch { continue }
                for obs in (reqEnh.results ?? []) {
                    guard let top = obs.topCandidates(1).first else { continue }
                    let norm = normalize(top.string)
                    if norm.isEmpty { continue }
                    if top.confidence > bestConf {
                        bestConf = top.confidence
                        bestText = norm
                    }
                }
            }
        }

        guard !bestText.isEmpty else { return nil }
        return (text: bestText, confidence: bestConf)
    }

    /// Druhý Vision průchod na tight-cropped + enhanced výřezu. Volá se jen když
    /// první (raw) pass má slabou confidence (< 0.85) nebo je prázdný — pokrývá
    /// shadow/noc/bleach scénáře bez ovlivnění dobrých-light situací.
    ///
    /// `source` — full post-quad CIImage (stejná jako v 1. pass).
    /// `sourceRect` — tight pixel-bbox uvnitř source (best workBox + 8 px pad, nebo
    /// full workspace při prázdné 1st pass).
    /// `sourceW/H` — dimenze source workspace pro mapping tight bbox zpět.
    ///
    /// Vrací `[WorkObs]` už remapnuté do source workspace → caller je jen appendne
    /// do existing workItems a mergeInWorkSpace zkombinuje hlasy z obou průchodů.
    fileprivate static func tightEnhancedRetry(
        source: CIImage,
        sourceRect: CGRect,
        sourceW: CGFloat, sourceH: CGFloat,
        minObsHeightFraction: CGFloat,
        customWords: [String],
        exclusionMasks: [CGRect] = [],
        expectedTexts: [String] = []
    ) -> [WorkObs] {
        guard sourceRect.width > 32, sourceRect.height > 16 else { return [] }

        // Tight crop z source (CIImage je BL-origin → flip Y z TL sourceRect).
        let ciRect = CGRect(x: sourceRect.minX, y: sourceH - sourceRect.maxY,
                            width: sourceRect.width, height: sourceRect.height)
        var tight = source.cropped(to: ciRect)
            .transformed(by: CGAffineTransform(translationX: -ciRect.minX, y: -ciRect.minY))

        tight = denoiseForPlateUpscaleIfNeeded(tight, sourceHeight: sourceRect.height)

        // Adaptivní brightness/contrast korekce na tight výřezu (malý region =
        // histogram reprezentuje opravdu plate pixely, ne scenu okolo).
        let tightExtent = CGRect(x: 0, y: 0, width: sourceRect.width, height: sourceRect.height)
        let preToneStats = measureLumaStats(tight, extent: tightExtent)
        if let stats = measureLumaStats(tight, extent: tightExtent),
           let enhanced = applyAdaptiveEnhancement(tight, stats: stats) {
            tight = enhanced
        }

        let upscale = ocrUpscaleFactor(for: sourceRect)
        let toneMeta: ToneMeta? = preToneStats.map { stats in
            let darkness = backlightDarkness(for: stats)
            return ToneMeta(
                mean: stats.mean,
                std: stats.std,
                p05: stats.p05,
                p95: stats.p95,
                darkness: darkness,
                upscale: Double(upscale),
                backlightFired: false,
                source: "tightEnhancedRetry"
            )
        }
        let renderSize = ocrRetryRenderSize(for: sourceRect)
        if upscale > 1.0 {
            tight = scalePlateCrop(tight, factor: upscale)
            AppState.devLog("PlateOCR.retry.upscale ×\(String(format: "%.1f", upscale)) tight=\(Int(sourceRect.width))×\(Int(sourceRect.height)) → render=\(Int(renderSize.width))×\(Int(renderSize.height))")
        }

        guard let cgRaw = renderForVision(tight, origW: renderSize.width, origH: renderSize.height,
                                          allowAutoScale: upscale <= 1.0) else {
            return []
        }

        // Pre-Vision mask paint — tight retry rebudovává Vision request z surového
        // CIImage, takže masky musíme aplikovat tady (primary pass je paint-uje
        // separátně). Masky jsou normalized k full workspace (sourceW×sourceH),
        // reprojektujeme do tight-rect coord.
        let cg: CGImage = {
            guard !exclusionMasks.isEmpty else { return cgRaw }
            let localMasks: [CGRect] = exclusionMasks.compactMap { m in
                let maskPx = CGRect(x: m.origin.x * sourceW, y: m.origin.y * sourceH,
                                    width: m.size.width * sourceW, height: m.size.height * sourceH)
                let inter = maskPx.intersection(sourceRect)
                guard !inter.isNull, !inter.isEmpty, inter.width > 0, inter.height > 0 else {
                    return nil
                }
                return CGRect(
                    x: (inter.minX - sourceRect.minX) / sourceRect.width,
                    y: (inter.minY - sourceRect.minY) / sourceRect.height,
                    width: inter.width / sourceRect.width,
                    height: inter.height / sourceRect.height)
            }
            return localMasks.isEmpty ? cgRaw : paintMasksOver(cgRaw, masks: localMasks)
        }()

        // Druhý Vision request — stejný setup jako primary pass, revision default.
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false
        req.recognitionLanguages = []
        if !customWords.isEmpty {
            req.customWords = Array(customWords.prefix(50))
        }
        req.minimumTextHeight = max(Float(minTextHeightPx / renderSize.height), 0.02)
        do { try handler.perform([req]) } catch { return [] }

        let tightMinObsH = sourceRect.height * minObsHeightFraction
        var out: [WorkObs] = []
        for obs in (req.results ?? []) {
            let cands = obs.topCandidates(topCandidateCount)
            guard let top = cands.first else { continue }
            var normSeq: [String] = []
            for c in cands {
                let n = normalize(c.string)
                if !n.isEmpty && !normSeq.contains(n) { normSeq.append(n) }
            }
            guard let primary = normSeq.first else { continue }
            let alts = Array(normSeq.dropFirst())
            let candidateTexts = [primary] + alts
            let plausible = candidateTexts.contains(where: isPlausiblePlateText)
            let similar = expectedTexts.isEmpty
                || candidateTexts.contains { cand in
                    expectedTexts.contains { base in isSimilarPlateText(cand, base) }
                }
            guard plausible, similar else { continue }

            let nbb = obs.boundingBox
            // workBox v tight-space (TL origin, pixels).
            let tightWBox = CGRect(
                x: nbb.origin.x * sourceRect.width,
                y: (1.0 - nbb.origin.y - nbb.size.height) * sourceRect.height,
                width: nbb.size.width * sourceRect.width,
                height: nbb.size.height * sourceRect.height
            )
            if tightWBox.height < tightMinObsH { continue }
            let aspect = tightWBox.width / max(tightWBox.height, 1)
            if aspect > maxObsAspect { continue }
            // Remap tight-space workBox → full source workspace (translate).
            let sourceWBox = CGRect(
                x: tightWBox.minX + sourceRect.minX,
                y: tightWBox.minY + sourceRect.minY,
                width: tightWBox.width, height: tightWBox.height
            )
            out.append(WorkObs(text: primary, altTexts: alts,
                               confidence: top.confidence,
                               workBox: sourceWBox,
                               origin: .passTwoEnhanced,
                               isStrictValidCz: isStrictValidCzCandidate(primary, alts: alts),
                               toneMeta: toneMeta))
        }
        return out
    }
}
