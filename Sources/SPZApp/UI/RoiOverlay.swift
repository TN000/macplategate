import SwiftUI
import AppKit

// MARK: - Live detection overlay (bbox + label)

struct LiveOverlay: View {
    let detections: [LiveDetection]
    let displaySize: CGSize

    var body: some View {
        // 20 Hz extrapolace — 2× nad Vision rate (10 Hz), plynule posouvá bbox mezi
        // ticky (velocity × Δt od posledního Vision update). Pause když žádné detekce.
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: detections.isEmpty)) { timeline in
        Canvas { ctx, size in
            for d in detections {
                guard d.sourceWidth > 0, d.sourceHeight > 0 else { continue }
                // Extrapolace: posuň bbox o velocity × Δt od Vision-commit timestampu.
                // Clamp na 250 ms aby stale detection (Vision off) nezaletěla mimo obraz.
                let dt = min(0.25, timeline.date.timeIntervalSince(d.ts))
                let offsetX = d.velocity.dx * dt
                let offsetY = d.velocity.dy * dt
                let extrapolated = d.bbox.offsetBy(dx: offsetX, dy: offsetY)
                let mapped = mapToDisplay(extrapolated, srcSize: CGSize(width: d.sourceWidth, height: d.sourceHeight), displaySize: size)
                let path = Path(roundedRect: mapped, cornerRadius: 3)
                ctx.stroke(path, with: .color(.green.opacity(0.92)), lineWidth: 2.5)
                if !d.plate.isEmpty {
                    let label = d.plate
                    let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
                    let labelWidth = label.measuredWidth(font: font) + 14
                    let labelHeight: CGFloat = 20
                    let labelRect = CGRect(x: mapped.minX,
                                           y: max(0, mapped.minY - labelHeight - 2),
                                           width: labelWidth, height: labelHeight)
                    ctx.fill(Path(roundedRect: labelRect, cornerRadius: 4),
                             with: .color(Color(red: 252/255, green: 211/255, blue: 77/255)))
                    let attr = AttributedString(label, attributes: AttributeContainer([
                        .font: font,
                        .foregroundColor: NSColor(red: 69/255, green: 26/255, blue: 3/255, alpha: 1),
                    ]))
                    ctx.draw(Text(attr), in: labelRect.insetBy(dx: 7, dy: 3))
                }
            }
        }
        }
    }
}

// MARK: - ROI live detection overlay (transforms source bbox → rotated crop → display)

/// Realtime bbox + text label pro každou aktuální detekci, zobrazené nad rotated crop view.
///
/// Používáme `d.workBox` — ten je už v rotated-crop pixel space a je **axis-aligned s
/// horizontálním textem** který Vision viděl. Stačí ho aspect-fit scalem mapovat na
/// display. Dřívější varianta brala source-frame axis-aligned `d.bbox` a dopočítávala
/// rotaci, což vyrábělo rotovaný obdélník přes horizontální text v rotated cropu.
struct RoiLiveOverlay: View {
    let detections: [LiveDetection]
    let roi: RoiBox
    let videoSize: CGSize
    let displaySize: CGSize

