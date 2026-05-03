import Foundation
import Metal
import CoreImage
import CoreVideo
import CoreGraphics
import simd

/// Wrapper kolem `PlateTransform.metal` compute shader.
///
/// Fúzuje ROI crop + rotation + perspective correction + detectionQuad crop +
/// NV12 → BGRA conversion do jednoho Metal compute dispatch. Vstup: NV12
/// CVPixelBuffer z VTDecompressionSession (zero-copy IOSurface). Výstup:
/// CGImage velikosti canonical plate-sized (~520×110 px pro CZ SPZ aspect),
/// připravený pro Vision VNRecognizeTextRequest.
///
/// **Stav:** infrastruktura hotová, **nezapojeno** do PlateOCR pipeline za
/// feature flagem `AppState.useMetalKernel` (default false). Core Image
/// pipeline zůstává primary path; Metal kernel se spustí jen pokud user
/// flag zapne v Settings → Advanced. Metal je perf optimization
/// (~0.5 ms/frame save).
///
/// Design:
/// - MTLDevice + MTLLibrary (z bundled `PlateTransform.metallib`) jsou lazy
///   singleton — kernel se kompiluje jednou.
/// - `CVMetalTextureCache` recykluje IOSurface → MTLTexture bindings (zero-copy).
/// - Output MTLTexture je IOSurface-backed → CGImage conversion přes
///   `CIImage(mtlTexture:)` + `CIContext.createCGImage()`.
final class PlateTransformKernel {
    /// Singleton — load .metallib once, cached pro re-use napříč kamerami.
    static let shared: PlateTransformKernel? = PlateTransformKernel()

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            FileHandle.safeStderrWrite(
                "[PlateTransformKernel] MTLCreateSystemDefaultDevice failed\n"
                    .data(using: .utf8)!)
            return nil
        }
        self.device = device

        guard let cq = device.makeCommandQueue() else {
            FileHandle.safeStderrWrite(
                "[PlateTransformKernel] makeCommandQueue failed\n".data(using: .utf8)!)
            return nil
        }
        self.commandQueue = cq

        // Load .metallib z bundled Resources (viz build_app.sh — xcrun metal +
        // metallib produkuje PlateTransform.metallib bundled do .app).
        guard let libURL = Bundle.main.url(forResource: "PlateTransform",
                                            withExtension: "metallib") else {
            FileHandle.safeStderrWrite(
                "[PlateTransformKernel] PlateTransform.metallib not found in Bundle\n"
                    .data(using: .utf8)!)
            return nil
        }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(URL: libURL)
        } catch {
            FileHandle.safeStderrWrite(
                "[PlateTransformKernel] makeLibrary failed: \(error)\n".data(using: .utf8)!)
            return nil
        }
        guard let function = library.makeFunction(name: "plateTransform") else {
            FileHandle.safeStderrWrite(
                "[PlateTransformKernel] makeFunction(plateTransform) failed\n"
                    .data(using: .utf8)!)
            return nil
        }
        do {
            self.pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            FileHandle.safeStderrWrite(
                "[PlateTransformKernel] makeComputePipelineState failed: \(error)\n"
                    .data(using: .utf8)!)
            return nil
        }

        var cacheRef: CVMetalTextureCache? = nil
        let cacheStatus = CVMetalTextureCacheCreate(
            kCFAllocatorDefault, nil, device, nil, &cacheRef
        )
        guard cacheStatus == kCVReturnSuccess, let cache = cacheRef else {
            FileHandle.safeStderrWrite(
                "[PlateTransformKernel] CVMetalTextureCacheCreate failed: \(cacheStatus)\n"
                    .data(using: .utf8)!)
            return nil
        }
        self.textureCache = cache
        FileHandle.safeStderrWrite(
            "[PlateTransformKernel] ready — Metal device: \(device.name)\n"
                .data(using: .utf8)!)
    }

    /// Aplikuje fúzovanou transformaci na NV12 CVPixelBuffer.
    ///
    /// - Parameters:
    ///   - pixelBuffer: NV12 (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    ///   - homography: inverse 3x3 matrix — z destination[x,y] → source[u,v]
    ///     (produkuje ho caller z ROI + rotation + perspective + quad crop)
    ///   - outputSize: canonical plate size (např. 600×130)
    /// - Returns: CGImage BGRA, nebo nil při selhání
    func transform(
        pixelBuffer: CVPixelBuffer,
        homography: simd_float3x3,
        outputSize: (width: Int, height: Int)
    ) -> CGImage? {
        let pbFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard pbFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
           || pbFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else {
            return nil  // jen NV12 support
        }

        // Vytáhni Y a UV plane jako MTLTexture přes CVMetalTextureCache (zero-copy)
        guard let yTex = makePlaneTexture(pb: pixelBuffer, plane: 0, format: .r8Unorm),
              let uvTex = makePlaneTexture(pb: pixelBuffer, plane: 1, format: .rg8Unorm) else {
            return nil
        }

        // Output texture — BGRA, IOSurface-backed pro zero-copy CGImage conversion
        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: outputSize.width,
            height: outputSize.height,
            mipmapped: false
        )
        outDesc.usage = [.shaderWrite, .shaderRead]
        outDesc.storageMode = .private  // GPU-local, readback via blit nebo CIImage bridge
        guard let outputTex = device.makeTexture(descriptor: outDesc) else { return nil }

        // Upload homography matrix jako inline buffer
        var hom = homography
        guard let cmdBuf = commandQueue.makeCommandBuffer(),
              let enc = cmdBuf.makeComputeCommandEncoder() else {
            return nil
        }
        enc.setComputePipelineState(pipeline)
        enc.setTexture(yTex, index: 0)
        enc.setTexture(uvTex, index: 1)
        enc.setTexture(outputTex, index: 2)
        enc.setBytes(&hom, length: MemoryLayout<simd_float3x3>.stride, index: 0)

        // Threadgroup dispatch — 16×16 threads per group (standard Metal pattern)
        let tgSize = MTLSize(width: 16, height: 16, depth: 1)
        let tgCount = MTLSize(
            width: (outputSize.width + 15) / 16,
            height: (outputSize.height + 15) / 16,
            depth: 1
        )
        enc.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
        enc.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        // Convert MTLTexture → CGImage přes CIImage bridge
        // (CIImage čte Metal texture IOSurface zero-copy, CGImage kopíruje 1× ven z GPU)
        // Toto je single memcpy — akceptovatelné, Vision stejně potřebuje CGImage.
        guard let ciImage = CIImage(mtlTexture: outputTex, options: nil) else { return nil }
        // Orient flip — Metal texture je top-left, CGImage expect bottom-left standard
        let flipped = ciImage.transformed(by: CGAffineTransform(
            a: 1, b: 0, c: 0, d: -1,
            tx: 0, ty: CGFloat(outputSize.height)
        ))
        let context = CIContext(mtlDevice: device)
        return context.createCGImage(flipped, from: CGRect(
            x: 0, y: 0, width: outputSize.width, height: outputSize.height
        ))
    }

    private func makePlaneTexture(pb: CVPixelBuffer, plane: Int,
                                   format: MTLPixelFormat) -> MTLTexture? {
        let width = CVPixelBufferGetWidthOfPlane(pb, plane)
        let height = CVPixelBufferGetHeightOfPlane(pb, plane)
        var cvTexture: CVMetalTexture? = nil
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pb,
            nil,
            format,
            width,
            height,
            plane,
            &cvTexture
        )
        guard status == kCVReturnSuccess, let cv = cvTexture else { return nil }
        return CVMetalTextureGetTexture(cv)
    }
}
