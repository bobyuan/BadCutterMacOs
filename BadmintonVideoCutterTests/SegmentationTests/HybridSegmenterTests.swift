import XCTest
@testable import BadmintonVideoCutter
import CoreML

final class HybridSegmenterTests: XCTestCase {

    let testVideoURL = URL(fileURLWithPath: "/Users/boyuan/Downloads/IMG_8510.MOV")
    static let cacheDir = URL(fileURLWithPath: "/Users/boyuan/Documents/badminton_video_cutter/TestData")
    static let cachedFramesURL = cacheDir.appendingPathComponent("IMG_8510_frames.json")

    func testClassifierReturnsAtLeastOneSegment() {
        let frames = [
            FeatureFrame(timestamp: 0, motionScore: 0.7, audioScore: 0.5),
            FeatureFrame(timestamp: 1, motionScore: 0.8, audioScore: 0.6)
        ]
        let sut = HybridSegmenter()
        let out = sut.classify(frames: frames, config: AnalysisConfig())
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.label, .rally)
    }

    /// Full pipeline test: extract features with ML model → classify → post-process → dump debug info.
    /// Caches extracted frames to TestData/ so subsequent runs skip the ~17min ML extraction.
    func testFullPipelineWithMLModel() async throws {
        let outputPath = "/tmp/hybrid_segmenter_debug.txt"
        var output = ""
        func log(_ s: String) { output += s + "\n"; print(s) }

        let frames = try await loadOrExtractFrames(log: log)
        XCTAssertFalse(frames.isEmpty, "Should produce feature frames")
        log("Using \(frames.count) frames")

        // --- Raw score distributions ---
        let shuttleScores = frames.map(\.shuttlecockFlightScore)
        let motionScores = frames.map(\.motionScore)
        let audioScores = frames.map(\.audioScore)

        let sortedShuttle = shuttleScores.sorted()
        let gt0 = shuttleScores.filter { $0 > 0 }.count
        let gt03 = shuttleScores.filter { $0 > 0.3 }.count
        let gt05 = shuttleScores.filter { $0 > 0.5 }.count
        let gt07 = shuttleScores.filter { $0 > 0.7 }.count
        let gt09 = shuttleScores.filter { $0 > 0.9 }.count

        log("\n--- SHUTTLECOCK FLIGHT SCORE DISTRIBUTION ---")
        log("  >0.0: \(gt0)/\(frames.count) (\(pct(gt0, frames.count))%)")
        log("  >0.3: \(gt03)/\(frames.count) (\(pct(gt03, frames.count))%)")
        log("  >0.5: \(gt05)/\(frames.count) (\(pct(gt05, frames.count))%)")
        log("  >0.7: \(gt07)/\(frames.count) (\(pct(gt07, frames.count))%)")
        log("  >0.9: \(gt09)/\(frames.count) (\(pct(gt09, frames.count))%)")
        log("  avg=\(fmt(shuttleScores.avg)) median=\(fmt(sortedShuttle.median))")
        log("  p10=\(fmt(sortedShuttle.p(0.10))) p25=\(fmt(sortedShuttle.p(0.25))) p75=\(fmt(sortedShuttle.p(0.75))) p90=\(fmt(sortedShuttle.p(0.90)))")

        log("\n--- MOTION SCORE DISTRIBUTION ---")
        let sortedMotion = motionScores.sorted()
        log("  avg=\(fmt(motionScores.avg)) median=\(fmt(sortedMotion.median))")
        log("  p10=\(fmt(sortedMotion.p(0.10))) p25=\(fmt(sortedMotion.p(0.25))) p75=\(fmt(sortedMotion.p(0.75))) p90=\(fmt(sortedMotion.p(0.90)))")

        log("\n--- AUDIO SCORE DISTRIBUTION ---")
        let sortedAudio = audioScores.sorted()
        log("  avg=\(fmt(audioScores.avg)) median=\(fmt(sortedAudio.median))")
        log("  p10=\(fmt(sortedAudio.p(0.10))) p25=\(fmt(sortedAudio.p(0.25))) p75=\(fmt(sortedAudio.p(0.75))) p90=\(fmt(sortedAudio.p(0.90)))")

        // --- Displacement analysis ---
        log("\n--- SHUTTLE DISPLACEMENT ANALYSIS ---")
        var displacements: [Double] = []
        var consecutivePairs = 0
        for i in 1..<frames.count {
            guard let pos = frames[i].shuttlecockPosition,
                  let prevPos = frames[i-1].shuttlecockPosition else { continue }
            consecutivePairs += 1
            let dx = pos.x - prevPos.x
            let dy = pos.y - prevPos.y
            displacements.append(sqrt(dx * dx + dy * dy))
        }
        let sortedDisp = displacements.sorted()
        let inFlightCount = displacements.filter { $0 > 0.02 }.count
        log("  Consecutive position pairs: \(consecutivePairs)/\(frames.count) (\(pct(consecutivePairs, frames.count))%)")
        log("  Displacement >0.02 (in flight): \(inFlightCount)/\(consecutivePairs) (\(pct(inFlightCount, max(1,consecutivePairs)))%)")
        if !sortedDisp.isEmpty {
            log("  avg=\(fmt(sortedDisp.avg)) median=\(fmt(sortedDisp.median))")
            log("  p10=\(fmt(sortedDisp.p(0.10))) p25=\(fmt(sortedDisp.p(0.25))) p75=\(fmt(sortedDisp.p(0.75))) p90=\(fmt(sortedDisp.p(0.90))) max=\(fmt(sortedDisp.last!))")
        }

        // Sample displacement around known break period (2:30-2:32)
        log("\n  Displacement samples around break (2:29-2:33):")
        for i in 1..<frames.count {
            let t = frames[i].timestamp
            guard t >= 149 && t <= 153 else { continue }
            if let pos = frames[i].shuttlecockPosition, let prev = frames[i-1].shuttlecockPosition {
                let dx = pos.x - prev.x; let dy = pos.y - prev.y
                let d = sqrt(dx*dx + dy*dy)
                log("    t=\(ts(t)) pos=(\(fmt(pos.x)),\(fmt(pos.y))) disp=\(fmt(d)) \(d > 0.02 ? "FLIGHT" : "still")")
            } else {
                let hasPos = frames[i].shuttlecockPosition != nil ? "pos" : "no-pos"
                let hasPrev = frames[i-1].shuttlecockPosition != nil ? "pos" : "no-pos"
                log("    t=\(ts(t)) [\(hasPrev)→\(hasPos)] skip")
            }
        }

        // Sample displacement during known rally period (0:05-0:15)
        log("\n  Displacement samples during rally (0:05-0:15):")
        for i in 1..<frames.count {
            let t = frames[i].timestamp
            guard t >= 5 && t <= 15 else { continue }
            if let pos = frames[i].shuttlecockPosition, let prev = frames[i-1].shuttlecockPosition {
                let dx = pos.x - prev.x; let dy = pos.y - prev.y
                let d = sqrt(dx*dx + dy*dy)
                log("    t=\(ts(t)) pos=(\(fmt(pos.x)),\(fmt(pos.y))) disp=\(fmt(d)) \(d > 0.02 ? "FLIGHT" : "still")")
            } else {
                let hasPos = frames[i].shuttlecockPosition != nil ? "pos" : "no-pos"
                let hasPrev = frames[i-1].shuttlecockPosition != nil ? "pos" : "no-pos"
                log("    t=\(ts(t)) [\(hasPrev)→\(hasPos)] skip")
            }
        }

        // --- Classification ---
        let segmenter = HybridSegmenter()
        let config = AnalysisConfig()
        let rawSegments = segmenter.classify(frames: frames, config: config)
        let processed = segmenter.postProcess(segments: rawSegments, frames: frames, config: config)
        let taRefined = TrajectoryAnalyzer.refineSegments(segments: processed, frames: frames, config: config)
        let refined = SegmentUtils.mergeAdjacent(SegmentUtils.removeInvalid(taRefined), maxGap: 0.5)

        // --- Segment results ---
        let rallies = refined.filter { $0.label == .rally }
        let breaks = refined.filter { $0.label == .betweenPoints }

        log("\n--- SEGMENTATION RESULTS ---")
        log("Raw segments: \(rawSegments.count)")

        // Show raw break segments
        let rawBreaks = rawSegments.filter { $0.label == .betweenPoints }
        log("  Raw breaks >= 2s:")
        for seg in rawBreaks.filter({ $0.duration >= 2.0 }) {
            log("    BREAK \(ts(seg.start)) - \(ts(seg.end)) (\(String(format: "%.1f", seg.duration))s)")
        }

        log("Post-processed: \(processed.count)")
        log("After TrajectoryAnalyzer: \(refined.count)")
        log("Rallies: \(rallies.count), Breaks: \(breaks.count)")

        log("\nAll final segments:")
        for (i, seg) in refined.enumerated() {
            let label = seg.label == .rally ? "RALLY " : "BREAK "
            log("  #\(String(format: "%2d", i+1)) \(label) \(ts(seg.start)) - \(ts(seg.end))  (\(String(format: "%5.1f", seg.duration))s)  conf=\(fmt(seg.confidence))")
        }

        // Write log to file
        try output.write(toFile: outputPath, atomically: true, encoding: .utf8)
        print("\n>>> Debug output written to: \(outputPath)")

        // Basic sanity
        XCTAssertGreaterThan(rallies.count, 0, "Should detect at least some rallies")
        for rally in rallies {
            XCTAssertLessThan(rally.duration, 300, "Rally at \(ts(rally.start)) is \(String(format: "%.0f", rally.duration))s — likely a merge bug")
        }
    }

    // MARK: - Frame Cache

    /// Loads cached frames from TestData/ or extracts fresh ones (and caches them).
    private func loadOrExtractFrames(log: (String) -> Void) async throws -> [FeatureFrame] {
        let cacheURL = Self.cachedFramesURL

        // Try loading from cache
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            log("Loading cached frames from \(cacheURL.lastPathComponent)...")
            let data = try Data(contentsOf: cacheURL)
            let cached = try JSONDecoder().decode([CodableFrame].self, from: data)
            let frames = cached.map { $0.toFeatureFrame() }
            log("Loaded \(frames.count) cached frames")
            return frames
        }

        // Extract fresh
        log("No cached frames found. Extracting from video (this takes ~17 min)...")
        guard FileManager.default.fileExists(atPath: testVideoURL.path) else {
            XCTFail("Test video not found at \(testVideoURL.path)")
            return []
        }
        guard let modelURL = findCompiledModel() else {
            XCTFail("TrackNetV3 model not found")
            return []
        }

        log("Video: \(testVideoURL.lastPathComponent)")
        log("Model: \(modelURL.lastPathComponent)")

        let extractor = BasicFeatureExtractor()
        let frames = try await extractor.extractFeatures(
            from: testVideoURL,
            mlModelURL: nil,
            progress: nil,
            calibrationPriors: [],
            shuttlecockModelURL: modelURL
        )

        // Cache to disk
        try FileManager.default.createDirectory(at: Self.cacheDir, withIntermediateDirectories: true)
        let codable = frames.map { CodableFrame(from: $0) }
        let data = try JSONEncoder().encode(codable)
        try data.write(to: cacheURL)
        log("Cached \(frames.count) frames to \(cacheURL.lastPathComponent) (\(data.count / 1024)KB)")

        return frames
    }

    // MARK: - Helpers

    private func fmt(_ v: Double) -> String { String(format: "%.3f", v) }
    private func pct(_ n: Int, _ total: Int) -> String { String(format: "%.1f", Double(n) / Double(total) * 100) }
    private func ts(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = t - Double(m * 60)
        return String(format: "%d:%05.2f", m, s)
    }

    /// Find the compiled TrackNetV3 model in DerivedData or the project
    private func findCompiledModel() -> URL? {
        if let url = Bundle(for: type(of: self)).url(forResource: "TrackNetV3", withExtension: "mlmodelc") {
            return url
        }
        if let url = Bundle.main.url(forResource: "TrackNetV3", withExtension: "mlmodelc") {
            return url
        }
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
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelDir = appSupport.appendingPathComponent("BadmintonVideoCutter")
        let compiled = modelDir.appendingPathComponent("TrackNetV3.mlmodelc")
        if FileManager.default.fileExists(atPath: compiled.path) { return compiled }
        let package = modelDir.appendingPathComponent("TrackNetV3.mlpackage")
        if FileManager.default.fileExists(atPath: package.path) { return package }
        let projectResource = URL(fileURLWithPath: "/Users/boyuan/Documents/badminton_video_cutter/BadmintonVideoCutter/Resources/TrackNetV3.mlpackage")
        if FileManager.default.fileExists(atPath: projectResource.path) { return projectResource }
        return nil
    }
}

