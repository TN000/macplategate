import Accelerate
import CoreGraphics
import CoreImage
import Foundation
import OnnxRuntimeBindings

// MARK: - Public types

enum PlateSRPurpose: String, Sendable {
    case snapshot
    case visionRetry
    case secondaryOCR
}

enum PlateSRSkipReason: String, Sendable {
    case modelUnavailable = "model_unavailable"
    case budgetExceeded = "budget_exceeded"
    case cropTooLarge = "crop_too_large"
    case cropTooSmall = "crop_too_small"
    case alreadySharp = "already_sharp"
    case poorExposure = "poor_exposure"
    case lowDetectionConfidence = "low_detection_confidence"
    case disabledByUser = "disabled_by_user"
    case sampledOut = "sampled_out"
    case unsupportedShape = "unsupported_shape"
    case cpuFallbackRisk = "cpu_fallback_risk"
    case highConfidenceBaseline = "high_confidence_baseline"
    case temporarilyDisabledAfterFailures = "temporarily_disabled_after_failures"
}

enum PlateSRFailureReason: String, Sendable {
    case modelLoadFailed = "model_load_failed"
    case sessionInitFailed = "session_init_failed"
    case inputConversionFailed = "input_conversion_failed"
    case inferenceFailed = "inference_failed"
    case outputConversionFailed = "output_conversion_failed"
    case unsupportedShape = "unsupported_shape"
    case profilingFailed = "profiling_failed"
}

struct PlateSRMetrics: Sendable {
    let inferenceMs: Double
    let cacheHit: Bool
    let inputW: Int
    let inputH: Int
    let paddedW: Int
    let paddedH: Int
    let outputW: Int
    let outputH: Int
}

enum PlateSRResult {
    case applied(CGImage, metrics: PlateSRMetrics)
    case skipped(reason: PlateSRSkipReason)
    case failed(reason: PlateSRFailureReason, message: String)
}

struct PlateCropMetadata: Sendable {
    let cameraID: String
    let trackID: String?
    let cropRect: CGRect
    let detectionConfidence: Double
}

// MARK: - Lockfile

struct PlateSRLockfile: Codable, Sendable {
    let repo: String
    let revision: String
    let file: String
    let sha256: String
    let sizeBytes: Int
    let license: String
    let modelKind: String
    let scaleFactor: Int
    let inputName: String
    let outputName: String

    enum CodingKeys: String, CodingKey {
        case repo, revision, file, sha256, license
        case sizeBytes = "size_bytes"
        case modelKind = "model_kind"
        case scaleFactor = "scale_factor"
        case inputName = "input_name"
        case outputName = "output_name"
    }

    var versionHash: UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in (revision + sha256).utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100000001b3
        }
        return h
    }
}

// MARK: - Engine

final class PlateSREngine: @unchecked Sendable {
    static let shared = PlateSREngine()

    private static let env: ORTEnv? = {
        do { return try ORTEnv(loggingLevel: ORTLoggingLevel.warning) }
        catch {
            FileHandle.safeStderrWrite(
                "[PlateSREngine] ORTEnv init failed: \(error)\n".data(using: .utf8)!)
            return nil
        }
    }()

    let isAvailable: Bool
    let lockfile: PlateSRLockfile?

    private let session: ORTSession?
    private let inputName: String
    private let outputName: String

    // Circuit breaker state (mutex protected)
    private let stateLock = NSLock()
    private var consecutiveFailures: Int = 0
    private var disabledUntil: Date?
    private var totalInferences: Int = 0
    private var firstInferenceLogged: Bool = false

    // Test injection
    init(modelURL: URL?, lockfileURL: URL?) {
        let resolved = Self.loadSession(modelURL: modelURL, lockfileURL: lockfileURL)
        self.isAvailable = (resolved.session != nil)
        self.session = resolved.session
        self.inputName = resolved.inputName
        self.outputName = resolved.outputName
        self.lockfile = resolved.lockfile
    }

    private convenience init() {
        let modelURL = Self.resolveResource(name: "PlateSR", ext: "onnx")
        let lockURL = Self.resolveResource(name: "PlateSR.model", ext: "json")
        self.init(modelURL: modelURL, lockfileURL: lockURL)
    }

