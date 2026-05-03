import CoreGraphics
import Foundation
import OnnxRuntimeBindings

/// Fast Plate OCR CCT-XS v2 global model through ONNX Runtime.
///
/// This is the single production secondary OCR path. We intentionally avoid
/// CoreML conversion here: the legacy MobileViT ONNX route deadlocks in
/// coremltools on local macOS. ORT runs the model file directly, so there is no
/// ONNX -> MIL/CoreML conversion step in the app pipeline.
final class FastPlateOCROnnxEngine: PlateRecognitionEngine, @unchecked Sendable {
    let name = "fast-plate-ocr-cct-xs-v2-global-onnx"

    private static let env: ORTEnv? = {
        do {
            return try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
        } catch {
            FileHandle.safeStderrWrite(
                "[FastPlateOCROnnxEngine] ORTEnv init failed: \(error)\n"
                    .data(using: .utf8)!)
            return nil
        }
    }()

    private let session: ORTSession
    private let inputName: String
    private let outputNames: Set<String>
    private let inputWidth: Int
    private let inputHeight: Int
    private let inputChannels: Int
    private let alphabet: [Character]

    init?() {
        guard let env = Self.env else { return nil }
        guard let modelURL = Self.resolveResourceURL(name: "FastPlateOCR", ext: "onnx") else {
            FileHandle.safeStderrWrite(
                "[FastPlateOCROnnxEngine] FastPlateOCR.onnx not found — secondary OCR disabled\n"
                    .data(using: .utf8)!)
            return nil
        }
        self.inputWidth = 128
        self.inputHeight = 64
        self.inputChannels = 3
        self.alphabet = Self.loadAlphabet()

        do {
            let options = try ORTSessionOptions()
            _ = try options.setGraphOptimizationLevel(ORTGraphOptimizationLevel.all)
            _ = try options.setIntraOpNumThreads(2)
            _ = try options.setLogSeverityLevel(ORTLoggingLevel.warning)
            self.session = try ORTSession(env: env,
                                          modelPath: modelURL.path,
                                          sessionOptions: options)
            let inputs = try session.inputNames()
            let outputs = try session.outputNames()
            guard let firstInput = inputs.first, !outputs.isEmpty else {
                FileHandle.safeStderrWrite(
                    "[FastPlateOCROnnxEngine] ONNX model has no usable inputs/outputs\n"
                        .data(using: .utf8)!)
                return nil
            }
            self.inputName = firstInput
            self.outputNames = Set(outputs)
            FileHandle.safeStderrWrite(
                "[FastPlateOCROnnxEngine] loaded model=\(modelURL.lastPathComponent) input=\(firstInput)(\(inputWidth)×\(inputHeight)×\(inputChannels) uint8) outputs=\(outputs.joined(separator: ",")) alphabet=\(alphabet.count)\n"
                    .data(using: .utf8)!)
        } catch {
            FileHandle.safeStderrWrite(
                "[FastPlateOCROnnxEngine] session init failed: \(error)\n"
                    .data(using: .utf8)!)
            return nil
        }
    }

    func recognize(crop: CGImage) async -> EngineReading? {
        autoreleasepool {
            guard let bytes = Self.makeRGBBytes(from: crop,
                                                width: inputWidth,
                                                height: inputHeight) else {
                return nil
            }
            let data = NSMutableData(bytes: bytes, length: bytes.count)
            let input: ORTValue
            do {
                input = try ORTValue(tensorData: data,
                                     elementType: ORTTensorElementDataType.uInt8,
                                     shape: [1, NSNumber(value: inputHeight),
                                             NSNumber(value: inputWidth),
                                             NSNumber(value: inputChannels)])
            } catch {
                FileHandle.safeStderrWrite(
                    "[FastPlateOCROnnxEngine] input tensor failed: \(error)\n"
                        .data(using: .utf8)!)
                return nil
            }

            let outputs: [String: ORTValue]
            do {
                outputs = try session.run(withInputs: [inputName: input],
                                          outputNames: outputNames,
                                          runOptions: nil)
            } catch {
                FileHandle.safeStderrWrite(
                    "[FastPlateOCROnnxEngine] inference failed: \(error)\n"
                        .data(using: .utf8)!)
                return nil
            }

            return Self.decodeBestOutput(outputs: outputs, alphabet: alphabet)
        }
    }

