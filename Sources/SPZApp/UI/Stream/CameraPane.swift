import SwiftUI
import AppKit

/// CameraPane — single-camera column layout (drží StreamStage + status overlays).
/// Extracted ze StreamView.swift jako součást big-refactor split (krok #10).

struct CameraPane: View {
    let cameraName: String
    /// Šířka pane přesně z StreamTabView — používá se pro deterministický
    /// výpočet výšky cameraCard (jinak aspectRatio(.fit) ve VStacku s druhou
    /// kartou kolaboval stream do thumbnailu).
    let paneWidth: CGFloat
    /// Binding na fullPreview state v StreamTabView — eye click v této pane
    /// nastaví na svoje cameraName, druhý click vrátí na nil.
    @Binding var fullPreviewCamera: String?
    @EnvironmentObject var state: AppState
    @EnvironmentObject var cameras: CameraManager
    @State private var roiSelectMode: Bool = false
    @State private var showKameraBypass: Bool = false
    @State private var settingsOpen: Bool = false

    private var isFullPreview: Bool { fullPreviewCamera == cameraName }

    private var camera: CameraService? { cameras.service(for: cameraName) }
    /// Výška karty kamery = stream (16:9) + header (~56 pt). Hlavní UI zůstává
    /// hardcoded 16:9 — full-stream aspect se uplatňuje jen v fullPreview, kde
    /// vrátíme nil → karta vezme plnou rodičovskou výšku (geo.size.height).
    private var cameraCardHeight: CGFloat? {
        isFullPreview ? nil : paneWidth * 9.0/16.0 + 56
    }

    private var myCam: CameraConfig? { state.cameras.first(where: { $0.name == cameraName }) }