    var body: some View {
        // 20 Hz update plynule extrapoluje mezi Vision ticky (10 Hz) s 2× oversample.
        // Pokud detections prázdné, Canvas nedělá nic (body only tick bez redraw content).
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: detections.isEmpty)) { timeline in
        Canvas { ctx, size in
            guard videoSize.width > 0, videoSize.height > 0 else { return }
            guard roi.width > 0, roi.height > 0 else { return }

            for d in detections {
                guard d.workSize.width > 0, d.workSize.height > 0 else { continue }
                // Aspect-fit workSize → display size. MUSÍ sedět s tím, co dělá
                // RoiPreviewVM (resp. RoiCroppedStage) při zobrazení rotated cropu.
                let srcAspect = d.workSize.width / d.workSize.height
                let dispAspect = size.width / size.height
                var dispW: CGFloat, dispH: CGFloat, padX: CGFloat = 0, padY: CGFloat = 0
                if srcAspect > dispAspect {
                    dispW = size.width; dispH = size.width / srcAspect; padY = (size.height - dispH) / 2
                } else {
                    dispH = size.height; dispW = size.height * srcAspect; padX = (size.width - dispW) / 2
                }
                let scale = dispW / d.workSize.width
                // Velocity-extrapolate workBox position.
                let dt = min(0.25, timeline.date.timeIntervalSince(d.ts))
                let ox = d.workVelocity.dx * dt
                let oy = d.workVelocity.dy * dt
                let rect = CGRect(
                    x: padX + (d.workBox.minX + ox) * scale,
                    y: padY + (d.workBox.minY + oy) * scale,
                    width: d.workBox.width * scale,
                    height: d.workBox.height * scale
                )
                let path = Path(roundedRect: rect, cornerRadius: 3)
                ctx.stroke(path, with: .color(.green.opacity(0.92)), lineWidth: 3)

                // Text label nad bbox-em
                if !d.plate.isEmpty {
                    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
                    let labelWidth = d.plate.measuredWidth(font: font) + 16
                    let labelHeight: CGFloat = 22
                    let labelRect = CGRect(x: rect.minX,
                                           y: max(0, rect.minY - labelHeight - 2),
                                           width: labelWidth, height: labelHeight)
                    ctx.fill(Path(roundedRect: labelRect, cornerRadius: 5),
                             with: .color(Color(red: 252/255, green: 211/255, blue: 77/255)))
                    let attr = AttributedString(d.plate, attributes: AttributeContainer([
                        .font: font,
                        .foregroundColor: NSColor(red: 69/255, green: 26/255, blue: 3/255, alpha: 1),
                    ]))
                    ctx.draw(Text(attr), in: labelRect.insetBy(dx: 8, dy: 3))
                }
            }
        }
        }
    }
}

// MARK: - Always-visible ROI outline (with rotation)

struct RoiOutline: View {
    let roi: CGRect
    let rotationDeg: Double
    let videoSize: CGSize
    let displaySize: CGSize

    var body: some View {
        Canvas { ctx, size in
            guard videoSize.width > 0, videoSize.height > 0 else { return }
            let mapped = mapToDisplay(roi, srcSize: videoSize, displaySize: size)
            let theta = CGFloat(rotationDeg) * .pi / 180
            // 4 rohy ROI v display-space, rotované kolem středu mapped rectu
            let cx = mapped.midX, cy = mapped.midY
            let hw = mapped.width / 2, hh = mapped.height / 2
            let local: [CGPoint] = [
                CGPoint(x: -hw, y: -hh), CGPoint(x: hw, y: -hh),
                CGPoint(x: hw, y: hh), CGPoint(x: -hw, y: hh),
            ]
            let cs = cos(theta), sn = sin(theta)
            let corners = local.map { p in
                CGPoint(x: cx + cs * p.x - sn * p.y, y: cy + sn * p.x + cs * p.y)
            }
            var path = Path()
            path.move(to: corners[0])
            for c in corners.dropFirst() { path.addLine(to: c) }
            path.closeSubpath()
            ctx.stroke(path, with: .color(Color(red: 96/255, green: 165/255, blue: 250/255).opacity(0.85)),
                       style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            // Corner brackets — reflect rotation
            let m: CGFloat = 12
            for i in 0..<4 {
                let prev = corners[(i + 3) % 4]
                let curr = corners[i]
                let next = corners[(i + 1) % 4]
                let vPrev = direction(from: curr, to: prev, length: m)
                let vNext = direction(from: curr, to: next, length: m)
                var b = Path()
                b.move(to: CGPoint(x: curr.x + vPrev.x, y: curr.y + vPrev.y))
                b.addLine(to: curr)
                b.addLine(to: CGPoint(x: curr.x + vNext.x, y: curr.y + vNext.y))
                ctx.stroke(b, with: .color(.blue.opacity(0.95)), lineWidth: 3)
            }
            // Up-arrow ve středu pro indikaci "kam Vision uvidí nahoru" (0° = nahoru)
            let up = CGPoint(x: -sn, y: -cs)  // rotated up vector (screen y+ = dolů)
            let arm: CGFloat = min(hw, hh) * 0.35
            var arrow = Path()
            arrow.move(to: CGPoint(x: cx, y: cy))
            arrow.addLine(to: CGPoint(x: cx + up.x * arm, y: cy + up.y * arm))
            ctx.stroke(arrow, with: .color(.green.opacity(0.9)), lineWidth: 2.5)
        }
    }

    private func direction(from a: CGPoint, to b: CGPoint, length: CGFloat) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = sqrt(dx * dx + dy * dy)
        guard len > 0.001 else { return .zero }
        return CGPoint(x: dx / len * length, y: dy / len * length)
    }
}