    private static func decodeBestOutput(outputs: [String: ORTValue],
                                         alphabet: [Character]) -> EngineReading? {
        var best: EngineReading?
        for (_, output) in outputs {
            guard let info = try? output.tensorTypeAndShapeInfo(),
                  info.elementType == ORTTensorElementDataType.float,
                  let tensor = try? output.tensorData() else {
                continue
            }
            let shape = info.shape.map { $0.intValue }
            let count = tensor.length / MemoryLayout<Float>.stride
            let ptr = tensor.bytes.assumingMemoryBound(to: Float.self)
            let floats = Array(UnsafeBufferPointer(start: ptr, count: count))
            guard let reading = FastPlateOCROnnxDecoder.decode(logits: floats,
                                                               shape: shape,
                                                               alphabet: alphabet) else {
                continue
            }
            if best == nil || reading.confidence > (best?.confidence ?? 0) {
                best = reading
            }
        }
        return best
    }

    private static func loadAlphabet() -> [Character] {
        guard let configURL = resolveResourceURL(name: "FastPlateOCR.plate_config", ext: "yaml"),
              let text = try? String(contentsOf: configURL, encoding: .utf8),
              let parsed = FastPlateOCROnnxDecoder.parseAlphabet(fromPlateConfig: text),
              !parsed.isEmpty else {
            return Array("0123456788ZBCDEFGHIJKLMNOPQRSTUVWXYZ_")
        }
        return parsed
    }

    private static func resolveResourceURL(name: String, ext: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            return url
        }
        if let url = Bundle.module.url(forResource: name, withExtension: ext) {
            return url
        }
        if let url = Bundle.module.url(forResource: "Resources/\(name)", withExtension: ext) {
            return url
        }
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        let candidates = [
            cwd.appendingPathComponent("Sources/SPZApp/Resources/\(name).\(ext)"),
            cwd.appendingPathComponent("macapp/Sources/SPZApp/Resources/\(name).\(ext)")
        ]
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    private static func makeRGBBytes(from image: CGImage,
                                     width: Int,
                                     height: Int) -> [UInt8]? {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let ok = rgba.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress,
                  let ctx = CGContext(data: base,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            ctx.interpolationQuality = .high
            // **Aspect-ratio-preserving letterbox:** plný stretch na cílový box
            // ignorující aspect deformuje znaky (vertical stretch); CCT byl
            // trained na aspect-preserved crops s mid-gray fill. Scale uniform,
            // center, fill border na (128,128,128).
            ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let srcW = CGFloat(image.width)
            let srcH = CGFloat(image.height)
            let dstW = CGFloat(width)
            let dstH = CGFloat(height)
            let scale = min(dstW / srcW, dstH / srcH)
            let drawW = srcW * scale
            let drawH = srcH * scale
            let drawX = (dstW - drawW) * 0.5
            let drawY = (dstH - drawH) * 0.5
            ctx.draw(image, in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))
            return true
        }
        guard ok else { return nil }
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for px in 0..<(width * height) {
            rgb[px * 3 + 0] = rgba[px * 4 + 0]
            rgb[px * 3 + 1] = rgba[px * 4 + 1]
            rgb[px * 3 + 2] = rgba[px * 4 + 2]
        }
        return rgb
    }
}

enum FastPlateOCROnnxDecoder {
    static func parseAlphabet(fromPlateConfig text: String) -> [Character]? {
        if let chars = parseInlineList(key: "alphabet", text: text)
            ?? parseInlineList(key: "vocabulary", text: text)
            ?? parseInlineList(key: "charset", text: text)
            ?? parseInlineList(key: "characters", text: text) {
            return chars.joined().map { Character(String($0)) }
        }
        for key in ["alphabet", "vocabulary", "charset", "characters"] {
            if let scalar = parseScalar(key: key, text: text) {
                return scalar.map { Character(String($0)) }
            }
        }
        return nil
    }