    private static func loadSession(modelURL: URL?, lockfileURL: URL?) -> (session: ORTSession?,
                                                                            inputName: String,
                                                                            outputName: String,
                                                                            lockfile: PlateSRLockfile?) {
        var lockfile: PlateSRLockfile? = nil
        if let lockURL = lockfileURL,
           let data = try? Data(contentsOf: lockURL),
           let parsed = try? JSONDecoder().decode(PlateSRLockfile.self, from: data) {
            lockfile = parsed
        }

        guard let env = env else {
            return (nil, "pixel_values", "reconstruction", lockfile)
        }
        guard let modelURL = modelURL, FileManager.default.fileExists(atPath: modelURL.path) else {
            FileHandle.safeStderrWrite(
                "[PlateSREngine] PlateSR.onnx not found — super-resolution disabled\n"
                    .data(using: .utf8)!)
            return (nil, "pixel_values", "reconstruction", lockfile)
        }

        let sessionLoadStart = Date()
        do {
            let options = try ORTSessionOptions()
            _ = try options.setGraphOptimizationLevel(ORTGraphOptimizationLevel.all)
            _ = try options.setLogSeverityLevel(ORTLoggingLevel.warning)
            // CRITICAL: dynamic input shapes (Swin2SR pixel_values [1,3,H,W])
            // způsobí buffer-reuse "Shape mismatch" error když po sobě jdou dva
            // crop-y různé velikosti. Vypnutí memory pattern eliminuje reuse.
            _ = try options.addConfigEntry(withKey: "session.disable_mem_pattern", value: "1")
            // **RAM fix:** bez disable arena ORT runtime drží malloc'd arenu
            // ~100-200 MB na proces život. S CoreML EP compile cache per shape
            // se to multiplikuje do 1+ GB. Disable + use_device_allocator = řez RSS.
            _ = try options.addConfigEntry(withKey: "session.use_env_allocators", value: "0")
            _ = try options.addConfigEntry(withKey: "session.disable_cpu_ep_fallback", value: "0")

            // CoreML EP with ANE-exclusion (useCPUAndGPU = true).
            // Verified header /onnxruntime-swift-package-manager/objectivec/include/ort_coreml_execution_provider.h:35
            if ORTIsCoreMLExecutionProviderAvailable() {
                let coreml = ORTCoreMLExecutionProviderOptions()
                coreml.useCPUAndGPU = true
                coreml.useCPUOnly = false
                coreml.onlyEnableForDevicesWithANE = false
                coreml.onlyAllowStaticInputShapes = false
                coreml.enableOnSubgraphs = true
                _ = try? options.appendCoreMLExecutionProvider(with: coreml)
            }

            let session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
            let inputs = try session.inputNames()
            let outputs = try session.outputNames()
            let inputName = lockfile?.inputName ?? inputs.first ?? "pixel_values"
            let outputName = lockfile?.outputName ?? outputs.first ?? "reconstruction"
            let loadMs = Date().timeIntervalSince(sessionLoadStart) * 1000.0

            FileHandle.safeStderrWrite(
                "[PlateSREngine] loaded model=\(modelURL.lastPathComponent) input=\(inputName) output=\(outputName) load=\(Int(loadMs))ms\n"
                    .data(using: .utf8)!)

            Audit.event("super_resolution_session_init", [
                "provider": "CoreML",
                "compute_units": "CPUAndGPU",
                "model_revision": lockfile?.revision ?? "unknown",
                "model_kind": lockfile?.modelKind ?? "unknown",
                "model_size_bytes": lockfile?.sizeBytes ?? 0,
                "session_load_ms": loadMs,
                "input_name": inputName,
                "output_name": outputName,
            ])
            return (session, inputName, outputName, lockfile)
        } catch {
            FileHandle.safeStderrWrite(
                "[PlateSREngine] session init failed: \(error)\n".data(using: .utf8)!)
            Audit.event("super_resolution_session_init_failed", [
                "error": String(describing: error),
            ])
            return (nil, "pixel_values", "reconstruction", lockfile)
        }
    }

    // MARK: - Public API

    // **Fixed canvas:** dynamic shape per crop způsobí CoreML EP per-shape
    // compile cache (5 unique sizes × ~200 MB compiled graph = 1 GB RSS leak).
    // Pin canvas na fixed (256×96) → CoreML compile JEN 1× při warmup → reuse
    // pro všechna inference. Crops větší než canvas skipnou na Plan B Lanczos.
    static let fixedCanvasW: Int = 256
    static let fixedCanvasH: Int = 96