    var body: some View {
        if isFullPreview, let cam = camera {
            // Čistý fullscreen video preview — žádné ROI / overlay / aspect-fit
            // konstrukty. User chce holé video, nic jiného.
            FullStreamPreview(
                camera: cam,
                cameraName: cameraName,
                onClose: { fullPreviewCamera = nil }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environmentObject(state)
        } else {
            VStack(spacing: 10) {
                cameraCard()
                    .frame(maxWidth: .infinity)
                    .frame(height: cameraCardHeight)
                    .overlay(alignment: .top) { gateOpenBanner }

                if settingsOpen && !roiSelectMode, let cam = camera {
                    SettingsPanel(
                        cameraName: cameraName,
                        roiSelectMode: $roiSelectMode,
                        settingsOpen: $settingsOpen,
                        showKameraBypass: $showKameraBypass,
                        camera: cam
                    )
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: settingsOpen)
            .animation(.easeInOut(duration: 0.2), value: roiSelectMode)
        }
    }

    /// Zelený banner „ZÁVORA OTEVŘENA" — per-camera, synchronizovaný s actual
    /// gate-open timerem dané kamery (`gateOpenDurationSec` / `…Vyjezd`).
    /// Show jen pokud daný Shelly device je usable nebo gate event proběhl.
    @ViewBuilder
    private var gateOpenBanner: some View {
        let isVyjezd = cameraName == "vyjezd" || cameraName == "výjezd"
        if isVyjezd ? state.shellyVyjezdEnabled : true {
            TimelineView(.periodic(from: Date(), by: 0.5)) { context in
                let openAt = isVyjezd ? state.gateOpenEventAtVyjezd : state.gateOpenEventAt
                let durSec = isVyjezd ? state.gateOpenDurationSecVyjezd : state.gateOpenDurationSec
                let visible: Bool = {
                    guard let at = openAt else { return false }
                    return context.date.timeIntervalSince(at) < durSec
                }()
                if visible {
                    HStack(spacing: 10) {
                        Image(systemName: "lock.open.fill")
                            .font(.system(size: 13, weight: .bold))
                        Text("Závora otevřena")
                            .font(.system(size: 13, weight: .semibold))
                            .tracking(0.4)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(
                        LinearGradient(colors: [Color.green, Color(red: 0.2, green: 0.80, blue: 0.35)],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
                    .shadow(color: Color.green.opacity(0.3), radius: 8, y: 2)
                    .padding(.horizontal, 2)
                    .padding(.top, 2)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// Hlavní karta — header (label + info cells/ROI hint) + stream/ROI stage.
    /// Má vlastní background, nezávislý na settings kartě.
    @ViewBuilder
    private func cameraCard() -> some View {
        VStack(spacing: 0) {
            headerRow()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)

            if let cam = camera {
                StreamStage(
                    camera: cam,
                    cameraName: cameraName,
                    roiSelectMode: $roiSelectMode,
                    showKameraBypass: $showKameraBypass,
                    settingsOpen: $settingsOpen,
                    fullPreviewCamera: $fullPreviewCamera
                )
                .aspectRatio(16.0/9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .onChange(of: cam.streamNominalFps) { _, _ in
                    cameras.onStreamNominalFpsChanged(for: cameraName)
                    if state.captureRateAuto { cameras.applyCaptureRateAll() }
                }
            } else {
                Color.black
                    .aspectRatio(16.0/9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay(
                        VStack(spacing: 8) {
                            ProgressView().scaleEffect(0.7)
                            Text("Inicializuji…")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [Color(white: 0.08), Color(white: 0.055)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
    }

    /// Hlavička pane — label kamery + buď info cells (RES/ROI/ROT/MODE) nebo,
    /// během ROI select módu, zelená instrukce „Tažením myší vyber oblast".
    /// Cells a hint se cross-faduje přes `.transition(.opacity.combined(with: .scale))`.
    @ViewBuilder
    private func headerRow() -> some View {
        ViewThatFits(in: .horizontal) {
            headerContent(compact: false)
            headerContent(compact: true)
        }
    }

    private func headerContent(compact: Bool) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(camera?.connected == true ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(LocalizedStringKey((myCam?.label ?? cameraName).uppercased()))
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .layoutPriority(1)
            Spacer(minLength: 10)

            if roiSelectMode {
                RoiSelectHint()
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .trailing)),
                        removal: .opacity.combined(with: .scale(scale: 0.95))
                    ))
            } else {
                HStack(spacing: compact ? 10 : 14) {
                    if !compact {
                        cell("ROZLIŠENÍ", videoResString(), width: 96)
                        divider
                    }
                    cell("VÝŘEZ", roiText(), width: 76)
                    divider
                    if !compact {
                        HStack(spacing: 6) {
                            cell("ROTACE", rotationText(), width: 56)
                            if roiSet {
                                VStack(spacing: 2) {
                                    rotStepButton(systemName: "plus", delta: 1)
                                    rotStepButton(systemName: "minus", delta: -1)
                                }
                            }
                        }
                        divider
                    }
                    cell("MÓD", modeText(), width: 58)
                }
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.95)),
                    removal: .opacity.combined(with: .move(edge: .trailing))
                ))
            }
        }
    }

    /// Mini stepper button — posune rotaci ROI o ±1°. Umístěno vpravo od ROT cell
    /// v headerRow. Enabled jen když je ROI nastaveno (bez ROI rotace nic neznamená).
    private func rotStepButton(systemName: String, delta: Double) -> some View {
        Button(action: {
            let current = myCam?.roi?.rotationDeg ?? 0
            state.setRoiRotation(name: cameraName, degrees: current + delta)
        }) {
            Image(systemName: systemName)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.75))
                .frame(width: 16, height: 12)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.12), lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
        .help(delta > 0 ? "Otočit +1°" : "Otočit −1°")
    }

    /// Vertical divider — stejná logika jako v CompactStatsBar.
    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1, height: 26)
    }

    /// Cell identicky stylizovaná s `CompactStatsBar.stat()` — 8pt bold tracking
    /// label nad 13pt semibold monospaced hodnotou, fixed column width, vše bílé.
    private func cell(_ k: String, _ v: String, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(k))
                .font(.system(size: 8, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(Color.white.opacity(0.45))
            Text(LocalizedStringKey(v))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(width: width, alignment: .leading)
    }

    // MARK: - Cell values

    private var roiSet: Bool { myCam?.roi != nil }

    private func videoResString() -> String {
        guard let cam = camera, cam.videoSize.width > 0 else { return "—" }
        return "\(Int(cam.videoSize.width))×\(Int(cam.videoSize.height))"
    }

    private func roiText() -> String {
        guard let r = myCam?.roi else { return "—" }
        // Pokud je nastaven detection quad, ukazujeme rozměry oblasti detekce
        // (axis-aligned bbox 4 bodů × ROI rozměry) — to co skutečně jde do OCR.
        if let dq = r.detectionQuad, dq.count == 4 {
            let xs = dq.map { $0.x }, ys = dq.map { $0.y }
            let minX = xs.min() ?? 0, maxX = xs.max() ?? 1
            let minY = ys.min() ?? 0, maxY = ys.max() ?? 1
            let w = Int(CGFloat(r.width) * (maxX - minX))
            let h = Int(CGFloat(r.height) * (maxY - minY))
            return "\(w)×\(h)"
        }
        return "\(r.width)×\(r.height)"
    }

    private func rotationText() -> String {
        guard let r = myCam?.roi else { return "—" }
        return String(format: "%+.0f°", r.rotationDeg)
    }

    private func modeText() -> String {
        if showKameraBypass { return "BYPASS" }
        if roiSet && !roiSelectMode { return "VÝŘEZ" }
        if roiSelectMode { return "VÝBĚR" }
        return "CELÝ"
    }
}
