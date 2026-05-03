import SwiftUI
import AppKit
import CoreImage

/// Interaktivní 2-fázová kalibrace 8-DOF perspektivy.
///
/// **Fáze A (free, modré dots):** 4 body volně přes ROI crop. Uživatel je
/// přetáhne na 4 rohy referenční SPZ kterou v cropu vidí. Image stojí.
/// **Fáze B (locked, zelené dots):** sourceQuad zafixován; drag bodů
/// real-time deformuje obraz přes 8-DOF homografii (source → destination).
/// Tlačítko **Odemknout zpět** vrátí do fáze A bez zahození bodů.
/// **Uložit** → uloží `(sourceQuad, destinationQuad)` do `RoiBox.perspectiveCalibration`.
struct InteractivePerspectiveCalibration: View {
    let cameraName: String
    let camera: CameraService
    @Binding var isPresented: Bool
    @EnvironmentObject var state: AppState

    @StateObject private var vm = RoiPreviewVM()
    /// 4 body v normalized [0,1] coords nad ROI cropem (TL-origin).
    /// Pořadí: TL, TR, BR, BL.
    @State private var points: [CGPoint] = [
        CGPoint(x: 0.30, y: 0.35),
        CGPoint(x: 0.70, y: 0.35),
        CGPoint(x: 0.70, y: 0.65),
        CGPoint(x: 0.30, y: 0.65),
    ]
    /// Source quad zafixovaný v Stage B. nil = Stage A.
    @State private var lockedSource: [CGPoint]? = nil
    /// Index bodu právě tažený — kreslí se vodítka V+H.
    @State private var draggingIndex: Int? = nil
    /// Lupa kolem kursoru — 2× zoom rectangle.
    @State private var showLoupe: Bool = true
    /// Pozice lupy — TL-origin v normalized coords cropu (kde je drag aktuálně).
    @State private var loupeAt: CGPoint? = nil
    /// V/H guideline overlay toggle.
    @State private var showGuides: Bool = true
    /// Zoom + pan stack přes ROI náhled (kolečko myši = zoom-to-cursor,
    /// drag mimo úchyty = pan, pinch = zoom).
    @StateObject private var zoomPan = ZoomPanController()

    private let dotRadius: CGFloat = 9

    private var isStageB: Bool { lockedSource != nil }
    private var roi: RoiBox? {
        state.cameras.first(where: { $0.name == cameraName })?.roi
    }

    /// True pokud polygon TL→TR→BR→BL je convex a nepřekřížený. Drag jednoho
    /// bodu přes druhý vyrobí self-intersection — solver to numericky vyřeší,
    /// ale image deformace bývá nesmyslná. Heuristika: všechny 3 cross-producty
    /// po sobě jdoucích hran musí mít stejné znaménko.
    private var polygonValid: Bool {
        let p = points
        guard p.count == 4 else { return false }
        func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        let c0 = cross(p[3], p[0], p[1])
        let c1 = cross(p[0], p[1], p[2])
        let c2 = cross(p[1], p[2], p[3])
        let c3 = cross(p[2], p[3], p[0])
        let signs = [c0, c1, c2, c3].map { $0 > 0 }
        return signs.allSatisfy { $0 == signs[0] }
    }

