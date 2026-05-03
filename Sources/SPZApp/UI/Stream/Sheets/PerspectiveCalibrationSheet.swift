import SwiftUI

/// PerspectiveCalibrationSheet — 4 rohy přes rotovaný ROI crop.
/// Extracted ze StreamView.swift jako součást big-refactor split (krok #10).

// MARK: - PerspectiveCalibrationSheet — 4 rohy přes rotovaný ROI crop

/// Kalibrace perspektivní korekce. Zobrazuje živý náhled rotovaného ROI
/// cropu + 4 draggable úchyty v rozích. Uživatel je přetáhne na rohy reálné
/// SPZ v záběru → `CIFilter.perspectiveCorrection` pak každý frame aplikuje
/// reverzní homografii a Vision dostává plate v čelním pohledu.
///
/// Souřadnice rohů jsou ukládány v normalized [0,1] prostoru ROI cropu.
struct PerspectiveCalibrationSheet: View {
    let cameraName: String
    @ObservedObject var camera: CameraService
    let onClose: () -> Void

    @EnvironmentObject var state: AppState
    @State private var corners: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
        CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)
    ]
    @State private var scaleX: Double = 1.0
    @State private var scaleY: Double = 1.0
    @State private var strength: Double = 1.0
    @State private var offsetX: Double = 0.0
    @State private var offsetY: Double = 0.0
    @State private var previewImage: NSImage? = nil
    @State private var previewTimer: Timer? = nil

    private var myCam: CameraConfig? { state.cameras.first(where: { $0.name == cameraName }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "perspective")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("PERSPEKTIVNÍ KOREKCE")
                        .font(.system(size: 10, weight: .bold)).tracking(1.5)
                        .foregroundStyle(.secondary)
                    Text("Kamera \(myCam?.label ?? cameraName)")
                        .font(.system(size: 14, weight: .semibold))
                }
                Spacer()
            }

            Text("Každý roh ROI má úchyt. Přetažením rohu přímo natáhneš perspektivu obrazu do požadovaného tvaru (ten roh obrazu půjde kam přetáhneš úchyt). Živý náhled ukazuje výsledek.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GeometryReader { geo in
                // Margin okolo zobrazeného obrazu — prostor, kam lze úchyty
                // vytáhnout ven z ROI pro roztažení perspektivy.
                // 35 % každé strany = obraz zabírá jen 30 % šířky/výšky sheetu,
                // zbytek je drag area všemi směry.
                let margin: CGFloat = min(geo.size.width, geo.size.height) * 0.35
                let imgW = max(geo.size.width - 2 * margin, 1)
                let imgH = max(geo.size.height - 2 * margin, 1)
                // Obraz je umístěn centrovaně v geo, margin je drag area.
                let imgOrigin = CGPoint(x: margin, y: margin)
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Color(white: 0.05))

                    // Preview obrázek v centrální části (imgOrigin, imgW × imgH)
                    if let img = previewImage {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: imgW, height: imgH)
                            .clipped()
                            .offset(x: imgOrigin.x, y: imgOrigin.y)
                    } else {
                        Rectangle().fill(Color(white: 0.12))
                            .frame(width: imgW, height: imgH)
                            .offset(x: imgOrigin.x, y: imgOrigin.y)
                        Text("Načítám náhled…")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .frame(width: imgW, height: imgH)
                            .offset(x: imgOrigin.x, y: imgOrigin.y)
                    }

                    // Vnitřní ROI frame (rámec původního obrazu) + polygon rohů.
                    Path { path in
                        path.addRect(CGRect(origin: imgOrigin, size: CGSize(width: imgW, height: imgH)))
                        let pts = corners.map { p in
                            CGPoint(x: imgOrigin.x + p.x * imgW,
                                    y: imgOrigin.y + p.y * imgH)
                        }
                        path.move(to: pts[0])
                        path.addLine(to: pts[1])
                        path.addLine(to: pts[2])
                        path.addLine(to: pts[3])
                        path.closeSubpath()
                    }
                    .stroke(Color.orange, lineWidth: 2)

                    // 4 úchyty — lze táhnout i mimo obraz (do margin prostoru).
                    ForEach(0..<4, id: \.self) { idx in
                        handleView(imgOrigin: imgOrigin, imgW: imgW, imgH: imgH, idx: idx)
                    }
                }
                .background(Color.black)
                // NO .clipped — úchyty musí být viditelné i mimo obraz.
            }
            .frame(minWidth: 500, minHeight: 350)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.15), lineWidth: 1))

            // Live-preview jemné doladění — strength + scale X/Y + offset X/Y.
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    Text("Síla").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .leading)
                    Slider(value: $strength, in: 0.0...2.54, step: 0.01)
                    Text(String(format: "%.0f %%", strength * 100))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 56, alignment: .trailing)
                }
                HStack(spacing: 10) {
                    Text("Scale X").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .leading)
                    Slider(value: $scaleX, in: 0.5...2.0, step: 0.01)
                    Text(String(format: "%.2f×", scaleX))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 56, alignment: .trailing)
                }
                HStack(spacing: 10) {
                    Text("Scale Y").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .leading)
                    Slider(value: $scaleY, in: 0.5...2.0, step: 0.01)
                    Text(String(format: "%.2f×", scaleY))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 56, alignment: .trailing)
                }
                HStack(spacing: 10) {
                    Text("Posun X").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .leading)
                    Slider(value: $offsetX, in: -0.5...0.5, step: 0.005)
                    Text(String(format: "%+.0f %%", offsetX * 100))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 56, alignment: .trailing)
                }
                HStack(spacing: 10) {
                    Text("Posun Y").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .leading)
                    Slider(value: $offsetY, in: -0.5...0.5, step: 0.005)
                    Text(String(format: "%+.0f %%", offsetY * 100))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 56, alignment: .trailing)
                }
            }

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
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: onClose) {
                    Text("Zrušit").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .foregroundStyle(.primary)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.1), lineWidth: 1)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button(action: savePerspective) {
                    Text("Uložit").font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .foregroundStyle(Color.black)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange))
                }
                .buttonStyle(PressAnimationStyle(cornerRadius: 7, flashColor: .white))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 900, height: 780)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [Color(white: 0.10), Color(white: 0.06)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .onAppear {
            loadInitial()
            startPreviewTimer()
        }
        .onDisappear { previewTimer?.invalidate() }
    }

    private func handleView(imgOrigin: CGPoint, imgW: CGFloat, imgH: CGFloat,
                            idx: Int) -> some View {
        // Úchyt v geo coords = imgOrigin + corner_normalized * imgSize.
        let px = imgOrigin.x + corners[idx].x * imgW
        let py = imgOrigin.y + corners[idx].y * imgH
        return Circle()
            .fill(Color.orange)
            .overlay(Circle().stroke(Color.black, lineWidth: 2))
            .frame(width: 20, height: 20)
            .shadow(color: .black.opacity(0.5), radius: 3)
            .position(x: px, y: py)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        // Převed geo coords zpět na normalized corner coords.
                        // Rozsah -1..2 umožní táhnout úchyty výrazně mimo ROI
                        // pro silnou perspektivu.
                        let nx = (value.location.x - imgOrigin.x) / imgW
                        let ny = (value.location.y - imgOrigin.y) / imgH
                        corners[idx] = CGPoint(
                            x: max(-3, min(4, nx)),
                            y: max(-3, min(4, ny))
                        )
                    }
            )
    }

    private func loadInitial() {
        if let p = myCam?.roi?.perspective, !p.isIdentity {
            corners = [p.topLeft, p.topRight, p.bottomRight, p.bottomLeft]
            scaleX = p.scaleX
            scaleY = p.scaleY
            strength = p.strength
            offsetX = p.offsetX
            offsetY = p.offsetY
        }
        refreshPreview()
    }

    private func startPreviewTimer() {
        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in refreshPreview() }
        }
    }

    /// Grab latest full frame → crop by ROI → rotate → APPLY PERSPECTIVE →
    /// to NSImage for preview. User vidí rovnou live výsledek svých úchytů.
    /// Pokud je nastaven zmrazený screenshot, edituje nad ním.
    private func refreshPreview() {
        let pbOpt = state.frozenFrames[cameraName] ?? camera.snapshotLatest()
        guard let pb = pbOpt,
              let roi = myCam?.roi else { return }
        let ci = CIImage(cvPixelBuffer: pb)
        let imgW = ci.extent.width
        let imgH = ci.extent.height
        let clamped = roi.cgRect.intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))
        guard !clamped.isNull else { return }
        let ciRect = CGRect(x: clamped.minX, y: imgH - clamped.maxY,
                            width: clamped.width, height: clamped.height)
        var cropped = ci.cropped(to: ciRect)
            .transformed(by: CGAffineTransform(translationX: -ciRect.minX, y: -ciRect.minY))
        let rot = roi.rotationRadians
        if abs(rot) > 0.001 {
            let cx = clamped.width / 2, cy = clamped.height / 2
            let t = CGAffineTransform(translationX: -cx, y: -cy)
                .concatenating(CGAffineTransform(rotationAngle: rot))
            cropped = cropped.transformed(by: t)
            let ext = cropped.extent
            cropped = cropped.transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
        }
        // Apply perspektivu přímo s aktuálními úchyty + všemi parametry —
        // live preview respektuje strength, scale X/Y, offset X/Y.
        let liveConfig = PerspectiveConfig(
            topLeft: corners[0],
            topRight: corners[1],
            bottomRight: corners[2],
            bottomLeft: corners[3],
            scaleX: scaleX,
            scaleY: scaleY,
            strength: strength,
            offsetX: offsetX,
            offsetY: offsetY
        )
        if !liveConfig.isIdentity {
            if let corrected = PlateOCR.applyPerspective(cropped,
                                                        width: cropped.extent.width,
                                                        height: cropped.extent.height,
                                                        perspective: liveConfig) {
                cropped = corrected
            }
        }
        guard let cg = SharedCIContext.shared.createCGImage(cropped, from: cropped.extent) else { return }
        previewImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private func resetCorners() {
        corners = [
            CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
            CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)
        ]
        scaleX = 1.0
        scaleY = 1.0
        strength = 1.0
        offsetX = 0.0
        offsetY = 0.0
        refreshPreview()  // okamžitý refresh, ne čekat na 0.5 s timer
    }

    private func savePerspective() {
        let p = PerspectiveConfig(
            topLeft: corners[0],
            topRight: corners[1],
            bottomRight: corners[2],
            bottomLeft: corners[3],
            scaleX: scaleX,
            scaleY: scaleY,
            strength: strength,
            offsetX: offsetX,
            offsetY: offsetY
        )
        state.setRoiPerspective(name: cameraName, perspective: p.isIdentity ? nil : p)
        onClose()
    }
}
