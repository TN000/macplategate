import SwiftUI
import AppKit

/// StreamStage — core video preview stage s ROI overlay + ovladače.
/// Extracted ze StreamView.swift jako součást big-refactor split (krok #10).

struct StreamStage: View {
    @ObservedObject var camera: CameraService
    @EnvironmentObject var state: AppState
    let cameraName: String
    @Binding var roiSelectMode: Bool
    @Binding var showKameraBypass: Bool
    @Binding var settingsOpen: Bool
    @Binding var fullPreviewCamera: String?

    /// Pan/zoom transformy aplikované na DisplayLayerHost ve fullPreview módu.
    @State private var zoomScale: CGFloat = 1.0
    @State private var zoomBase: CGFloat = 1.0          // committed scale mezi gesty
    @State private var dragOffset: CGSize = .zero
    @State private var dragBase: CGSize = .zero         // committed offset mezi gesty
    @State private var snapFlash: Bool = false          // bílý záblesk po vyfocení
    @State private var snapToast: String? = nil        // status text "Uloženo: …"

    private var isFullPreview: Bool { fullPreviewCamera == cameraName }

    /// Per-stage camera config (ne state.activeCamera — dual-pane UI).
    private var myCam: CameraConfig? {
        state.cameras.first(where: { $0.name == cameraName })
    }
    private var roiSet: Bool { myCam?.roi != nil }

    /// Rozhoduje jestli stage ukazuje celý stream nebo ROI-cropped+rotated view.
    /// Ve fullPreview vždy plný stream (uživatel vyžadoval "co největší okno
    /// náhledu na stream", ne ROI crop).
    private var showRoiCropped: Bool {
        !roiSelectMode && !showKameraBypass && !isFullPreview && roiSet
    }

    var body: some View {
        ZStack {
            if showRoiCropped, let roi = myCam?.roi {
                RoiCroppedStage(camera: camera, cameraName: cameraName, roi: roi, hideStatus: settingsOpen)
            } else {
                fullStreamStage()
                    .scaleEffect(isFullPreview ? zoomScale : 1.0, anchor: .center)
                    .offset(isFullPreview ? dragOffset : .zero)
                    .gesture(isFullPreview ? panZoomGesture : nil)
            }

            // Ovládací ikony bottom-right — gear pro settings, eye pro fullscreen toggle.
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Spacer()
                    iconButton(system: "camera.fill", tint: .yellow,
                               help: "Vyfotit celý frame streamu (uloží do Manuálních průjezdů)") {
                        captureManualPhoto()
                    }
                    iconButton(
                        system: "eye",
                        tint: .white,
                        help: "Otevřít fullscreen náhled (zoom + foto)"
                    ) {
                        fullPreviewCamera = cameraName
                    }
                    iconButton(
                        system: "gearshape.fill",
                        tint: settingsOpen ? .green : .white,
                        help: "Nastavení streamu"
                    ) { settingsOpen.toggle() }
                }
                .padding(10)
            }