// MARK: - ROI selector overlay (cursor-follow ghost rectangle)

struct RoiSelectorOverlay: View {
    let cameraName: String
    let videoSize: CGSize
    let displaySize: CGSize
    let onSelect: (CGRect) -> Void
    let onCancel: () -> Void

    @State private var dragStart: CGPoint? = nil
    @State private var dragCurrent: CGPoint? = nil
    @State private var hoverPoint: CGPoint? = nil
    private let minSizePx: CGFloat = 80  // minimum sensible ROI (source pixels)

    var body: some View {
        ZStack {
            // Transparent gesture catcher — žádný opaque scrim, video zůstává viditelné.
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 3, coordinateSpace: .local)
                        .onChanged { val in
                            if dragStart == nil {
                                dragStart = clampToVideo(val.startLocation)
                            }
                            dragCurrent = clampToVideo(val.location)
                        }
                        .onEnded { _ in
                            commitDragSelection()
                        }
                )

            // "Donut" dim — outside ROI rect je 50% black, inside ROI je čistý video frame.
            // Live overlay (LiveOverlay) zůstává nad tím, takže detekce jsou viditelné.
            if let geom = computeGeom() {
                let selectionRect = currentSelectionRect()
                Canvas { ctx, size in
                    // Letterbox — dim mimo video plochu (jen tenké pruhy nahoře/dole nebo po stranách)
                    let videoArea = CGRect(x: geom.padX, y: geom.padY, width: geom.dispW, height: geom.dispH)
                    var letterboxDim = Path(CGRect(origin: .zero, size: size))
                    letterboxDim.addRect(videoArea)
                    ctx.fill(letterboxDim, with: .color(.black.opacity(0.7)), style: FillStyle(eoFill: true))

                    // Pokud uživatel táhne — donut: dim mimo ROI v rámci video plochy
                    if let rect = selectionRect {
                        var outsideRoi = Path(videoArea)
                        outsideRoi.addRect(rect)
                        ctx.fill(outsideRoi, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))

                        // Sharp green border + corner brackets
                        ctx.stroke(Path(rect), with: .color(.green), lineWidth: 3)
                        drawCornerMarkers(ctx: ctx, rect: rect)
                    } else if let hp = hoverPoint, videoArea.contains(hp) {
                        // Crosshair guide když user hover ale ještě netáhne
                        var cross = Path()
                        let arm: CGFloat = 16
                        cross.move(to: CGPoint(x: hp.x - arm, y: hp.y)); cross.addLine(to: CGPoint(x: hp.x + arm, y: hp.y))
                        cross.move(to: CGPoint(x: hp.x, y: hp.y - arm)); cross.addLine(to: CGPoint(x: hp.x, y: hp.y + arm))
                        ctx.stroke(cross, with: .color(.green.opacity(0.6)), lineWidth: 1.5)
                    }
                }
                .allowsHitTesting(false)
            }

            // Top hint banner odstraněn — instrukce nyní žije v headerRow pane
            // (nepřekrývá obraz během výběru). Drag size info už zobrazuje
            // samotný zelený obdélník.
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button(action: onCancel) {
                        HStack(spacing: 6) {
                            Image(systemName: "xmark")
                            Text("Zrušit (Esc)")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Color.white.opacity(0.15)))
                        .overlay(Capsule().stroke(Color.white.opacity(0.3), lineWidth: 1))
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
            }
        }
        .onContinuousHover { phase in
            if case .active(let pt) = phase { hoverPoint = pt } else { hoverPoint = nil }
        }
        .background(KeyEventCapture(onEsc: onCancel))
    }

    private func currentSelectionRect() -> CGRect? {
        guard let s = dragStart, let c = dragCurrent else { return nil }
        let x = min(s.x, c.x), y = min(s.y, c.y)
        let w = abs(c.x - s.x), h = abs(c.y - s.y)
        guard w >= 4 && h >= 4 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func clampToVideo(_ p: CGPoint) -> CGPoint {
        guard let geom = computeGeom() else { return p }
        return CGPoint(
            x: min(max(geom.padX, p.x), geom.padX + geom.dispW),
            y: min(max(geom.padY, p.y), geom.padY + geom.dispH)
        )
    }

    private func drawCornerMarkers(ctx: GraphicsContext, rect: CGRect) {
        let m: CGFloat = 14
        let corners: [(CGPoint, CGPoint, CGPoint)] = [
            (CGPoint(x: rect.minX, y: rect.minY + m), CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX + m, y: rect.minY)),
            (CGPoint(x: rect.maxX - m, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY + m)),
            (CGPoint(x: rect.minX, y: rect.maxY - m), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX + m, y: rect.maxY)),
            (CGPoint(x: rect.maxX - m, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY - m)),
        ]
        for (a, b, c) in corners {
            var p = Path()
            p.move(to: a); p.addLine(to: b); p.addLine(to: c)
            ctx.stroke(p, with: .color(.green), lineWidth: 4)
        }
    }

    private func commitDragSelection() {
        defer { dragStart = nil; dragCurrent = nil }
        guard let geom = computeGeom(), let rect = currentSelectionRect() else { return }
        let src = displayToSource(rect, geom: geom)
        // Reject too small ROIs — minimum 80×80 source pixels
        guard src.width >= minSizePx && src.height >= minSizePx else { return }
        // Clamp do video bounds
        let clamped = src.intersection(CGRect(x: 0, y: 0, width: videoSize.width, height: videoSize.height))
        guard !clamped.isNull, clamped.width >= minSizePx && clamped.height >= minSizePx else { return }
        onSelect(clamped)
    }

    private func displayToSource(_ rect: CGRect, geom: Geom) -> CGRect {
        let scaleX = videoSize.width / geom.dispW
        let scaleY = videoSize.height / geom.dispH
        return CGRect(
            x: (rect.minX - geom.padX) * scaleX,
            y: (rect.minY - geom.padY) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )
    }

    // MARK: - Geometry

    private struct Geom {
        let padX: CGFloat, padY: CGFloat   // letterbox padding (display pixels)
        let dispW: CGFloat, dispH: CGFloat // active video area size in display
        let scale: CGFloat                  // display pixels per source pixel
    }

    private func computeGeom() -> Geom? {
        guard videoSize.width > 0, videoSize.height > 0 else { return nil }
        let srcAspect = videoSize.width / videoSize.height
        let dispAspect = displaySize.width / displaySize.height
        var w: CGFloat, h: CGFloat, padX: CGFloat = 0, padY: CGFloat = 0
        if srcAspect > dispAspect {
            w = displaySize.width
            h = displaySize.width / srcAspect
            padY = (displaySize.height - h) / 2
        } else {
            h = displaySize.height
            w = displaySize.height * srcAspect
            padX = (displaySize.width - w) / 2
        }
        let scale = w / videoSize.width
        return Geom(padX: padX, padY: padY, dispW: w, dispH: h, scale: scale)
    }

}

