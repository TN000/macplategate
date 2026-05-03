import SwiftUI
import AppKit

/// Sdílený zoom + pan stack pro sheety s manipulací nad ROI náhledem.
/// Aplikuj na drawing area přes `.zoomPan(controller)`. Modifier:
/// • scaleEffect + offset přes celý content (rendering-only — gestures
///   uvnitř child views vidí pre-transform coords, takže existující
///   handle-drag kód v sheetech zůstává funkční).
/// • DragGesture na container = pan (rychlost roste se scalem).
/// • MagnificationGesture = pinch zoom (trackpad).
/// • NSEvent local scroll-wheel monitor = zoom-to-cursor (kolečko myši).
/// • Filter scroll events podle aktuální plochy (`area.global`) — sheet
///   s vedlejším ScrollView (např. ExclusionMaskSheet seznam masek)
///   si zachová svůj scroll na vlastní ploše.
@MainActor
final class ZoomPanController: ObservableObject {
    @Published var scale: CGFloat = 1.0
    @Published var offset: CGSize = .zero

    /// Stable base mezi gesty (Magnification.onEnded, DragPan.onEnded).
    private var scaleBase: CGFloat = 1.0
    private var offsetBase: CGSize = .zero

    /// Frame plochy v .global SwiftUI coords (TL origin) — pro filtering
    /// scroll wheel events.
    var areaGlobalFrame: CGRect = .zero
    /// Cursor uvnitř plochy ve view-local coords (TL origin) — pro
    /// zoom-to-cursor anchor math.
    var cursorLocal: CGPoint = .zero
    /// Velikost plochy (pro center-anchor scaleEffect math).
    var viewSize: CGSize = .zero

    private var scrollMonitor: Any?

    func attach() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            // Filter — kurzor musí být nad drawing area, jinak nech event projít
            // jiným views (např. ScrollView seznamu masek vpravo v sheetu).
            guard let window = event.window,
                  let content = window.contentView else { return event }
            let blY = event.locationInWindow.y
            let tlY = content.bounds.height - blY
            let p = CGPoint(x: event.locationInWindow.x, y: tlY)
            guard self.areaGlobalFrame.contains(p) else { return event }

            // Sjednocení trackpad (precise) vs wheel notch — viz FullStreamPreview.
            let dyRaw = event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY * 0.4
                : event.scrollingDeltaY * 3.0
            guard dyRaw.isFinite else { return event }
            let dy = max(-25.0, min(25.0, dyRaw))
            guard abs(dy) > 0.001 else { return event }
            let factor = exp(dy * 0.008)
            let prev = self.scale
            let next = max(1.0, min(8.0, prev * factor))
            guard next != prev else { return nil }

            // Zoom-to-cursor: udrž pixel pod kurzorem na stejné view pozici.
            let r = next / prev
            let cx = self.cursorLocal.x - self.viewSize.width / 2
            let cy = self.cursorLocal.y - self.viewSize.height / 2
            self.offset = CGSize(
                width: cx * (1 - r) + self.offset.width * r,
                height: cy * (1 - r) + self.offset.height * r
            )
            self.offsetBase = self.offset
            self.scale = next
            self.scaleBase = next
            if next == 1.0 {
                self.offset = .zero
                self.offsetBase = .zero
            }
            return nil
        }
    }

    func detach() {
        if let m = scrollMonitor {
            NSEvent.removeMonitor(m)
            scrollMonitor = nil
        }
    }

    /// Safety net: pokud `onDisappear` view modifier neprobehnul (např. sheet
    /// dismissed via crash / forced cleanup), deinit explicitly zruší monitor.
    /// `NSEvent.removeMonitor` je safe i mimo main thread.
    deinit {
        if let m = scrollMonitor {
            NSEvent.removeMonitor(m)
        }
    }

    func reset() {
        scale = 1.0
        scaleBase = 1.0
        offset = .zero
        offsetBase = .zero
    }

    fileprivate func applyMagnification(_ value: CGFloat) {
        let next = max(1.0, min(8.0, scaleBase * value))
        scale = next
    }

    fileprivate func endMagnification() {
        scaleBase = scale
        if scale == 1.0 {
            offset = .zero
            offsetBase = .zero
        }
    }

    fileprivate func applyPan(_ translation: CGSize) {
        let mult = 0.35 + scale * 0.42
        offset = CGSize(
            width: offsetBase.width + translation.width * mult,
            height: offsetBase.height + translation.height * mult
        )
    }

    fileprivate func endPan() {
        offsetBase = offset
    }
}

extension View {
    /// Aplikuj zoom + pan stack na drawing area. Aktivuj `.onAppear`
    /// `controller.attach()` a `.onDisappear` `controller.detach()` se
    /// dějí automaticky.
    /// • `dragPan = true` (default) — DragGesture na container = pan.
    ///   Vhodné když uvnitř obsahu nejsou drag gestures jiné.
    /// • `dragPan = false` — pan jen Shift+drag (pomocí simultaneousGesture
    ///   s NSEvent modifier check). Použij když uvnitř ZStacku už drag
    ///   slouží něčemu jinému (kreslení masek, atd.).
    func zoomPan(_ ctrl: ZoomPanController, dragPan: Bool = true) -> some View {
        modifier(ZoomPanViewModifier(controller: ctrl, dragPan: dragPan))
    }
}

private struct ZoomPanViewModifier: ViewModifier {
    @ObservedObject var controller: ZoomPanController
    let dragPan: Bool
    /// **Shift state captured při drag startu**, držený po celou dobu
    /// drag-u. Bez tohoto by user mohl Shift přidržet, začít pan, pustit
    /// Shift mid-drag → onChanged by stop reagovat, onEnded by neukončil
    /// pan correctly → tracker offsetBase by se neaktualizoval = pan stav
    /// se příště "skoči" k chybnému startu. NSEvent.modifierFlags je global
    /// volatile, číst ho jen jednou (drag start) zajistí konzistenci.
    @State private var dragShiftActive: Bool = false

    func body(content: Content) -> some View {
        let base = content
            .scaleEffect(controller.scale, anchor: .center)
            .offset(controller.offset)
        return Group {
            if dragPan {
                base.gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { val in controller.applyPan(val.translation) }
                        .onEnded { _ in controller.endPan() }
                )
            } else {
                // Shift+drag = pan; bez modifieru se drag pošle child gestům
                // (kreslení masky atd.). Shift se loaduje při start a držený.
                base.simultaneousGesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { val in
                            if val.translation == .zero {
                                // First onChanged tick — capture Shift state.
                                dragShiftActive = NSEvent.modifierFlags.contains(.shift)
                            }
                            if dragShiftActive {
                                controller.applyPan(val.translation)
                            }
                        }
                        .onEnded { _ in
                            if dragShiftActive {
                                controller.endPan()
                            }
                            dragShiftActive = false
                        }
                )
            }
        }
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { v in controller.applyMagnification(v) }
                .onEnded { _ in controller.endMagnification() }
        )
        .onContinuousHover(coordinateSpace: .local) { phase in
            if case .active(let p) = phase { controller.cursorLocal = p }
        }
        .background(
            GeometryReader { inner in
                Color.clear
                    .onAppear {
                        controller.areaGlobalFrame = inner.frame(in: .global)
                        controller.viewSize = inner.size
                    }
                    .onChange(of: inner.frame(in: .global)) { _, new in
                        controller.areaGlobalFrame = new
                    }
                    .onChange(of: inner.size) { _, new in
                        controller.viewSize = new
                    }
            }
        )
        .onAppear { controller.attach() }
        .onDisappear { controller.detach() }
    }
}