// MARK: - Codable bridge for FeatureFrame (tuple isn't Codable)

private struct CodableFrame: Codable {
    let timestamp: TimeInterval
    let motionScore: Double
    let audioScore: Double
    let shuttlecockFlightScore: Double
    let posX: Double?
    let posY: Double?

    init(from frame: FeatureFrame) {
        self.timestamp = frame.timestamp
        self.motionScore = frame.motionScore
        self.audioScore = frame.audioScore
        self.shuttlecockFlightScore = frame.shuttlecockFlightScore
        self.posX = frame.shuttlecockPosition?.x
        self.posY = frame.shuttlecockPosition?.y
    }

    func toFeatureFrame() -> FeatureFrame {
        var f = FeatureFrame(timestamp: timestamp, motionScore: motionScore, audioScore: audioScore)
        f.shuttlecockFlightScore = shuttlecockFlightScore
        if let x = posX, let y = posY {
            f.shuttlecockPosition = (x: x, y: y)
        }
        return f
    }
}

// MARK: - Array stats helpers

private extension Array where Element == Double {
    var avg: Double {
        guard !isEmpty else { return 0 }
        return reduce(0, +) / Double(count)
    }
    var median: Double { p(0.5) }
    func p(_ percentile: Double) -> Double {
        guard !isEmpty else { return 0 }
        let sorted = self.sorted()
        let clamped = Swift.max(0, Swift.min(1, percentile))
        let idx = Int(Double(sorted.count - 1) * clamped)
        return sorted[idx]
    }
}