    /// 4× upscale via Swin2SR. Caller is responsible for AppState gates (master toggle
    /// + per-purpose flags) before calling.
    func upscale4x(_ image: CGImage,
                   purpose: PlateSRPurpose,
                   metadata: PlateCropMetadata) -> PlateSRResult {
        // Wrap whole inference in autoreleasepool — CIImage chains z post-processingu
        // mohou držet temporary GPU surfaces; bez explicit drain RSS roste.
        return autoreleasepool { upscale4xInternal(image, purpose: purpose, metadata: metadata) }
    }

    private func upscale4xInternal(_ image: CGImage,
                                   purpose: PlateSRPurpose,
                                   metadata: PlateCropMetadata) -> PlateSRResult {
        guard let session = session, isAvailable else {
            return .skipped(reason: .modelUnavailable)
        }
        // Skip pokud crop přesáhl fixed canvas — fallback na Plan B Lanczos.
        if image.width > Self.fixedCanvasW || image.height > Self.fixedCanvasH {
            return .skipped(reason: .unsupportedShape)
        }

        // Circuit breaker check
        stateLock.lock()
        if let disabledUntil = disabledUntil {
            if Date() < disabledUntil {
                stateLock.unlock()
                return .skipped(reason: .temporarilyDisabledAfterFailures)
            } else {
                self.disabledUntil = nil  // breaker auto-reopens
            }
        }
        stateLock.unlock()

        // Cache lookup
        let cacheKey = PlateSRCache.shared.makeKey(image: image,
                                                    cameraID: metadata.cameraID,
                                                    cropRect: metadata.cropRect,
                                                    purpose: purpose,
                                                    modelVersion: lockfile?.versionHash ?? 0)
        if let cached = PlateSRCache.shared.get(key: cacheKey) {
            Audit.event("super_resolution_cache_hit", [
                "purpose": purpose.rawValue,
                "input_w": image.width, "input_h": image.height,
            ])
            return .applied(cached, metrics: PlateSRMetrics(
                inferenceMs: 0, cacheHit: true,
                inputW: image.width, inputH: image.height,
                paddedW: 0, paddedH: 0,
                outputW: cached.width, outputH: cached.height
            ))
        }

        // **Fixed canvas** (eliminuje CoreML multi-shape compile cache → ~1 GB RSS).
        // Crop centered v canvas, mid-gray fill na borders.
        let paddedW = Self.fixedCanvasW
        let paddedH = Self.fixedCanvasH
        let leftPad = (paddedW - image.width) / 2
        let topPad = (paddedH - image.height) / 2

        guard let paddedRGBFloats = makePaddedRGBFloats(from: image,
                                                         paddedW: paddedW,
                                                         paddedH: paddedH,
                                                         leftPad: leftPad,
                                                         topPad: topPad) else {
            return registerFailure(.inputConversionFailed, "padded RGB float conversion failed")
        }

        // Build input tensor [1, 3, paddedH, paddedW] fp32
        let tensorByteCount = paddedRGBFloats.count * MemoryLayout<Float>.stride
        let data = NSMutableData(bytes: paddedRGBFloats, length: tensorByteCount)
        let input: ORTValue
        do {
            input = try ORTValue(tensorData: data,
                                 elementType: ORTTensorElementDataType.float,
                                 shape: [1,
                                         NSNumber(value: 3),
                                         NSNumber(value: paddedH),
                                         NSNumber(value: paddedW)])
        } catch {
            return registerFailure(.inputConversionFailed, "ORTValue init: \(error)")
        }

        let inferStart = Date()
        let outputs: [String: ORTValue]
        do {
            outputs = try session.run(withInputs: [inputName: input],
                                      outputNames: Set([outputName]),
                                      runOptions: nil)
        } catch {
            return registerFailure(.inferenceFailed, "session.run: \(error)")
        }
        let inferMs = Date().timeIntervalSince(inferStart) * 1000.0

        guard let outputTensor = outputs[outputName],
              let info = try? outputTensor.tensorTypeAndShapeInfo(),
              info.elementType == ORTTensorElementDataType.float,
              let outData = try? outputTensor.tensorData() else {
            return registerFailure(.outputConversionFailed, "output tensor not float or missing")
        }
        let outShape = info.shape.map { $0.intValue }
        // Expect [1, 3, 4*paddedH, 4*paddedW]
        guard outShape.count == 4, outShape[0] == 1, outShape[1] == 3,
              outShape[2] == paddedH * 4, outShape[3] == paddedW * 4 else {
            return registerFailure(.outputConversionFailed,
                                   "unexpected output shape \(outShape) for input \(paddedW)×\(paddedH)")
        }

        let outFloatCount = outData.length / MemoryLayout<Float>.stride
        let outFloatPtr = outData.bytes.assumingMemoryBound(to: Float.self)
        guard let upscaledFull = makeCGImageFromCHWFloats(ptr: outFloatPtr,
                                                           count: outFloatCount,
                                                           width: paddedW * 4,
                                                           height: paddedH * 4) else {
            return registerFailure(.outputConversionFailed, "CHW→CGImage conversion failed")
        }

        // Crop padded output back to exact 4× original
        let cropRect = CGRect(x: leftPad * 4,
                              y: topPad * 4,
                              width: image.width * 4,
                              height: image.height * 4)
        guard let final = upscaledFull.cropping(to: cropRect) else {
            return registerFailure(.outputConversionFailed, "crop-back failed")
        }

        registerSuccess()
        let cost = final.width * final.height * 4
        PlateSRCache.shared.put(image: final, key: cacheKey, cost: cost)

        // Telemetry: log first inference latency separately from steady-state
        stateLock.lock()
        let isFirst = !firstInferenceLogged
        firstInferenceLogged = true
        totalInferences += 1
        stateLock.unlock()

        let metrics = PlateSRMetrics(
            inferenceMs: inferMs, cacheHit: false,
            inputW: image.width, inputH: image.height,
            paddedW: paddedW, paddedH: paddedH,
            outputW: final.width, outputH: final.height
        )

        if isFirst {
            Audit.event("super_resolution_first_inference", [
                "inference_ms": inferMs,
                "input_w": image.width, "input_h": image.height,
                "padded_w": paddedW, "padded_h": paddedH,
            ])
        }

        Audit.event("super_resolution_applied", [
            "purpose": purpose.rawValue,
            "inference_ms": inferMs,
            "input_w": image.width, "input_h": image.height,
            "padded_w": paddedW, "padded_h": paddedH,
            "output_w": final.width, "output_h": final.height,
        ])

        return .applied(final, metrics: metrics)
    }

