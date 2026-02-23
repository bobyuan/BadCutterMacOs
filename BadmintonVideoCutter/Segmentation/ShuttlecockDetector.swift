import Foundation
import AVFoundation
import CoreML
import CoreImage

/// ML-based shuttlecock detector using a TrackNetV3 CoreML model.
/// Buffers `seqLen` (3) consecutive frames, runs inference in batches, and returns
/// per-frame (timestamp, normalizedPosition?) detections.
///
/// Model architecture (TrackNetV3):
///   Input:  (1, 9, 288, 512) — 3 consecutive frames * 3 RGB channels, normalized 0-1
///   Output: (1, 3, 288, 512) — 3 heatmaps (post-sigmoid, 0-1), one per input frame
final class ShuttlecockDetector {
    private let model: MLModel
    private let inputWidth = 512
    private let inputHeight = 288
    private let seqLen = 3

    /// Buffered preprocessed frames (normalized RGB float arrays at model resolution).
    private var frameBuffer: [[Float]] = []
    /// Timestamps corresponding to each buffered frame.
    private var timestampBuffer: [TimeInterval] = []

    struct Detection {
        var timestamp: TimeInterval
        var position: (x: Double, y: Double)?
        var confidence: Double
    }

    init(modelURL: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all

        // Handle both .mlpackage (source) and .mlmodelc (compiled)
        let compiledURL: URL
        if modelURL.pathExtension == "mlmodelc" {
            compiledURL = modelURL
        } else {
            compiledURL = try MLModel.compileModel(at: modelURL)
        }
        self.model = try MLModel(contentsOf: compiledURL, configuration: config)
    }

    // MARK: - Frame Processing

    /// Feed one analysis frame. Returns detections when buffer is full (every seqLen frames).
    func processFrame(rgba: [UInt8], width: Int, height: Int, timestamp: TimeInterval) -> [Detection]? {
        let preprocessed = preprocessFrame(rgba, width: width, height: height)
        frameBuffer.append(preprocessed)
        timestampBuffer.append(timestamp)

        guard frameBuffer.count >= seqLen else { return nil }

        // Buffer full — run inference
        let positions = runInference()
        let timestamps = timestampBuffer

        // Clear buffers
        frameBuffer.removeAll(keepingCapacity: true)
        timestampBuffer.removeAll(keepingCapacity: true)

        // Build detections
        var detections: [Detection] = []
        for i in 0..<seqLen {
            let pos = i < positions.count ? positions[i] : nil
            detections.append(Detection(
                timestamp: i < timestamps.count ? timestamps[i] : 0,
                position: pos?.position,
                confidence: pos?.confidence ?? 0
            ))
        }

        return detections
    }

    /// Flush any remaining buffered frames (run inference with zero-padded buffer).
    func flush() -> [Detection]? {
        guard !frameBuffer.isEmpty else { return nil }

        let actualCount = frameBuffer.count

        // Pad with copies of the last frame to fill the buffer
        while frameBuffer.count < seqLen {
            frameBuffer.append(frameBuffer.last!)
            timestampBuffer.append(timestampBuffer.last!)
        }

        let positions = runInference()
        let timestamps = timestampBuffer

        frameBuffer.removeAll(keepingCapacity: true)
        timestampBuffer.removeAll(keepingCapacity: true)

        // Only return detections for the actual (non-padded) frames
        var detections: [Detection] = []
        for i in 0..<actualCount {
            let pos = i < positions.count ? positions[i] : nil
            detections.append(Detection(
                timestamp: timestamps[i],
                position: pos?.position,
                confidence: pos?.confidence ?? 0
            ))
        }

        return detections
    }

    // MARK: - Inference

