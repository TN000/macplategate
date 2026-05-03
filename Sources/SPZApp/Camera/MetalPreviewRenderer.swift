import AppKit
import Metal
import QuartzCore
import CoreImage
import CoreVideo
import CoreMedia

/// CAMetalLayer-based preview renderer.
///
/// CVPixelBuffer (IOSurface NV12) → CIImage(cvPixelBuffer:) zero-copy →
/// CIContext.startTask(toRender:to:) renderuje přímo na `CAMetalLayer.nextDrawable()`
/// texture. Žádný `CMSampleBuffer` intermediate alloc per frame jak by vyžadoval
/// `AVSampleBufferDisplayLayer.enqueue()`.
///
/// **Aspect fit + letterbox:** CIImage.transformed() s min(sx, sy) scale + black
/// background composite. Stejný vizuál jako `videoGravity = .resizeAspect`.
///
/// **Color management:** BT.709 YCbCr → sRGB přes CIContext working color space.
/// CoreImage fuses to jeden Metal shader pass (ne 2 samples + 2 shader invocations
/// jak by bylo s explicit NV12 sampler).
final class MetalPreviewRenderer: @unchecked Sendable {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let ciContext: CIContext
    let metalLayer: CAMetalLayer

    /// Framebuffer layout — matchuje drawable pixel format.
    private static let drawablePixelFormat: MTLPixelFormat = .bgra8Unorm

    init?() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let cq = dev.makeCommandQueue() else {
            FileHandle.safeStderrWrite(
                "[MetalPreviewRenderer] device/queue creation failed\n".data(using: .utf8)!)
            return nil
        }
        self.device = dev
        self.commandQueue = cq
        // BT.709 working space (HEVC default) → sRGB output (display default)
        self.ciContext = CIContext(mtlCommandQueue: cq, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.itur_709)!,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            .cacheIntermediates: false,
        ])

        let layer = CAMetalLayer()
        layer.device = dev
        layer.pixelFormat = Self.drawablePixelFormat
        layer.framebufferOnly = false  // false = Core Image může zapisovat
        layer.contentsGravity = .resizeAspect
        layer.isOpaque = true
        layer.backgroundColor = NSColor.black.cgColor
        self.metalLayer = layer
    }

    /// Render CVPixelBuffer (IOSurface NV12 z H265Decoder) na CAMetalLayer drawable.
    /// Volá se ze VT decoder thread (nonisolated). Je thread-safe — `commandQueue`,
    /// `metalLayer.nextDrawable()`, `ciContext.startTask` jsou všechny thread-safe.
    ///
    /// **Autoreleasepool:** volané 30×/s z VT decoder threadu (non-dispatch → bez
    /// automatic autoreleasepool draining). Každé volání vytvoří CIImage +
    /// transformed + composited + CIRenderDestination — všechny NSObject. Bez
    /// explicit autoreleasepool rostou alokace ~32 MB/h.
    func display(pixelBuffer: CVPixelBuffer) {
        autoreleasepool { displayInner(pixelBuffer: pixelBuffer) }
    }

    private func displayInner(pixelBuffer: CVPixelBuffer) {
        let signpost = SPZSignposts.signposter.beginInterval(SPZSignposts.Name.metalPreview)
        defer { SPZSignposts.signposter.endInterval(SPZSignposts.Name.metalPreview, signpost) }
        let layerBounds = metalLayer.bounds
        guard layerBounds.width > 0, layerBounds.height > 0 else { return }

        // Scale factor pro HiDPI (Retina) — layer.drawableSize musí matchovat backing.
        let screenScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let targetSize = CGSize(
            width: layerBounds.width * screenScale,
            height: layerBounds.height * screenScale
        )
        if metalLayer.drawableSize != targetSize {
            metalLayer.drawableSize = targetSize
        }

        guard let drawable = metalLayer.nextDrawable(),
              let cmdBuf = commandQueue.makeCommandBuffer() else {
            // Drawable pool exhausted — přeskočit frame (bude další za ~16 ms).
            return
        }

        // CVPixelBuffer → CIImage: zero-copy přes IOSurface. CIImage drží reference
        // na pb dokud není composite rendered. Y-plane + CbCr plane se samplujou
        // v CI-internal Metal shaderu, BT.709 matice je aplikovaná via working colorspace.
        let srcImage = CIImage(cvPixelBuffer: pixelBuffer)
        let srcExtent = srcImage.extent
        guard srcExtent.width > 0, srcExtent.height > 0 else { return }

        // Aspect-fit matemika (matchuje `.resizeAspect` semantiku).
        let dstW = targetSize.width, dstH = targetSize.height
        let scaleX = dstW / srcExtent.width
        let scaleY = dstH / srcExtent.height
        let fitScale = min(scaleX, scaleY)
        let renderedW = srcExtent.width * fitScale
        let renderedH = srcExtent.height * fitScale
        let offsetX = (dstW - renderedW) / 2.0
        let offsetY = (dstH - renderedH) / 2.0

        let fitted = srcImage
            .transformed(by: CGAffineTransform(scaleX: fitScale, y: fitScale))
            .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))

        // Black letterbox background — černá barva composited UNDER fitted image.
        let black = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: targetSize))
        let composite = fitted.composited(over: black)

        // Render destination wrapping drawable's MTLTexture. startTask(toRender:to:)
        // vytvoří CI internal command encoder na commandBuffer a enqueue-uje work.
        let dest = CIRenderDestination(
            width: Int(dstW),
            height: Int(dstH),
            pixelFormat: Self.drawablePixelFormat,
            commandBuffer: cmdBuf,
            mtlTextureProvider: { drawable.texture }
        )
        dest.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)

        do {
            _ = try ciContext.startTask(toRender: composite, to: dest)
        } catch {
            FileHandle.safeStderrWrite(
                "[MetalPreviewRenderer] CI render failed: \(error)\n".data(using: .utf8)!)
            return
        }

        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    /// Vyčistí drawable na solid black (equivalent `flushAndRemoveImage` pro AVSBDL).
    /// Volá se při disconnect, aby preview nezachovalo poslední frame.
    func clear() {
        let layerBounds = metalLayer.bounds
        guard layerBounds.width > 0, layerBounds.height > 0 else { return }
        guard let drawable = metalLayer.nextDrawable(),
              let cmdBuf = commandQueue.makeCommandBuffer() else { return }
        let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: {
            let d = MTLRenderPassDescriptor()
            d.colorAttachments[0].texture = drawable.texture
            d.colorAttachments[0].loadAction = .clear
            d.colorAttachments[0].storeAction = .store
            d.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            return d
        }())
        encoder?.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }
}
