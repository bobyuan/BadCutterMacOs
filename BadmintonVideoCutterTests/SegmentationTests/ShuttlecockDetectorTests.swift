import XCTest
@testable import BadmintonVideoCutter
import CoreML
import AVFoundation

final class ShuttlecockDetectorTests: XCTestCase {

    let testVideoURL = URL(fileURLWithPath: "/Users/boyuan/Downloads/IMG_8510.MOV")

    /// Test that the CoreML model loads correctly from the bundle
    func testModelLoads() throws {
        guard let modelURL = Bundle.main.url(forResource: "TrackNetV3", withExtension: "mlmodelc") else {
            // Fallback: try the app bundle (tests use different bundle)
            let compiled = findCompiledModel()
            guard let url = compiled else {
                XCTFail("TrackNetV3.mlmodelc not found in any bundle")
                return
            }
            let detector = try ShuttlecockDetector(modelURL: url)
            XCTAssertNotNil(detector)
            return
        }
        let detector = try ShuttlecockDetector(modelURL: modelURL)
        XCTAssertNotNil(detector)
    }

    /// Test CoreML model input/output shapes by running a dummy prediction
    func testModelInputOutput() throws {
        guard let modelURL = findCompiledModel() else {
            XCTFail("TrackNetV3 model not found")
            return
        }

        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly  // Safer for testing
        let model = try MLModel(contentsOf: modelURL, configuration: config)

        // Print model description for debugging
        print("Model inputs:")
        for (name, desc) in model.modelDescription.inputDescriptionsByName {
            print("  \(name): \(desc.type) constraint=\(desc.multiArrayConstraint?.shape ?? [])")
        }
        print("Model outputs:")
        for (name, desc) in model.modelDescription.outputDescriptionsByName {
            print("  \(name): \(desc.type) constraint=\(desc.multiArrayConstraint?.shape ?? [])")
        }

        // Create input: (1, 9, 288, 512)
        let inputArray = try MLMultiArray(shape: [1, 9, 288, 512], dataType: .float32)
        // Fill with zeros (safe dummy input)
        let count = 1 * 9 * 288 * 512
        for i in 0..<count {
            inputArray[i] = 0.5
        }

        let inputName = model.modelDescription.inputDescriptionsByName.keys.first!
        print("Using input name: '\(inputName)'")

        let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: inputArray)])
        let prediction = try model.prediction(from: provider)

        let outputName = model.modelDescription.outputDescriptionsByName.keys.first!
        print("Using output name: '\(outputName)'")

        guard let outputArray = prediction.featureValue(for: outputName)?.multiArrayValue else {
            XCTFail("No output array")
            return
        }

        print("Output shape: \(outputArray.shape)")
        print("Output dataType: \(outputArray.dataType.rawValue)")
        print("Output strides: \(outputArray.strides)")

        // Verify shape
        XCTAssertEqual(outputArray.shape.count, 4, "Expected 4D output")
        // Check values are in sigmoid range
        let outCount = outputArray.shape.reduce(1) { $0 * $1.intValue }
        var minVal: Float = Float.greatestFiniteMagnitude
        var maxVal: Float = -Float.greatestFiniteMagnitude
        for i in 0..<outCount {
            let val = outputArray[i].floatValue
            minVal = min(minVal, val)
            maxVal = max(maxVal, val)
        }
        print("Output value range: [\(minVal), \(maxVal)]")
    }

    /// Test processing a few real frames through the detector
    func testProcessRealFrames() throws {
        guard FileManager.default.fileExists(atPath: testVideoURL.path) else {
            XCTFail("Test video not found")
            return
        }
        guard let modelURL = findCompiledModel() else {
            XCTFail("TrackNetV3 model not found")
            return
        }

        let detector = try ShuttlecockDetector(modelURL: modelURL)

        // Extract a few frames from the video
        let asset = AVURLAsset(url: testVideoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 540)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)

        // Get 6 frames (2 batches of 3) starting at 30 seconds
        var allDetections: [ShuttlecockDetector.Detection] = []
        for i in 0..<6 {
            let t = 30.0 + Double(i) * 0.2
            let cmTime = CMTime(seconds: t, preferredTimescale: 600)
            guard let cgImage = try? generator.copyCGImage(at: cmTime, actualTime: nil) else {
                print("Failed to get frame at t=\(t)")
                continue
            }

            // Render to RGBA
            let w = cgImage.width
            let h = cgImage.height
            var rgba = [UInt8](repeating: 0, count: w * h * 4)
            guard let ctx = CGContext(
                data: &rgba, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                XCTFail("Failed to create CGContext")
                continue
            }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

            print("Processing frame \(i) at t=\(String(format: "%.1f", t))s (\(w)x\(h))")

            if let detections = detector.processFrame(rgba: rgba, width: w, height: h, timestamp: t) {
                print("  Got \(detections.count) detections")
                for det in detections {
                    let posStr = det.position.map { String(format: "(%.3f, %.3f)", $0.x, $0.y) } ?? "nil"
                    print("    t=\(String(format: "%.1f", det.timestamp))s pos=\(posStr) conf=\(String(format: "%.3f", det.confidence))")
                }
                allDetections.append(contentsOf: detections)
            }
        }

        // Flush remaining
        if let remaining = detector.flush() {
            allDetections.append(contentsOf: remaining)
        }

        print("\nTotal detections: \(allDetections.count)")
        let withPosition = allDetections.filter { $0.position != nil }
        print("With position: \(withPosition.count)")
    }

    /// Full integration test: run extractFeatures with ML model on real video (first 30s)
    func testExtractFeaturesWithMLDetector() async throws {
        guard FileManager.default.fileExists(atPath: testVideoURL.path) else {
            XCTFail("Test video not found")
            return
        }
        guard let modelURL = findCompiledModel() else {
            XCTFail("TrackNetV3 model not found")
            return
        }

        let extractor = BasicFeatureExtractor()
        let frames = try await extractor.extractFeatures(
            from: testVideoURL,
            mlModelURL: nil,
            progress: nil,
            calibrationPriors: [],
            shuttlecockModelURL: modelURL
        )

        XCTAssertFalse(frames.isEmpty, "Should produce feature frames")

        let mlDetected = frames.filter { $0.shuttlecockPosition != nil }
        let mlConfident = frames.filter { $0.shuttlecockFlightScore > 0.5 }

        print("Feature extraction with ML detector:")
        print("  Total frames: \(frames.count)")
        print("  ML detections (position != nil): \(mlDetected.count)")
        print("  High confidence (>0.5): \(mlConfident.count)")

        // Validate ranges
        for frame in frames {
            XCTAssertGreaterThanOrEqual(frame.motionScore, 0)
            XCTAssertLessThanOrEqual(frame.motionScore, 1)
            XCTAssertGreaterThanOrEqual(frame.shuttlecockFlightScore, 0)
            XCTAssertLessThanOrEqual(frame.shuttlecockFlightScore, 1)
            if let pos = frame.shuttlecockPosition {
                XCTAssertGreaterThanOrEqual(pos.x, 0)
                XCTAssertLessThanOrEqual(pos.x, 1)
                XCTAssertGreaterThanOrEqual(pos.y, 0)
                XCTAssertLessThanOrEqual(pos.y, 1)
            }
        }
    }

    // MARK: - Helpers

    /// Find the compiled TrackNetV3 model in DerivedData or the project
    private func findCompiledModel() -> URL? {
        // Check test bundle
        if let url = Bundle(for: type(of: self)).url(forResource: "TrackNetV3", withExtension: "mlmodelc") {
            return url
        }
        // Check main bundle
        if let url = Bundle.main.url(forResource: "TrackNetV3", withExtension: "mlmodelc") {
            return url
        }
        // Check DerivedData build products
        let derivedData = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData")
        if let enumerator = FileManager.default.enumerator(at: derivedData, includingPropertiesForKeys: nil) {
            while let url = enumerator.nextObject() as? URL {
                if url.lastPathComponent == "TrackNetV3.mlmodelc" {
                    print("Found model at: \(url.path)")
                    return url
                }
            }
        }
        // Check Application Support
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelDir = appSupport.appendingPathComponent("BadmintonVideoCutter")
        let compiled = modelDir.appendingPathComponent("TrackNetV3.mlmodelc")
        if FileManager.default.fileExists(atPath: compiled.path) { return compiled }
        let package = modelDir.appendingPathComponent("TrackNetV3.mlpackage")
        if FileManager.default.fileExists(atPath: package.path) { return package }
        // Check project resources directly
        let projectResource = URL(fileURLWithPath: "/Users/boyuan/Documents/badminton_video_cutter/BadmintonVideoCutter/Resources/TrackNetV3.mlpackage")
        if FileManager.default.fileExists(atPath: projectResource.path) { return projectResource }
        return nil
    }
}
