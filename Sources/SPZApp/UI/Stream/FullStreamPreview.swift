import SwiftUI
import AppKit

/// FullStreamPreview + FullStreamPreviewVM — clean fullscreen video preview.
/// Extracted ze StreamView.swift jako součást big-refactor split (krok #10).

// MARK: - FullStreamPreview (clean fullscreen video)

@MainActor
final class FullStreamPreviewVM: ObservableObject {
    @Published var image: NSImage?
    @Published var aspect: CGFloat = 16.0 / 9.0
    var camera: CameraService?
    private var timer: Timer?
    /// Cap preview na ~960 px wide — full HD frame (1080×1920) má 8 MP,
    /// downscale na 0.5× snižuje pixel ops 4× při render. Pro preview je
    /// to vizuálně dostatečné, zoom na detail je řešen scaleEffect.
    private static let maxPreviewWidth: CGFloat = 960

    func start() {
        timer?.invalidate()
        // 10 Hz preview (place 20 Hz měl 4× větší CPU cost než RoiPreviewVM
        // protože pulluje FULL frame, ne malý ROI crop).
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        tick()
    }
    func stop() {
        timer?.invalidate(); timer = nil
        image = nil; camera = nil
    }
    deinit { timer?.invalidate() }

    func tick() {
        autoreleasepool {
            guard let pb = camera?.snapshotLatest() else { return }
            var ci = CIImage(cvPixelBuffer: pb)
            let w = ci.extent.width, h = ci.extent.height
            guard w > 0, h > 0 else { return }
            if h > 0 {
                let a = w / h
                if abs(a - aspect) > 0.001 { aspect = a }
            }
            // Downscale na ≤ maxPreviewWidth — sdílený CIContext renderuje
            // míň pixelů (~5× méně CPU pro 1920→900).
            if w > Self.maxPreviewWidth {
                let scale = Self.maxPreviewWidth / w
                ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
            let ext = ci.extent
            guard let cg = SharedCIContext.shared.createCGImage(
                ci, from: CGRect(x: 0, y: 0, width: ext.width, height: ext.height)
            ) else { return }
            image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
    }
}

/// Holé video over full window. Žádné ROI overlay, žádný LiveOverlay,
/// žádný RoiSelectorOverlay — pouze NSImage z 20 Hz timer pull, aspect-fit
/// dle aktuálního image rozměru + minimální controls (close, snap photo).
/// Schválně NEpoužívá CAMetalLayer / DisplayLayerHost — migrace mezi
/// SwiftUI re-mounty způsobovala stale layer s 0×0 bounds → black screen.
struct FullStreamPreview: View {
    @ObservedObject var camera: CameraService
    let cameraName: String
    let onClose: () -> Void
    @EnvironmentObject var state: AppState
    @StateObject private var vm = FullStreamPreviewVM()
    @State private var snapFlash: Bool = false
    @State private var snapToast: String? = nil
    @State private var zoomScale: CGFloat = 1.0
    @State private var dragOffset: CGSize = .zero
    @State private var dragBase: CGSize = .zero
    @State private var scrollMonitor: Any?
    /// Aktuální velikost view (z GeometryReader) — sdíleno do scroll monitor closure.
    @State private var viewSize: CGSize = .zero
    /// Aktuální pozice kurzoru v view-local coords (top-left origin) — pro
    /// zoom-to-cursor anchor math.
    @State private var cursorLocal: CGPoint = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                    .ignoresSafeArea()

                if let img = vm.image {
                    let fit = aspectFit(videoAspect: vm.aspect, container: geo.size)
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: fit.width, height: fit.height)
                        .scaleEffect(zoomScale, anchor: .center)
                        .offset(dragOffset)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { val in
                                    // Pan rychlost roste se zoomem (1× klidný, 8× rychlý).
                                    // Po 30% zpomalení od user — předtím při 8× moc rychlé.
                                    let mult = 0.35 + zoomScale * 0.42
                                    dragOffset = CGSize(
                                        width: dragBase.width + val.translation.width * mult,
                                        height: dragBase.height + val.translation.height * mult
                                    )
                                }
                                .onEnded { _ in dragBase = dragOffset }
                        )
                } else {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.large).tint(.white)
                        Text(camera.lastError ?? "Připojuji ke streamu…")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                    }
                }

                // Controls — close + snap photo, top-right.
                VStack {
                    HStack(spacing: 10) {
                        Spacer()
                        Button(action: snapPhoto) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.yellow)
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(Color.black.opacity(0.65))
                                    .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1)))
                        }
                        .buttonStyle(.plain)
                        .help("Vyfotit snímek a uložit do Manuálních průjezdů")

                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(Color.black.opacity(0.65))
                                    .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1)))
                        }
                        .buttonStyle(.plain)
                        .help("Zavřít fullscreen náhled")
                        .keyboardShortcut(.escape, modifiers: [])
                    }
                    .padding(14)
                    Spacer()
                }

                // Toast po vyfocení
                if let msg = snapToast {
                    VStack {
                        Spacer()
                        Text(LocalizedStringKey(msg))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.black)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Capsule().fill(Color.yellow))
                            .padding(.bottom, 60)
                    }
                    .allowsHitTesting(false)
                }

                if snapFlash {
                    Color.white.opacity(0.55).allowsHitTesting(false)
                }
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                if case .active(let p) = phase { cursorLocal = p }
            }
            .onAppear { viewSize = geo.size }
            .onChange(of: geo.size) { _, new in viewSize = new }
        }
        .onAppear {
            vm.camera = camera
            vm.start()
            // Local scroll wheel monitor — kolečko myši = zoom. FullPreview
            // overlay vyplňuje celé okno aplikace, takže každý scroll event
            // patří nám (žádný conflict s ostatními views).
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                // Trackpad/Magic Mouse mají hasPreciseScrollingDeltas=true a posílají
                // precizní pixel-level deltas (často velmi vysoké pod akcelerací).
                // Klasický wheel mouse má deltaY = ±1, ±2 per notch. Sjednoceno přes
                // exp() s malým koeficientem — pro malé dy téměř lineární, pro velké
                // dy roste pomalu (žádný instant-zoom-max).
                let dyRaw = event.hasPreciseScrollingDeltas
                    ? event.scrollingDeltaY * 0.4   // tlumení akcelerace trackpadu
                    : event.scrollingDeltaY * 3.0   // wheel notch jistě cítí
                guard dyRaw.isFinite else { return event }
                // Cap raw delta — extreme spurious events (driver glitches) by
                // jinak prohnaly zoom celým range v jediném ticku.
                let dy = max(-25.0, min(25.0, dyRaw))
                guard abs(dy) > 0.001 else { return event }
                let factor = exp(dy * 0.008)
                let prev = zoomScale
                let next = max(1.0, min(8.0, prev * factor))
                guard next != prev else { return nil }
                // Zoom-to-cursor: udrž image-pixel pod kurzorem na stejné view
                // pozici. dx/dy jsou cursor coords od view středu (anchor center
                // v scaleEffect). Vzorec O' = d * (1 - r) + O * r kde r = S2/S1.
                let r = next / prev
                let cx = cursorLocal.x - viewSize.width / 2
                let cy = cursorLocal.y - viewSize.height / 2
                dragOffset = CGSize(
                    width: cx * (1 - r) + dragOffset.width * r,
                    height: cy * (1 - r) + dragOffset.height * r
                )
                dragBase = dragOffset
                zoomScale = next
                if next == 1.0 {
                    dragOffset = .zero
                    dragBase = .zero
                }
                return nil  // consume — netoulat scroll dál (žádný background scroll vedlejší UI)
            }
        }
        .onDisappear {
            vm.stop()
            if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
        }
    }

    private func aspectFit(videoAspect aspect: CGFloat, container size: CGSize) -> CGSize {
        let availW = size.width, availH = size.height
        guard availW > 0, availH > 0, aspect > 0 else { return .zero }
        if availW / availH > aspect {
            return CGSize(width: availH * aspect, height: availH)
        }
        return CGSize(width: availW, height: availW / aspect)
    }

    private func snapPhoto() {
        guard let pb = camera.snapshotLatest() else {
            showToast("⚠️ Stream nemá frame")
            return
        }
        let ci = CIImage(cvPixelBuffer: pb)
        guard let cg = SharedCIContext.shared.createCGImage(ci, from: ci.extent) else {
            showToast("⚠️ Konverze selhala")
            return
        }
        let ns = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        if let url = Store.shared.persistManualPass(cameraName: cameraName, fullImage: ns) {
            withAnimation(.easeOut(duration: 0.1)) { snapFlash = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.easeIn(duration: 0.2)) { snapFlash = false }
            }
            showToast("✓ Uloženo: \(url.lastPathComponent)")
        } else {
            showToast("⚠️ Uložení selhalo")
        }
    }

    private func showToast(_ msg: String) {
        withAnimation(.easeOut(duration: 0.2)) { snapToast = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeIn(duration: 0.3)) { snapToast = nil }
        }
    }
}