    /// Idle warmup — pre-compile CoreML graph at production canvas size, takže
    /// first user-visible call neplatí cold-start spike (~13 sec compile).
    /// Dummy size MUSÍ být = fixedCanvas, jinak CoreML re-compile při production.
    func warmup() {
        guard isAvailable else { return }
        let dummy = makeDummyImage(width: Self.fixedCanvasW, height: Self.fixedCanvasH)
        guard let dummy = dummy else { return }
        let meta = PlateCropMetadata(cameraID: "warmup",
                                      trackID: nil,
                                      cropRect: .zero,
                                      detectionConfidence: 1.0)
        _ = upscale4x(dummy, purpose: .snapshot, metadata: meta)
    }

    // MARK: - Circuit breaker bookkeeping

    private func registerSuccess() {
        stateLock.lock()
        consecutiveFailures = 0
        stateLock.unlock()
    }

    private func registerFailure(_ reason: PlateSRFailureReason, _ message: String) -> PlateSRResult {
        FileHandle.safeStderrWrite(
            "[PlateSREngine] failure \(reason.rawValue): \(message)\n".data(using: .utf8)!)

        stateLock.lock()
        let openImmediately: Bool
        switch reason {
        case .modelLoadFailed, .sessionInitFailed:
            openImmediately = true
        case .inferenceFailed, .inputConversionFailed, .outputConversionFailed:
            consecutiveFailures += 1
            openImmediately = (consecutiveFailures >= 3)
        case .unsupportedShape:
            openImmediately = false  // per-input issue, not engine
        case .profilingFailed:
            openImmediately = false  // telemetry-only
        }
        if openImmediately {
            disabledUntil = Date().addingTimeInterval(300)
            consecutiveFailures = 0
            stateLock.unlock()
            Audit.event("super_resolution_circuit_breaker_open", [
                "cause": reason.rawValue,
                "duration_seconds": 300,
            ])
        } else {
            stateLock.unlock()
        }
        return .failed(reason: reason, message: message)
    }

    // MARK: - Image conversion helpers