    var body: some View {
        ZStack {
            // Background dim — overlay přes celé okno.
            Color.black.opacity(0.92).ignoresSafeArea()

            VStack(spacing: 12) {
                header

                GeometryReader { geo in
                    let imgSize = aspectFit(image: vm.image?.size,
                                            container: geo.size)
                    // Aspect-fit centruje image v ZStacku. Dots .position() jsou
                    // ale v ZStack TL-origin coords → musíme přidat origin offset
                    // aby seděly s Path/Image (centered .frame(imgSize)).
                    let originX = (geo.size.width - imgSize.width) / 2
                    let originY = (geo.size.height - imgSize.height) / 2
                    ZStack {
                        Color.black.opacity(0.7)

                        // Zoom-able content layer — image + overlays + dots.
                        ZStack {
                            if let img = displayedImage(for: vm.image) {
                                Image(nsImage: img)
                                    .resizable()
                                    .interpolation(.medium)
                                    .frame(width: imgSize.width, height: imgSize.height)
                            } else {
                                ProgressView().controlSize(.large).tint(.white)
                            }

                            // Guidelines through the dragged point (V + H crosshair).
                            if showGuides, let idx = draggingIndex {
                                let p = points[idx]
                                let local = pixel(p, in: imgSize)
                                Path { path in
                                    path.move(to: CGPoint(x: 0, y: local.y))
                                    path.addLine(to: CGPoint(x: imgSize.width, y: local.y))
                                    path.move(to: CGPoint(x: local.x, y: 0))
                                    path.addLine(to: CGPoint(x: local.x, y: imgSize.height))
                                }
                                .stroke(Color.cyan.opacity(0.7),
                                        style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                                .frame(width: imgSize.width, height: imgSize.height)
                                .allowsHitTesting(false)
                            }

                            // 4-corner polygon connecting dots.
                            Path { path in
                                for (i, p) in points.enumerated() {
                                    let local = pixel(p, in: imgSize)
                                    if i == 0 { path.move(to: local) }
                                    else { path.addLine(to: local) }
                                }
                                path.closeSubpath()
                            }
                            .stroke(isStageB ? Color.green : Color.cyan,
                                    style: StrokeStyle(lineWidth: 1.5, dash: isStageB ? [] : [3, 3]))
                            .frame(width: imgSize.width, height: imgSize.height)
                            .allowsHitTesting(false)

                            // Draggable dots — pozice v ZStack absolute coords
                            // (originX/Y offset aby seděly s centered image).
                            // Kulička je **diagonálně mimo roh polygonu** směrem
                            // ven od centroidu, aby roh polygonu zůstal viditelný.
                            // Drag pak inverzně odečte offset, takže corner sleduje
                            // kurzor a kulička drží svůj outside-offset.
                            let centroid = CGPoint(
                                x: points.reduce(0) { $0 + $1.x } / 4,
                                y: points.reduce(0) { $0 + $1.y } / 4)
                            ForEach(0..<4, id: \.self) { i in
                                let p = points[i]
                                let cx = originX + p.x * imgSize.width
                                let cy = originY + p.y * imgSize.height
                                let dx = (p.x - centroid.x) * imgSize.width
                                let dy = (p.y - centroid.y) * imgSize.height
                                let len = max(0.001, sqrt(dx * dx + dy * dy))
                                let outDist: CGFloat = dotRadius + 8
                                let offX = dx / len * outDist
                                let offY = dy / len * outDist
                                ZStack {
                                    Circle()
                                        .fill(isStageB ? Color.green : Color.cyan)
                                        .frame(width: dotRadius * 2, height: dotRadius * 2)
                                    Circle()
                                        .stroke(Color.white, lineWidth: 1.5)
                                        .frame(width: dotRadius * 2, height: dotRadius * 2)
                                    Text(["TL","TR","BR","BL"][i])
                                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Color.black)
                                }
                                .position(x: cx + offX, y: cy + offY)
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { val in
                                            draggingIndex = i
                                            // Cursor je na kuličce (corner + offset).
                                            // Skutečný corner = location - offset.
                                            let nx = max(-0.05, min(1.05, (val.location.x - offX - originX) / imgSize.width))
                                            let ny = max(-0.05, min(1.05, (val.location.y - offY - originY) / imgSize.height))
                                            points[i] = CGPoint(x: nx, y: ny)
                                            loupeAt = points[i]
                                        }
                                        .onEnded { _ in
                                            draggingIndex = nil
                                            loupeAt = nil
                                        }
                                )
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .zoomPan(zoomPan)

                        // Lupa a zoom badge — mimo zoomable layer (fixed UI).
                        if showLoupe, let l = loupeAt, let nsImg = vm.image {
                            loupeView(nsImg: nsImg, at: l, container: imgSize)
                                .frame(width: 140, height: 140)
                                .position(x: geo.size.width - 80, y: 80)
                                .allowsHitTesting(false)
                        }
                        if zoomPan.scale > 1.01 {
                            VStack {
                                HStack {
                                    Button(action: { zoomPan.reset() }) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "arrow.up.left.and.arrow.down.right.magnifyingglass")
                                                .font(.system(size: 10))
                                            Text(String(format: "%.1f×", zoomPan.scale))
                                                .font(.system(size: 10, design: .monospaced))
                                        }
                                        .foregroundStyle(Color.white)
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(Capsule().fill(Color.black.opacity(0.7)))
                                    }.buttonStyle(.plain)
                                    .help("Reset zoomu (1×)")
                                    Spacer()
                                }
                                Spacer()
                            }
                            .padding(8)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 24)

                controlsBar
            }
            .padding(.vertical, 18)
        }
        .onAppear {
            if let calib = roi?.perspectiveCalibration,
               calib.sourceQuad.count == 4,
               calib.destinationQuad.count == 4 {
                lockedSource = calib.sourceQuad
                points = calib.destinationQuad
            }
            vm.camera = camera
            vm.roi = roi
            // 8-DOF editor musí běžet nad obrazem PŘED 8-DOF a před detection
            // cropem. Jinak by uživatel editoval výsledek vlastní kalibrace a
            // při uložení by se transformace skládala dvakrát.
            vm.applyPerspectiveCalibration = false
            vm.applyDetectionQuad = false
            // Pokud je nastaven zmrazený screenshot, edituj nad ním (statický).
            vm.frozenFrame = state.frozenFrames[cameraName]
            vm.start()
        }
        .onDisappear { vm.stop() }
    }

