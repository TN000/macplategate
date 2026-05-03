import SwiftUI
import AppKit
import CoreGraphics
import CoreImage

/// Editor exclusion mask obdélníků uvnitř detection quad oblasti.
///
/// Use case: na ROI cropu jsou opakované statické texty (banner „ZIMNÍ
/// STADION PŘÍBRAM", logo, cedule, reklamní tabule) co Vision OCR pořád
/// čte. Normalizer je sice odmítne (nevalidní CZ formát), ale OCR cyklus
/// + log spam zbytečně zatěžuje CPU. Maska říká „neber observation které
/// padnou do tohoto obdélníku".
///
/// Souřadnice masek: normalized [0,1] TL-origin **relative k post-perspective
/// + post-detectionQuad workspace** — stejný coord space co Vision vrátí v
/// `obs.bbox`. PlateOCR.recognize masky aplikuje (line 581+).
struct ExclusionMaskSheet: View {
    let cameraName: String
    @ObservedObject var camera: CameraService
    let onClose: () -> Void

    @EnvironmentObject var state: AppState
    @State private var masks: [CGRect] = []
    @State private var dragStart: CGPoint? = nil
    @State private var dragCurrent: CGPoint? = nil
    /// `true` = Shift byl zmáčknutý při drag startu → ten celý drag je pan
    /// (delegovaný ZoomPan modifier-u), nekreslíme masku. Bez tohoto stavu
    /// by user toggling Shift mid-drag korumpoval gesture state.
    @State private var dragIsPan: Bool = false
    @State private var previewImage: NSImage? = nil
    @State private var previewTimer: Timer? = nil
    @StateObject private var zoomPan = ZoomPanController()

    private var myCam: CameraConfig? { state.cameras.first(where: { $0.name == cameraName }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Text("Tažením myši přes obraz nakresli obdélník kolem statického textu (banner, logo). Vision text observations uvnitř masky se ignorují. Můžeš nakreslit víc masek (max 16). Existující smažeš tlačítkem v seznamu vpravo.\n• Kolečko myši nebo pinch = zoom (až 8×)\n• Shift + tažení = posun zoomovaného obrazu")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 12) {
                drawingArea
                masksList
                    .frame(width: 200)
            }

            controlBar
        }
        .padding(22)
        .frame(width: 920, height: 680)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [Color(white: 0.10), Color(white: 0.06)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .onAppear { loadInitial(); startTimer() }
        .onDisappear { previewTimer?.invalidate() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 22))
                .foregroundStyle(Color.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("MASKY VÝJIMEK")
                    .font(.system(size: 10, weight: .bold)).tracking(1.5)
                    .foregroundStyle(.secondary)
                Text("Kamera \(myCam?.label ?? cameraName)")
                    .font(.system(size: 14, weight: .semibold))
            }
            Spacer()
            Text("\(masks.count)/16")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Drawing area