            // Toast po vyfocení — 2.5s
            if let msg = snapToast {
                VStack {
                    Spacer()
                    Text(LocalizedStringKey(msg))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Color.yellow))
                        .padding(.bottom, 60)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                .allowsHitTesting(false)
            }

            // Bílý flash při fotografování — 150 ms.
            if snapFlash {
                Color.white.opacity(0.55).allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
    }

    /// Combined pinch-to-zoom + drag-to-pan gesture pro fullPreview mode.
    /// Limity: zoom [1.0, 6.0], pan v ±větší straně view.
    private var panZoomGesture: some Gesture {
        SimultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    let next = zoomBase * value
                    zoomScale = max(1.0, min(6.0, next))
                }
                .onEnded { _ in zoomBase = zoomScale },
            DragGesture()
                .onChanged { value in
                    dragOffset = CGSize(
                        width: dragBase.width + value.translation.width,
                        height: dragBase.height + value.translation.height
                    )
                }
                .onEnded { _ in dragBase = dragOffset }
        )
    }

    /// Vyfotí current frame z `camera.snapshotLatest()` (CVPixelBuffer) → CGImage
    /// → NSImage → `Store.persistManualPass`. Spustí 150ms bílý flash + 2.5s toast.
    private func captureManualPhoto() {
        guard let pb = camera.snapshotLatest() else {
            showSnapToast("Stream nemá dostupný frame")
            return
        }
        let ci = CIImage(cvPixelBuffer: pb)
        guard let cg = SharedCIContext.shared.createCGImage(ci, from: ci.extent) else {
            showSnapToast("Konverze frame selhala")
            return
        }
        let ns = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        let url = Store.shared.persistManualPass(cameraName: cameraName, fullImage: ns)
        if let url {
            withAnimation(.easeOut(duration: 0.1)) { snapFlash = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.easeIn(duration: 0.2)) { snapFlash = false }
            }
            showSnapToast("Uloženo: \(url.lastPathComponent)")
        } else {
            showSnapToast("Uložení selhalo")
        }
    }

    private func showSnapToast(_ msg: String) {
        withAnimation(.easeOut(duration: 0.2)) { snapToast = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeIn(duration: 0.3)) { snapToast = nil }
        }
    }

    /// Sdílený styl pro kulatou iconu v rohu streamu.
    private func iconButton(system: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(Color.black.opacity(0.55))
                        .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func fullStreamStage() -> some View {
        ZStack {
            ZStack {
                Color.black
                if roiSelectMode, let frozen = state.frozenFrameCGImages[cameraName] {
                    Image(decorative: frozen, scale: 1.0)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                } else if let metalLayer = camera.previewLayer {
                    DisplayLayerHost(layer: metalLayer)
                }
                if !camera.connected, state.frozenFrameCGImages[cameraName] == nil {
                    VStack(spacing: 8) {
                        ProgressView().scaleEffect(0.7)
                        Text(camera.lastError ?? "Připojuji ke streamu…")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            .aspectRatio(camera.videoSize.width > 0 ? camera.videoSize.width / camera.videoSize.height : 16.0/9.0,
                         contentMode: .fit)

            // Bbox live overlay (jen full stream, ne bypass — bypass je "clean" stream)
            if !showKameraBypass {
                GeometryReader { geo in
                    LiveOverlay(detections: state.liveDetectionsByCamera[cameraName] ?? [],
                                displaySize: geo.size)
                }
                .allowsHitTesting(false)
            }

            if roiSelectMode {
                GeometryReader { geo in
                    RoiSelectorOverlay(
                        cameraName: cameraName,
                        videoSize: camera.videoSize,
                        displaySize: geo.size,
                        onSelect: { rect in
                            state.setRoi(name: cameraName, roi: rect)
                            roiSelectMode = false
                            // Settings panel ZŮSTÁVÁ otevřený — přirozený next step
                            // workflow je vyrovnat rotaci nového výřezu. Uživatel
                            // ho zavře klikem na "Hotovo".
                        },
                        onCancel: {
                            roiSelectMode = false
                            // Cancel → zpátky do settings (odkud user vybírat šel).
                        }
                    )
                }
            }

            // ROI outline: ukazujeme v full-stream módu jen pokud je bypass ON (aby uživatel
            // viděl kde ROI sedí). V normálním full-stream módu (ROI není set) není co kreslit.
            if showKameraBypass, let roi = myCam?.roi {
                GeometryReader { geo in
                    RoiOutline(roi: roi.cgRect, rotationDeg: roi.rotationDeg,
                               videoSize: camera.videoSize, displaySize: geo.size)
                }
                .allowsHitTesting(false)
            }
        }
    }

    private func videoResString() -> String {
        let s = camera.videoSize
        if s.width > 0 { return "\(Int(s.width))×\(Int(s.height))" }
        return "—"
    }

    private func roiInfoText() -> String {
        if let r = myCam?.roi {
            return "ROI \(r.width)×\(r.height) @ \(r.x),\(r.y) · \(String(format: "%.1f°", r.rotationDeg))"
        }
        return "ROI: ne"
    }
}