// MARK: - Helpers

func mapToDisplay(_ src: CGRect, srcSize: CGSize, displaySize: CGSize) -> CGRect {
    guard srcSize.width > 0, srcSize.height > 0 else { return .zero }
    let srcAspect = srcSize.width / srcSize.height
    let dispAspect = displaySize.width / displaySize.height
    var w: CGFloat, h: CGFloat, padX: CGFloat = 0, padY: CGFloat = 0
    if srcAspect > dispAspect {
        w = displaySize.width; h = displaySize.width / srcAspect; padY = (displaySize.height - h) / 2
    } else {
        h = displaySize.height; w = displaySize.height * srcAspect; padX = (displaySize.width - w) / 2
    }
    let sx = w / srcSize.width
    let sy = h / srcSize.height
    return CGRect(x: padX + src.origin.x * sx,
                  y: padY + src.origin.y * sy,
                  width: src.width * sx,
                  height: src.height * sy)
}

extension String {
    func measuredWidth(font: NSFont) -> CGFloat {
        (self as NSString).size(withAttributes: [.font: font]).width
    }
}

/// Captures Esc key for cancel.
private struct KeyEventCapture: NSViewRepresentable {
    let onEsc: () -> Void
    func makeNSView(context: Context) -> NSView {
        let v = KeyView(); v.onEsc = onEsc; return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        if let k = nsView as? KeyView { k.onEsc = onEsc }
    }

    private final class KeyView: NSView {
        var onEsc: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { onEsc?() }  // Esc
            else { super.keyDown(with: event) }
        }
    }
}