    /// Pad CGImage to (paddedW × paddedH) with reflect padding, return CHW fp32 RGB
    /// in [0, 1].
    private func makePaddedRGBFloats(from image: CGImage,
                                     paddedW: Int,
                                     paddedH: Int,
                                     leftPad: Int,
                                     topPad: Int) -> [Float]? {
        let totalCount = paddedW * paddedH * 3
        var out = [Float](repeating: 0, count: totalCount)

        // Render padded RGBA via CGContext with reflect-pad emulated by drawing
        // mirrored copies. For simplicity (and Swin2SR robustness on reasonable-size
        // borders) we use a centered draw with mid-gray fill — visually equivalent
        // to "padding doesn't disturb attention windows" for borders <= 32 px.
        var rgba = [UInt8](repeating: 128, count: paddedW * paddedH * 4)
        let drewOK = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base,
                                      width: paddedW, height: paddedH,
                                      bitsPerComponent: 8, bytesPerRow: paddedW * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)
            ctx.fill(CGRect(x: 0, y: 0, width: paddedW, height: paddedH))
            // CGContext is BL-origin → flip Y for top-left-origin draw
            let dstY = CGFloat(paddedH - topPad - image.height)
            ctx.draw(image, in: CGRect(x: CGFloat(leftPad),
                                       y: dstY,
                                       width: CGFloat(image.width),
                                       height: CGFloat(image.height)))
            return true
        }
        guard drewOK else { return nil }

        // CHW conversion: rgba is HWC RGBA8 → CHW RGB float32 in [0,1].
        // Note: CGContext drew in BL-origin; output tensor is in TL-origin (PyTorch
        // convention). Flip rows during CHW pack.
        let plane = paddedW * paddedH
        for y in 0..<paddedH {
            let srcY = paddedH - 1 - y  // BL → TL flip
            for x in 0..<paddedW {
                let srcIdx = (srcY * paddedW + x) * 4
                let dstIdx = y * paddedW + x
                out[0 * plane + dstIdx] = Float(rgba[srcIdx + 0]) / 255.0
                out[1 * plane + dstIdx] = Float(rgba[srcIdx + 1]) / 255.0
                out[2 * plane + dstIdx] = Float(rgba[srcIdx + 2]) / 255.0
            }
        }
        return out
    }

    /// Build CGImage from CHW fp32 RGB tensor in [0, 1] (clamp + scale to uint8).
    private func makeCGImageFromCHWFloats(ptr: UnsafePointer<Float>,
                                          count: Int,
                                          width: Int,
                                          height: Int) -> CGImage? {
        let plane = width * height
        guard count == plane * 3 else { return nil }
        var rgba = [UInt8](repeating: 255, count: plane * 4)
        // Tensor in TL-origin → flip back to BL for CGContext.
        for y in 0..<height {
            let srcY = height - 1 - y
            for x in 0..<width {
                let srcIdx = srcY * width + x
                let dstIdx = (y * width + x) * 4
                rgba[dstIdx + 0] = clampToU8(ptr[0 * plane + srcIdx])
                rgba[dstIdx + 1] = clampToU8(ptr[1 * plane + srcIdx])
                rgba[dstIdx + 2] = clampToU8(ptr[2 * plane + srcIdx])
                rgba[dstIdx + 3] = 255
            }
        }
        return rgba.withUnsafeMutableBytes { raw -> CGImage? in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base,
                                      width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return nil
            }
            return ctx.makeImage()
        }
    }

    @inline(__always)
    private func clampToU8(_ v: Float) -> UInt8 {
        let scaled = max(0.0, min(255.0, v * 255.0))
        return UInt8(scaled.rounded())
    }

    private func makeDummyImage(width: Int, height: Int) -> CGImage? {
        let bytes = [UInt8](repeating: 128, count: width * height * 4)
        return bytes.withUnsafeBytes { raw -> CGImage? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                  let ctx = CGContext(data: UnsafeMutableRawPointer(mutating: base),
                                      width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return nil
            }
            return ctx.makeImage()
        }
    }

    // MARK: - Resource resolution

    private static func resolveResource(name: String, ext: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) { return url }
        if let url = Bundle.module.url(forResource: name, withExtension: ext) { return url }
        if let url = Bundle.module.url(forResource: "Resources/\(name)", withExtension: ext) { return url }
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        let candidates = [
            cwd.appendingPathComponent("Sources/SPZApp/Resources/\(name).\(ext)"),
            cwd.appendingPathComponent("macapp/Sources/SPZApp/Resources/\(name).\(ext)"),
        ]
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }
}

@inline(__always)
func ceilToMultiple(_ value: Int, _ multiple: Int) -> Int {
    let m = max(1, multiple)
    return ((value + m - 1) / m) * m
}