    private func runInference() -> [(position: (x: Double, y: Double), confidence: Double)?] {
        guard frameBuffer.count >= seqLen else {
            return Array(repeating: nil, count: seqLen)
        }

        let channels = seqLen * 3  // 9
        let h = inputHeight
        let w = inputWidth

        // Build MLMultiArray: shape (1, 9, 288, 512) — NCHW
        guard let inputArray = try? MLMultiArray(shape: [1, NSNumber(value: channels), NSNumber(value: h), NSNumber(value: w)], dataType: .float32) else {
            return Array(repeating: nil, count: seqLen)
        }

        // Fill channels: frame0(3) + frame1(3) + frame2(3)
        // Source data is HWC (height*width*3), target is CHW per group
        // Use pointer access for the input array (which we created as Float32)
        let ptr = inputArray.dataPointer.assumingMemoryBound(to: Float.self)
        var channelOffset = 0
        for i in 0..<seqLen {
            frameBuffer[i].withUnsafeBufferPointer { srcBuf in
                let src = srcBuf.baseAddress!
                for c in 0..<3 {
                    let chPlane = (channelOffset + c) * (h * w)
                    for y in 0..<h {
                        let rowOffset = y * w
                        for x in 0..<w {
                            ptr[chPlane + rowOffset + x] = src[(rowOffset + x) * 3 + c]
                        }
                    }
                }
            }
            channelOffset += 3
        }

        // Run prediction
        let inputName = model.modelDescription.inputDescriptionsByName.keys.first ?? "input"
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: inputArray)]),
              let prediction = try? model.prediction(from: provider) else {
            return Array(repeating: nil, count: seqLen)
        }

        // Get output heatmaps: (1, 3, 288, 512) — already post-sigmoid (0-1)
        // IMPORTANT: output may be Float16, so use subscript access (auto-converts to NSNumber)
        guard let outputName = model.modelDescription.outputDescriptionsByName.keys.first,
              let outputValue = prediction.featureValue(for: outputName),
              let outputArray = outputValue.multiArrayValue else {
            return Array(repeating: nil, count: seqLen)
        }

        // Read output heatmap using direct pointer access when possible (avoids NSNumber boxing)
        var results: [(position: (x: Double, y: Double), confidence: Double)?] = []
        for i in 0..<seqLen {
            let planeOffset = i * h * w
            var heatmap = [Float](repeating: 0, count: h * w)
            if outputArray.dataType == .float32 {
                let ptr = outputArray.dataPointer.assumingMemoryBound(to: Float.self)
                for j in 0..<(h * w) { heatmap[j] = ptr[planeOffset + j] }
            } else {
                // Fallback to subscript access for Float16 or other types (auto-converts via NSNumber)
                for j in 0..<(h * w) { heatmap[j] = outputArray[planeOffset + j].floatValue }
            }
            results.append(extractPosition(from: heatmap, width: w, height: h))
        }

        return results
    }

    // MARK: - Preprocessing

    /// Convert RGBA frame to normalized RGB Float array at model resolution (288x512).
    private func preprocessFrame(_ rgba: [UInt8], width: Int, height: Int) -> [Float] {
        let targetW = inputWidth
        let targetH = inputHeight
        let pixelCount = targetW * targetH

        // Use unsafe pointer access to eliminate per-element bounds checking
        return rgba.withUnsafeBufferPointer { srcBuf in
            let src = srcBuf.baseAddress!

            // If input matches model resolution, convert directly
            if width == targetW && height == targetH {
                var rgb = [Float](repeating: 0, count: pixelCount * 3)
                for i in 0..<pixelCount {
                    rgb[i * 3] = Float(src[i * 4]) / 255.0
                    rgb[i * 3 + 1] = Float(src[i * 4 + 1]) / 255.0
                    rgb[i * 3 + 2] = Float(src[i * 4 + 2]) / 255.0
                }
                return rgb
            }

            // Resize via bilinear interpolation
            var rgb = [Float](repeating: 0, count: pixelCount * 3)
            let scaleX = Double(width) / Double(targetW)
            let scaleY = Double(height) / Double(targetH)

            for y in 0..<targetH {
                let srcY = Double(y) * scaleY
                let y0 = min(Int(srcY), height - 1)
                let y1 = min(y0 + 1, height - 1)
                let fy = Float(srcY) - Float(y0)

                for x in 0..<targetW {
                    let srcX = Double(x) * scaleX
                    let x0 = min(Int(srcX), width - 1)
                    let x1 = min(x0 + 1, width - 1)
                    let fx = Float(srcX) - Float(x0)

                    let dstIdx = (y * targetW + x) * 3
                    for c in 0..<3 {
                        let v00 = Float(src[(y0 * width + x0) * 4 + c])
                        let v10 = Float(src[(y0 * width + x1) * 4 + c])
                        let v01 = Float(src[(y1 * width + x0) * 4 + c])
                        let v11 = Float(src[(y1 * width + x1) * 4 + c])

                        let top = v00 * (1 - fx) + v10 * fx
                        let bot = v01 * (1 - fx) + v11 * fx
                        rgb[dstIdx + c] = (top * (1 - fy) + bot * fy) / 255.0
                    }
                }
            }

            return rgb
        }
    }

    // MARK: - Post-processing

    /// Post-process heatmap: threshold + weighted centroid.
    /// The model output is already post-sigmoid (0-1), so no sigmoid needed here.
    /// Returns normalized (0-1) position and confidence, or nil if no detection.
    private func extractPosition(from heatmap: [Float], width: Int, height: Int) -> (position: (x: Double, y: Double), confidence: Double)? {
        // Find max value (already in 0-1 range from model's sigmoid)
        var maxVal: Float = 0
        for val in heatmap {
            if val > maxVal { maxVal = val }
        }

        // No detection if max confidence < 0.5
        guard maxVal >= 0.5 else { return nil }

        // Weighted centroid of pixels above soft threshold (0.3)
        let threshold: Float = 0.3
        var sumX: Double = 0
        var sumY: Double = 0
        var sumW: Double = 0

        for y in 0..<height {
            for x in 0..<width {
                let val = heatmap[y * width + x]
                if val > threshold {
                    let w = Double(val)
                    sumX += Double(x) * w
                    sumY += Double(y) * w
                    sumW += w
                }
            }
        }

        guard sumW > 0 else { return nil }

        // Normalize to 0-1
        let normX = sumX / sumW / Double(width)
        let normY = sumY / sumW / Double(height)

        return (position: (x: normX, y: normY), confidence: Double(maxVal))
    }
}
