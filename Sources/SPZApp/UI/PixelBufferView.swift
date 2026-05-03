import SwiftUI
import AppKit
import QuartzCore

/// NSView který hostí CAMetalLayer z `MetalPreviewRenderer`.
/// CameraService.previewRenderer má `metalLayer: CAMetalLayer` a VT decoder thread
/// renderuje frames přímo na něj přes `CIContext.startTask(toRender:to:)` —
/// žádný SwiftUI re-render storm, žádné CMSampleBuffer intermediate alokace
/// per frame.
final class HostingDisplayNSView: NSView {
    private(set) var currentLayer: CAMetalLayer

    init(metalLayer: CAMetalLayer) {
        self.currentLayer = metalLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        // Detach z předchozího hostujícího NSView (může se stát při SwiftUI
        // re-mountu mezi mody — stejný CAMetalLayer migruje mezi parenty).
        metalLayer.removeFromSuperlayer()
        layer?.addSublayer(metalLayer)
    }
    required init?(coder: NSCoder) { return nil }

    /// Swap na jiný CAMetalLayer (camera switch).
    func swapLayer(to newLayer: CAMetalLayer) {
        currentLayer.removeFromSuperlayer()
        currentLayer = newLayer
        newLayer.frame = bounds
        layer?.addSublayer(newLayer)
    }

    override func layout() {
        super.layout()
        currentLayer.frame = bounds
    }
}

struct DisplayLayerHost: NSViewRepresentable {
    let layer: CAMetalLayer
    func makeNSView(context: Context) -> HostingDisplayNSView {
        HostingDisplayNSView(metalLayer: layer)
    }
    /// Swap aktivního sublayer když se layer identity změní (switch mezi kamerami).
    func updateNSView(_ nsView: HostingDisplayNSView, context: Context) {
        if nsView.currentLayer !== layer {
            nsView.swapLayer(to: layer)
        }
    }
}