    // MARK: - Header / controls

    private var header: some View {
        HStack(spacing: 12) {
            Text("KALIBRACE PERSPEKTIVY")
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .tracking(2)
                .foregroundStyle(.white)
            Text(isStageB ? "Fáze B — locked" : "Fáze A — free")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(isStageB ? Color.green.opacity(0.7) : Color.cyan.opacity(0.7)))
                .foregroundStyle(.black)
            Spacer()
            Toggle("Vodítka", isOn: $showGuides)
                .toggleStyle(.switch)
                .controlSize(.small)
                .foregroundStyle(.white)
            Toggle("Lupa", isOn: $showLoupe)
                .toggleStyle(.switch)
                .controlSize(.small)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 24)
    }

    private var controlsBar: some View {
        HStack(spacing: 14) {
            Button("Zrušit") { isPresented = false }
                .keyboardShortcut(.escape, modifiers: [])

            Spacer()

            if !polygonValid {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Pořadí bodů: polygon překřížený")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Color.yellow)
            } else {
                Text(isStageB
                     ? "Tahej body — obraz se deformuje. Zelené body = kam se má SPZ vyrovnat. (kolečko = zoom · tažení mimo body = posun)"
                     : "Najdi referenční SPZ. Přetáhni 4 modré body na její rohy (TL/TR/BR/BL). (kolečko = zoom · tažení mimo body = posun)")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.75))
            }

            Spacer()

            if isStageB {
                Button("Odemknout zpět") {
                    lockedSource = nil
                }
                .tint(.orange)
                Button("Reset destination") {
                    if let src = lockedSource { points = src }
                }
            } else {
                Button("Reset body") {
                    points = [
                        CGPoint(x: 0.30, y: 0.35),
                        CGPoint(x: 0.70, y: 0.35),
                        CGPoint(x: 0.70, y: 0.65),
                        CGPoint(x: 0.30, y: 0.65),
                    ]
                }
                Button("Zamknout (Fáze B)") {
                    lockedSource = points
                }
                .keyboardShortcut(.return, modifiers: [])
                .tint(.cyan)
            }

            Button("Uložit") { save() }
                .tint(.green)
                .disabled(!isStageB || !polygonValid)
                .keyboardShortcut("s", modifiers: .command)
        }
        .buttonStyle(.borderedProminent)
        .padding(.horizontal, 24)
    }

    // MARK: - Image rendering (Stage A vs B)

    /// Stage A → vrátí raw image jak je.
    /// Stage B → aplikuje 8-DOF homografii source (locked) → current points.
    private func displayedImage(for nsImg: NSImage?) -> NSImage? {
        guard let nsImg else { return nil }
        guard let lockedSrc = lockedSource else { return nsImg }
        guard let cg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nsImg }
        let ci = CIImage(cgImage: cg)
        let extent = ci.extent
        // Konvertuj normalized (TL-origin) → CIImage (BL-origin) pixel coords.
        let toCi = { (p: CGPoint) -> CGPoint in
            CGPoint(x: p.x * extent.width, y: (1 - p.y) * extent.height)
        }
        let src = lockedSrc.map(toCi)
        let dst = points.map(toCi)
        guard let warped = PerspectiveTransform.apply(ci, source: src, destination: dst) else {
            return nsImg
        }
        // Warped output má potenciálně extent mimo původní rect → guard proti
        // infinite/null extentu (degenerate homografie). Sdílený CIContext.
        let outExt = warped.extent.intersection(extent)
        guard !outExt.isInfinite, !outExt.isNull else { return nsImg }
        guard let outCG = SharedCIContext.shared.createCGImage(warped, from: extent) else {
            return nsImg
        }
        return NSImage(cgImage: outCG, size: NSSize(width: outCG.width, height: outCG.height))
    }

    // MARK: - Lupa (2× zoom around drag point)

    @ViewBuilder
    private func loupeView(nsImg: NSImage, at p: CGPoint, container: CGSize) -> some View {
        // 2× zoom — okno 70 × 70 px nativní, vykreslené do 140 × 140.
        let pxX = p.x * nsImg.size.width
        let pxY = p.y * nsImg.size.height
        let half: CGFloat = 35
        let srcRect = CGRect(x: pxX - half, y: pxY - half, width: half * 2, height: half * 2)
        ZStack {
            // Crop preview — Image-level masking.
            Image(nsImage: nsImg)
                .interpolation(.none)
                .resizable()
                .scaleEffect(2)
                .frame(width: nsImg.size.width * 2, height: nsImg.size.height * 2)
                .offset(x: -pxX * 2 + 70, y: -pxY * 2 + 70)
                .clipped()
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white, lineWidth: 1.5))
                .background(Color.black)
            // Crosshair v centru lupy.
            Path { path in
                path.move(to: CGPoint(x: 70, y: 50)); path.addLine(to: CGPoint(x: 70, y: 90))
                path.move(to: CGPoint(x: 50, y: 70)); path.addLine(to: CGPoint(x: 90, y: 70))
            }
            .stroke(Color.cyan, lineWidth: 1)
        }
        // Reference srcRect (informational only — frame already controlled above).
        .help("Lupa 2× kolem bodu (\(Int(srcRect.minX)),\(Int(srcRect.minY)))")
    }

    // MARK: - Helpers

    /// Aspect-fit cropu do containeru. Vrací reálné UI rozměry (jak je SwiftUI
    /// vykreslí) — pomocné pro mapování normalized→local pixel coords.
    private func aspectFit(image size: NSSize?, container: CGSize) -> CGSize {
        guard let s = size, s.width > 0, s.height > 0 else { return container }
        let imgAspect = s.width / s.height
        let conAspect = container.width / container.height
        if imgAspect > conAspect {
            return CGSize(width: container.width, height: container.width / imgAspect)
        } else {
            return CGSize(width: container.height * imgAspect, height: container.height)
        }
    }

    /// Normalized [0,1] → local pixel v aktuálním image frame.
    private func pixel(_ p: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: p.x * size.width, y: p.y * size.height)
    }

    private func save() {
        guard isStageB, let src = lockedSource else { return }
        let calib = PerspectiveCalibration(sourceQuad: src, destinationQuad: points)
        state.setRoiPerspectiveCalibration(name: cameraName, calibration: calib)
        isPresented = false
    }
}