    static func decode(logits: [Float],
                       shape: [Int],
                       alphabet: [Character]) -> EngineReading? {
        guard !logits.isEmpty, alphabet.count >= 2 else { return nil }
        let alphabetCount = alphabet.count
        let padIndex = alphabet.firstIndex(of: "_") ?? (alphabetCount - 1)
        guard let layout = inferLayout(shape: shape,
                                       totalCount: logits.count,
                                       alphabetCount: alphabetCount) else {
            return nil
        }

        var chars = ""
        var perCharConf: [Float] = []
        perCharConf.reserveCapacity(layout.slots)

        for slot in 0..<layout.slots {
            var maxLogit: Float = -.infinity
            for c in 0..<alphabetCount {
                let v = layout.value(logits, slot, c)
                if v > maxLogit { maxLogit = v }
            }
            var sumExp: Float = 0
            for c in 0..<alphabetCount {
                sumExp += expf(layout.value(logits, slot, c) - maxLogit)
            }
            var bestIdx = padIndex
            var bestProb: Float = 0
            for c in 0..<alphabetCount {
                let prob = expf(layout.value(logits, slot, c) - maxLogit) / max(sumExp, Float.leastNonzeroMagnitude)
                if prob > bestProb {
                    bestProb = prob
                    bestIdx = c
                }
            }
            if bestIdx == padIndex { continue }
            chars.append(alphabet[bestIdx])
            perCharConf.append(bestProb)
        }

        guard !chars.isEmpty, !perCharConf.isEmpty else { return nil }
        let mean = perCharConf.reduce(0, +) / Float(perCharConf.count)
        return EngineReading(text: chars, confidence: mean, perCharConf: perCharConf)
    }

    private struct Layout {
        let slots: Int
        let value: ([Float], Int, Int) -> Float
    }

    private static func inferLayout(shape: [Int],
                                    totalCount: Int,
                                    alphabetCount: Int) -> Layout? {
        let positiveShape = shape.filter { $0 > 0 }
        if positiveShape.count >= 2, positiveShape.last == alphabetCount {
            let dimsBeforeAlphabet = positiveShape.dropLast()
            let slotDims = (dimsBeforeAlphabet.first == 1 && dimsBeforeAlphabet.count > 1)
                ? dimsBeforeAlphabet.dropFirst()
                : ArraySlice(dimsBeforeAlphabet)
            let slots = max(1, slotDims.reduce(1, *))
            guard slots * alphabetCount <= totalCount else { return nil }
            return Layout(slots: slots) { data, slot, char in
                data[slot * alphabetCount + char]
            }
        }
        if positiveShape.count >= 3, positiveShape[positiveShape.count - 2] == alphabetCount {
            let slots = positiveShape.last ?? 0
            guard slots > 0, slots * alphabetCount <= totalCount else { return nil }
            return Layout(slots: slots) { data, slot, char in
                data[char * slots + slot]
            }
        }
        guard totalCount % alphabetCount == 0 else { return nil }
        let slots = totalCount / alphabetCount
        guard slots > 0 && slots <= 32 else { return nil }
        return Layout(slots: slots) { data, slot, char in
            data[slot * alphabetCount + char]
        }
    }

    private static func parseInlineList(key: String, text: String) -> [String]? {
        let prefix = "\(key):"
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix),
                  let open = trimmed.firstIndex(of: "["),
                  let close = trimmed.lastIndex(of: "]"),
                  open < close else {
                continue
            }
            let body = trimmed[trimmed.index(after: open)..<close]
            let values = body.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }.filter { !$0.isEmpty }
            return values.isEmpty ? nil : values
        }
        return nil
    }

    private static func parseScalar(key: String, text: String) -> String? {
        let prefix = "\(key):"
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix) else { continue }
            let raw = trimmed.dropFirst(prefix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return raw.isEmpty ? nil : raw
        }
        return nil
    }
}