    private var drawingArea: some View {
        GeometryReader { geo in
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

                    // Existing masks (red filled with stroke).
                    ForEach(0..<masks.count, id: \.self) { idx in
                        let m = masks[idx]
                        Rectangle()
                            .fill(Color.red.opacity(0.25))
                            .overlay(Rectangle().stroke(Color.red, lineWidth: 1.5))
                            .frame(width: m.width * imgRect.width,
                                   height: m.height * imgRect.height)
                            .position(x: imgRect.minX + (m.minX + m.width / 2) * imgRect.width,
                                      y: imgRect.minY + (m.minY + m.height / 2) * imgRect.height)
                            .allowsHitTesting(false)
                    }

                    // In-progress drag rectangle (cyan dashed).
                    if let s = dragStart, let c = dragCurrent {
                        let r = normalizedRect(start: s, current: c, in: imgRect)
                        Rectangle()
                            .fill(Color.cyan.opacity(0.18))
                            .overlay(Rectangle().stroke(Color.cyan,
                                                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                            .frame(width: r.width * imgRect.width,
                                   height: r.height * imgRect.height)
                            .position(x: imgRect.minX + (r.minX + r.width / 2) * imgRect.width,
                                      y: imgRect.minY + (r.minY + r.height / 2) * imgRect.height)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { val in
                            // Capture Shift state at drag start — pak je pan
                            // / draw režim konzistentní po celý drag i když
                            // user toggle Shift mid-tahem.
                            if dragStart == nil && val.translation == .zero {
                                dragIsPan = NSEvent.modifierFlags.contains(.shift)
                            }
                            if dragIsPan { return }     // Shift+drag → pan vyřídí ZoomPan modifier
                            guard imgRect.contains(val.startLocation) else { return }
                            if dragStart == nil { dragStart = val.startLocation }
                            dragCurrent = val.location
                        }
                        .onEnded { val in
                            defer { dragIsPan = false }
                            if dragIsPan { return }
                            if let s = dragStart {
                                let r = normalizedRect(start: s, current: val.location, in: imgRect)
                                // Min size guard — drobný klik bez tahnutí ne-vytvoří mask.
                                if r.width > 0.01, r.height > 0.01, masks.count < 16 {
                                    masks.append(r)
                                }
                            }
                            dragStart = nil
                            dragCurrent = nil
                        }
                )
                .zoomPan(zoomPan, dragPan: false)
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
                }
            }
            .clipped()
        }
        .frame(minWidth: 580, minHeight: 380)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.15), lineWidth: 1))
    }

    /// Normalized rect [0,1] z 2 geo bodů. TL-origin, clampovaný na imgRect.
    private func normalizedRect(start: CGPoint, current: CGPoint, in imgRect: CGRect) -> CGRect {
        let x1 = max(imgRect.minX, min(imgRect.maxX, start.x))
        let y1 = max(imgRect.minY, min(imgRect.maxY, start.y))
        let x2 = max(imgRect.minX, min(imgRect.maxX, current.x))
        let y2 = max(imgRect.minY, min(imgRect.maxY, current.y))
        let nx = (min(x1, x2) - imgRect.minX) / imgRect.width
        let ny = (min(y1, y2) - imgRect.minY) / imgRect.height
        let nw = abs(x2 - x1) / imgRect.width
        let nh = abs(y2 - y1) / imgRect.height
        return CGRect(x: nx, y: ny, width: nw, height: nh)
    }

    // MARK: - Masks list (right column)

    private var masksList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ULOŽENÉ MASKY")
                .font(.system(size: 10, weight: .bold)).tracking(1.2)
                .foregroundStyle(.secondary)
            if masks.isEmpty {
                Text("Žádná maska. Nakresli obdélník myší v náhledu.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(0..<masks.count, id: \.self) { idx in
                            maskRow(idx: idx)
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color.white.opacity(0.04))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)))
    }

    private func maskRow(idx: Int) -> some View {
        let m = masks[idx]
        return HStack(spacing: 6) {
            Text("\(idx + 1)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .frame(width: 18)
                .foregroundStyle(Color.orange)
            Text(String(format: "%.2f,%.2f %.2f×%.2f", m.minX, m.minY, m.width, m.height))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: { masks.remove(at: idx) }) {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Smazat tuto masku")
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.08)))
    }

    // MARK: - Control bar

    private var controlBar: some View {
        HStack(spacing: 8) {
            Button(action: { masks = [] }) {
                HStack(spacing: 5) {
                    Image(systemName: "trash").font(.system(size: 10))
                    Text("Smazat vše").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.1), lineWidth: 1)))
            }
            .buttonStyle(.plain)
            .disabled(masks.isEmpty)

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

            Button(action: save) {
                Text("Uložit (\(masks.count))").font(.system(size: 12, weight: .bold))
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .foregroundStyle(Color.black)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Preview

    private func loadInitial() {
        masks = myCam?.roi?.exclusionMasks ?? []
        refreshPreview()
    }

    private func startTimer() {
        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in refreshPreview() }
        }
    }

    private func refreshPreview() {
        // Stejný transform stack jako DetectionAreaSheet — user vidí přesně
        // workspace co Vision dostane (post-rotation + post-perspective +
        // post-detectionQuad). Masky jsou v tomto coord space.
        let pbOpt = state.frozenFrames[cameraName] ?? camera.snapshotLatest()
        guard let pb = pbOpt, let roi = myCam?.roi else { return }
        guard let cropped = RoiTransformRenderer.renderCIImage(
            from: pb, roi: roi,
            options: .init(applyPerspectiveCalibration: true,
                           applyDetectionQuad: true,    // ← key: masky jsou v post-quad space
                           maxOutputWidth: nil)
        ) else { return }
        guard let cg = SharedCIContext.shared.createCGImage(cropped, from: cropped.extent) else { return }
        previewImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private func imageDisplayRect(in size: CGSize) -> CGRect {
        guard let img = previewImage, img.size.width > 0, img.size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let imgAspect = img.size.width / img.size.height
        let geoAspect = size.width / max(size.height, 0.001)
        if imgAspect > geoAspect {
            let h = size.width / imgAspect
            let y = (size.height - h) / 2
            return CGRect(x: 0, y: y, width: size.width, height: h)
        } else {
            let w = size.height * imgAspect
            let x = (size.width - w) / 2
            return CGRect(x: x, y: 0, width: w, height: size.height)
        }
    }

    private func save() {
        state.setRoiExclusionMasks(name: cameraName, masks: masks)
        onClose()
    }
}
