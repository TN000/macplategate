import SwiftUI

/// DetectionAreaSheet — finální oblast detekce (4 body uvnitř korigovaného ROI).
/// Extracted ze StreamView.swift jako součást big-refactor split (krok #10).

// MARK: - DetectionAreaSheet — finální oblast detekce (4 body uvnitř korigovaného ROI)

/// Kalibrace konečné oblasti detekce. Na rozdíl od PerspectiveCalibrationSheet
/// ukazuje náhled PO aplikaci perspektivní korekce včetně 8-DOF — user vidí
/// už srovnaný obraz. 4 úchyty definují axis-aligned bbox, uvnitř kterého
/// poběží OCR.
struct DetectionAreaSheet: View {
    let cameraName: String
    @ObservedObject var camera: CameraService
    let onClose: () -> Void

    @EnvironmentObject var state: AppState
    @State private var corners: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
        CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)
    ]
    @State private var previewImage: NSImage? = nil
    @State private var previewTimer: Timer? = nil
    @StateObject private var zoomPan = ZoomPanController()

    private var myCam: CameraConfig? { state.cameras.first(where: { $0.name == cameraName }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.cyan)
                VStack(alignment: .leading, spacing: 3) {
                    Text("OBLAST DETEKCE")
                        .font(.system(size: 10, weight: .bold)).tracking(1.5)
                        .foregroundStyle(.secondary)
                    Text("Kamera \(myCam?.label ?? cameraName)")
                        .font(.system(size: 14, weight: .semibold))
                }
                Spacer()
            }

            Text("Náhled ukazuje ROI PO perspektivní korekci včetně 8-DOF narovnání. Přetáhni 4 úchyty tak, aby obklopily oblast, kde se čte SPZ. OCR poběží jen v axis-aligned bbox těchto bodů — šetří CPU a snižuje false-positives z okolí.\n• Kolečko myši nebo pinch = zoom (až 8×) · tažení mimo úchyty = posun.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GeometryReader { geo in
                // Vypočti skutečný image display rect uvnitř geo při aspect-fit.
                // Bez tohohle výpočtu úchyty pracují v geo prostoru (včetně
                // letterbox), ale runtime crop aplikuje normalized coords
                // na image pixels → user vybere plate, ale crop je jinde.
                let imgRect = imageDisplayRect(in: geo.size)
                ZStack {
                    Color.black
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(Color(white: 0.05))
                        if let img = previewImage {
                            Image(nsImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: geo.size.width, height: geo.size.height)
                        } else {
                            Text("Načítám náhled…")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .frame(width: geo.size.width, height: geo.size.height)
                        }
                        // Quad polygon overlay — v image rect coords, ne geo.
                        Path { path in
                            let pts = corners.map { p in
                                CGPoint(x: imgRect.minX + p.x * imgRect.width,
                                        y: imgRect.minY + p.y * imgRect.height)
                            }
                            path.move(to: pts[0])
                            path.addLine(to: pts[1])
                            path.addLine(to: pts[2])
                            path.addLine(to: pts[3])
                            path.closeSubpath()
                        }
                        .stroke(Color.cyan, lineWidth: 2)
                        // Bbox rámeček (co skutečně půjde do OCR) — také v image rect.
                        Path { path in
                            let xs = corners.map { $0.x }, ys = corners.map { $0.y }
                            let minX = xs.min() ?? 0, maxX = xs.max() ?? 1
                            let minY = ys.min() ?? 0, maxY = ys.max() ?? 1
                            path.addRect(CGRect(
                                x: imgRect.minX + minX * imgRect.width,
                                y: imgRect.minY + minY * imgRect.height,
                                width: (maxX - minX) * imgRect.width,
                                height: (maxY - minY) * imgRect.height))
                        }
                        .stroke(Color.cyan.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
                        // 4 handles — poziční i drag coords relativní k image rect.
                        ForEach(0..<4, id: \.self) { idx in
                            handleView(imgRect: imgRect, idx: idx)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .zoomPan(zoomPan)
                    if zoomPan.scale > 1.01 {
                        VStack {
                            HStack {
                                Spacer()
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
                            }
                            Spacer()
                        }
                        .padding(8)
                        .allowsHitTesting(true)
                    }
                }
                .clipped()
            }
            .frame(minWidth: 600, minHeight: 380)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.15), lineWidth: 1))

            Text("Přerušovaný rámeček = skutečná oblast kde poběží OCR (axis-aligned bbox 4 bodů).")
                .font(.system(size: 10)).foregroundStyle(.tertiary)

            HStack(spacing: 8) {
                Button(action: { resetCorners() }) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 10))
                        Text("Reset").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.1), lineWidth: 1)))
                }.buttonStyle(.plain)
                Spacer()
                Button(action: onClose) {
                    Text("Zrušit").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .foregroundStyle(.primary)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.1), lineWidth: 1)))
                }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
                Button(action: saveQuad) {
                    Text("Uložit").font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .foregroundStyle(Color.black)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.cyan))
                }.buttonStyle(PressAnimationStyle(cornerRadius: 7, flashColor: .white)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 720, height: 640)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [Color(white: 0.10), Color(white: 0.06)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .onAppear { loadInitial(); startTimer() }
        .onDisappear { previewTimer?.invalidate() }
    }

    private func handleView(imgRect: CGRect, idx: Int) -> some View {
        // Centroid polygonu (v normalized image coords) — kulička se odsouvá
        // diagonálně **mimo roh** směrem ven od centroidu, aby roh quadu zůstal
        // viditelný. Drag inverzně odečte offset.
        let cxN = corners.reduce(0) { $0 + $1.x } / 4
        let cyN = corners.reduce(0) { $0 + $1.y } / 4
        let cornerX = imgRect.minX + corners[idx].x * imgRect.width
        let cornerY = imgRect.minY + corners[idx].y * imgRect.height
        let dx = (corners[idx].x - cxN) * imgRect.width
        let dy = (corners[idx].y - cyN) * imgRect.height
        let len = max(0.001, sqrt(dx * dx + dy * dy))
        // Match dotRadius+8 vzorec z PerspectiveCalibrationView; dot frame=20
        // (radius=10) → outDist 18 = 8 px gap mezi corner a hranou kuličky.
        let outDist: CGFloat = 18
        let offX = dx / len * outDist
        let offY = dy / len * outDist
        return Circle()
            .fill(Color.cyan)
            .overlay(Circle().stroke(Color.black, lineWidth: 2))
            .frame(width: 20, height: 20)
            .shadow(color: .black.opacity(0.5), radius: 3)
            .position(x: cornerX + offX, y: cornerY + offY)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        // Cursor sleduje kuličku, ale corner je offset zpět.
                        let nx = (value.location.x - offX - imgRect.minX) / imgRect.width
                        let ny = (value.location.y - offY - imgRect.minY) / imgRect.height
                        corners[idx] = CGPoint(
                            x: max(0, min(1, nx)),
                            y: max(0, min(1, ny))
                        )
                    }
            )
    }

    /// Spočte skutečný obdélník kde je image zobrazený uvnitř geo plochy.
    /// aspect-fit centrování — letterbox top/bottom nebo pillarbox left/right.
    private func imageDisplayRect(in size: CGSize) -> CGRect {
        guard let img = previewImage, img.size.width > 0, img.size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let imgAspect = img.size.width / img.size.height
        let geoAspect = size.width / max(size.height, 0.001)
        if imgAspect > geoAspect {
            // Fills width, letterbox vertical.
            let h = size.width / imgAspect
            let y = (size.height - h) / 2
            return CGRect(x: 0, y: y, width: size.width, height: h)
        } else {
            // Fills height, pillarbox horizontal.
            let w = size.height * imgAspect
            let x = (size.width - w) / 2
            return CGRect(x: x, y: 0, width: w, height: size.height)
        }
    }

    private func loadInitial() {
        if let dq = myCam?.roi?.detectionQuad, dq.count == 4 {
            corners = dq
        }
        refreshPreview()
    }

    private func startTimer() {
        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in refreshPreview() }
        }
    }

    /// Preview = ROI crop + rotace + perspektiva + 8-DOF (stejný pipeline jako
    /// OCR před detekčním cropem). User tak vidí přesně prostor, ve kterém
    /// nastavuje finální detection bbox. Respektuje zmrazený screenshot.
    private func refreshPreview() {
        let pbOpt = state.frozenFrames[cameraName] ?? camera.snapshotLatest()
        guard let pb = pbOpt,
              let roi = myCam?.roi else { return }
        guard let cropped = RoiTransformRenderer.renderCIImage(
            from: pb,
            roi: roi,
            options: .init(applyPerspectiveCalibration: true,
                           applyDetectionQuad: false,
                           maxOutputWidth: nil)
        ) else { return }
        guard let cg = SharedCIContext.shared.createCGImage(cropped, from: cropped.extent) else { return }
        previewImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private func resetCorners() {
        corners = [
            CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
            CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)
        ]
        refreshPreview()
    }

    private func saveQuad() {
        // Validace — quad musí mít platnou bbox geometrii (min < max v obou osách).
        let xs = corners.map { $0.x }, ys = corners.map { $0.y }
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 1
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 1
        guard maxX - minX > 0.02, maxY - minY > 0.02 else {
            // Degenerate geometrie (např. všechny body slepené) — ignorovat.
            FileHandle.safeStderrWrite(
                "[DetectionQuad] ignored invalid geometry (bbox too small)\n".data(using: .utf8) ?? Data())
            return
        }
        // Kontrola: pokud 4 rohy jsou ~ rohy ROI, uložit nil (no-op).
        let eps = 0.01
        let isFull =
            corners[0].x < eps && corners[0].y < eps &&
            corners[1].x > 1 - eps && corners[1].y < eps &&
            corners[2].x > 1 - eps && corners[2].y > 1 - eps &&
            corners[3].x < eps && corners[3].y > 1 - eps
        state.setRoiDetectionQuad(name: cameraName, quad: isFull ? nil : corners)
        onClose()
    }
}
