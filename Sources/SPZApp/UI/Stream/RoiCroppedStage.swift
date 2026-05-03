import SwiftUI
import AppKit

/// RoiCroppedStage + RoiPreviewVM — live ROI preview s cropped image + timer.
/// Extracted ze StreamView.swift jako součást big-refactor split (krok #10).

// MARK: - ROI cropped live stage

/// View-model držící timer + last image. MUSÍ být reference type, protože Timer
/// closure by jinak captured self (struct value) z jednoho renderu a update() by
/// používal STARÝ roi i po prop change — bug co způsoboval "slider pustím a obraz se
/// vrátí tam kde byl" a "preset nic neudělá".
@MainActor
final class RoiPreviewVM: ObservableObject {
    @Published var image: NSImage?
    var camera: CameraService?
    var roi: RoiBox?
    var applyPerspectiveCalibration: Bool = true
    var applyDetectionQuad: Bool = true
    /// Když nastaveno, místo `camera.snapshotLatest()` se používá tento
    /// statický buffer (uživatelův uložený screenshot scény s autem).
    var frozenFrame: CVPixelBuffer?
    private var timer: Timer?

    private static var ciContext: CIContext { SharedCIContext.shared }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        tick()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        // Explicitně uvolnit last NSImage — RoiCroppedStage.onDisappear volá stop();
        // bez nil sete NSImage viselo v @Published store dokud SwiftUI nerecykloval view.
        image = nil
        camera = nil
    }

    deinit {
        // Fallback cleanup (onDisappear už by měl stop() zavolat).
        timer?.invalidate()
    }

    func tick() {
        autoreleasepool {
            guard let roi else { return }
            let pb: CVPixelBuffer? = frozenFrame ?? camera?.snapshotLatest()
            guard let pb else { return }
            // Shared transform stack — musí sedět s PlateOCR.recognize().
            // Běžný ROI preview zapíná 8-DOF i detection crop; kalibrační
            // obrazovky si tyto vrstvy vypínají podle toho, kterou právě editují.
            guard let cropped = RoiTransformRenderer.renderCIImage(
                from: pb,
                roi: roi,
                options: .init(applyPerspectiveCalibration: applyPerspectiveCalibration,
                               applyDetectionQuad: applyDetectionQuad,
                               maxOutputWidth: 900)
            ) else { return }
            let ext = cropped.extent
            guard let cg = Self.ciContext.createCGImage(cropped, from: ext) else { return }
            image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
    }
}

/// Live view ROI cropu s rotací — pulls latest pixel buffer from camera at ~20 Hz,
/// crops + rotates per current roi, displays as Image. Identický pipeline jako
/// PlateOCR vidí → uživatel kouká na to co OCR dostává.
struct RoiCroppedStage: View {
    @ObservedObject var camera: CameraService
    @EnvironmentObject var state: AppState
    let cameraName: String
    let roi: RoiBox
    /// Při úpravě rotace (settings panel otevřen) chceme "clean" preview bez
    /// OCR chipu — uživatel se soustředí na vyrovnání obrazu.
    let hideStatus: Bool
    @StateObject private var vm = RoiPreviewVM()

    var body: some View {
        ZStack {
            Color.black
            if let img = vm.image {
                // Fit — zachová aspect ratio detection areas bez clippingu.
                // Pokud je aspect ≠ pane, vzniknou černé pruhy. User chce vidět
                // přesně tu oblast kterou vybral, bez umělého zoomu/oříznutí.
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView().scaleEffect(0.6)
            }
            // Overlay (bbox) jen když NENÍ otevřený settings panel. Per-camera
            // slot — každá pane zobrazuje ten svůj, nemíchají se.
            if !hideStatus {
                let myDets = state.liveDetectionsByCamera[cameraName] ?? []
                GeometryReader { geo in
                    RoiLiveOverlay(
                        detections: myDets,
                        roi: roi,
                        videoSize: camera.videoSize,
                        displaySize: geo.size
                    )
                }
                .allowsHitTesting(false)
                DetectionStatusOverlay(cameraName: cameraName)
            }
        }
        // Resize artefakty: banner NoPlateBanner má `.tracking(5.0)` + transition
        // animaci 0.25 s; při live resize okna se layout vlastní frame mění rychleji
        // než transition, takže fragmenty letters ("I", "M" z NEVIDÍM/ZACHYCENÍ)
        // krátce proluklý mimo pane a prosvěcovaly skrz detekční panel. Explicitní
        // clip zabraní leakingu obsahu overlay mimo stage.
        .clipped()
        .onAppear {
            vm.camera = camera
            vm.roi = roi
            vm.start()
        }
        .onDisappear { vm.stop() }
        .onChange(of: roi) { _, new in
            vm.roi = new
            vm.tick()
        }
    }
}
