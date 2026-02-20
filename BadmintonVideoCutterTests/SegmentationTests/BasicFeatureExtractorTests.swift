import XCTest
@testable import BadmintonVideoCutter

final class BasicFeatureExtractorTests: XCTestCase {

    let testVideoURL = URL(fileURLWithPath: "/Users/boyuan/Downloads/IMG_8510.MOV")

    func testMotionExtractionDoesNotCrash() async throws {
        guard FileManager.default.fileExists(atPath: testVideoURL.path) else {
            XCTFail("Test video not found at \(testVideoURL.path)")
            return
        }

        let extractor = BasicFeatureExtractor()
        let frames = try await extractor.extractFeatures(from: testVideoURL)

        // Should produce frames
        XCTAssertFalse(frames.isEmpty, "Should produce at least some feature frames")

        // Should have non-zero motion scores
        let nonZeroMotion = frames.filter { $0.motionScore > 0 }
        XCTAssertFalse(nonZeroMotion.isEmpty, "Should have some frames with non-zero motion scores")

        // Motion scores in valid range [0, 1]
        for frame in frames {
            XCTAssertGreaterThanOrEqual(frame.motionScore, 0, "Motion score should be >= 0")
            XCTAssertLessThanOrEqual(frame.motionScore, 1, "Motion score should be <= 1")
        }

        // Score distribution: should have variation (not all the same value)
        let scores = frames.map(\.motionScore)
        let avgMotion = scores.reduce(0, +) / Double(scores.count)
        let maxMotion = scores.max() ?? 0
        let minMotion = scores.min() ?? 0
        XCTAssertGreaterThan(maxMotion - minMotion, 0.05, "Motion scores should show variation between rally and non-rally periods")

        // Distribution buckets for diagnostics
        let lowMotion = scores.filter { $0 < 0.2 }.count
        let midMotion = scores.filter { $0 >= 0.2 && $0 < 0.5 }.count
        let highMotion = scores.filter { $0 >= 0.5 }.count
        let avgAudio = frames.map(\.audioScore).reduce(0, +) / Double(frames.count)

        print("Feature extraction complete (shuttlecock-aware motion):")
        print("  Total frames: \(frames.count)")
        print("  Non-zero motion: \(nonZeroMotion.count) (\(String(format: "%.0f", Double(nonZeroMotion.count) / Double(frames.count) * 100))%)")
        print("  Avg motion: \(String(format: "%.4f", avgMotion))")
        print("  Max motion: \(String(format: "%.4f", maxMotion))")
        print("  Min motion: \(String(format: "%.4f", minMotion))")
        print("  Score distribution: low(<0.2)=\(lowMotion) mid(0.2-0.5)=\(midMotion) high(>=0.5)=\(highMotion)")
        print("  Avg audio: \(String(format: "%.4f", avgAudio))")
    }

    /// Outputs a curated list of timestamps for visual verification.
    /// Picks frames across the score spectrum: lowest, low, medium, high, highest.
    /// Also runs segmentation to show which timestamps are rally vs betweenPoints.
    func testVisualVerificationTimestamps() async throws {
        guard FileManager.default.fileExists(atPath: testVideoURL.path) else {
            XCTFail("Test video not found at \(testVideoURL.path)")
            return
        }

        let extractor = BasicFeatureExtractor()
        extractor.collectDiagnostics = true
        let frames = try await extractor.extractFeatures(from: testVideoURL)
        let diag = extractor.diagnostics

        // Run segmentation to get rally/betweenPoints labels
        let segmenter = HybridSegmenter()
        let config = AnalysisConfig()
        let rawSegments = segmenter.classify(frames: frames, config: config)
        let segments = segmenter.postProcess(segments: rawSegments, frames: frames, config: config)

        // Helper: find segment label at a given timestamp
        func labelAt(_ t: TimeInterval) -> String {
            if let seg = segments.first(where: { t >= $0.start && t <= $0.end }) {
                return seg.label == .rally ? "RALLY" : "BETWEEN"
            }
            return "?"
        }

        // Sort frames by motion score
        let sorted = frames.sorted { $0.motionScore < $1.motionScore }

        // Pick frames: 5 lowest, 5 around p25, 5 around median, 5 around p75, 5 highest
        var picks: [(FeatureFrame, String)] = [] // (frame, reason)

        // 5 lowest
        for i in 0..<5 { picks.append((sorted[i], "LOWEST")) }
        // 5 around p25
        let p25 = sorted.count / 4
        for i in (p25-2)...(p25+2) { picks.append((sorted[i], "P25")) }
        // 5 around median
        let med = sorted.count / 2
        for i in (med-2)...(med+2) { picks.append((sorted[i], "MEDIAN")) }
        // 5 around p75
        let p75 = sorted.count * 3 / 4
        for i in (p75-2)...(p75+2) { picks.append((sorted[i], "P75")) }
        // 5 highest
        for i in (sorted.count-5)..<sorted.count { picks.append((sorted[i], "HIGHEST")) }

        // Sort picks by timestamp for easier viewing
        picks.sort { $0.0.timestamp < $1.0.timestamp }

        // Get diagnostic info for each pick
        print("\n=== VISUAL VERIFICATION FRAME LIST ===")
        print("Format: timestamp | motion | audio | white_px | general | label | bucket")
        print(String(repeating: "-", count: 85))
        for (frame, bucket) in picks {
            let diagInfo = diag.first(where: { abs($0.timestamp - frame.timestamp) < 0.05 })
            let whitePx = diagInfo?.displacedWhiteCount ?? -1
            let general = diagInfo?.generalMotionScore ?? -1
            let label = labelAt(frame.timestamp)
            let ts = String(format: "%7.2f", frame.timestamp)
            let mot = String(format: "%.3f", frame.motionScore)
            let aud = String(format: "%.3f", frame.audioScore)
            let gen = String(format: "%.3f", general)
            print("t=\(ts)s | mot=\(mot) | aud=\(aud) | white=\(whitePx) | gen=\(gen) | \(label) | \(bucket)")
        }

        // Also print segment summary
        let rallies = segments.filter { $0.label == .rally }
        let betweens = segments.filter { $0.label == .betweenPoints }
        print("\n=== SEGMENT SUMMARY ===")
        print("Rallies: \(rallies.count), Between-points: \(betweens.count)")
        print("\nRally segments:")
        for (i, seg) in rallies.enumerated() {
            let s = String(format: "%7.2f", seg.start)
            let e = String(format: "%7.2f", seg.end)
            let d = String(format: "%.1f", seg.duration)
            let c = String(format: "%.2f", seg.confidence)
            print("  Rally \(i+1): \(s) - \(e)  (\(d)s)  conf=\(c)")
        }

        // Print ffmpeg commands for easy frame extraction
        print("\n=== FFMPEG EXTRACTION COMMANDS ===")
        let dir = "/Users/boyuan/Documents/badminton_video_cutter/sample_frames"
        let video = "/Users/boyuan/Downloads/IMG_8510.MOV"
        for (frame, bucket) in picks {
            let ts = frame.timestamp
            let label = labelAt(ts)
            let fname = String(format: "t%07.2f_mot%.3f_%s_%s.jpg",
                               ts, frame.motionScore, label, bucket)
                .replacingOccurrences(of: " ", with: "")
            print("ffmpeg -ss \(String(format: "%.2f", ts)) -i \"\(video)\" -frames:v 1 -q:v 2 \"\(dir)/\(fname)\" -y 2>/dev/null")
        }
    }

    func testDisplacedWhitePixelDistribution() async throws {
        guard FileManager.default.fileExists(atPath: testVideoURL.path) else {
            XCTFail("Test video not found at \(testVideoURL.path)")
            return
        }

        let extractor = BasicFeatureExtractor()
        extractor.collectDiagnostics = true
        _ = try await extractor.extractFeatures(from: testVideoURL)

        let diag = extractor.diagnostics
        guard !diag.isEmpty else {
            XCTFail("No diagnostics collected")
            return
        }

        let counts = diag.map(\.displacedWhiteCount)
        let sorted = counts.sorted()
        let avgCount = Double(counts.reduce(0, +)) / Double(counts.count)

        print("Displaced white pixel distribution:")
        print("  Total frames: \(counts.count)")
        print("  Min: \(sorted.first!), Max: \(sorted.last!)")
        print("  Avg: \(String(format: "%.1f", avgCount))")
        print("  Median (p50): \(sorted[sorted.count / 2])")
        print("  p10: \(sorted[sorted.count / 10])")
        print("  p25: \(sorted[sorted.count / 4])")
        print("  p75: \(sorted[sorted.count * 3 / 4])")
        print("  p90: \(sorted[sorted.count * 9 / 10])")
        print("  p95: \(sorted[sorted.count * 19 / 20])")

        // Bucket distribution
        let under10 = counts.filter { $0 < 10 }.count
        let under50 = counts.filter { $0 >= 10 && $0 < 50 }.count
        let under100 = counts.filter { $0 >= 50 && $0 < 100 }.count
        let under200 = counts.filter { $0 >= 100 && $0 < 200 }.count
        let under500 = counts.filter { $0 >= 200 && $0 < 500 }.count
        let over500 = counts.filter { $0 >= 500 }.count
        print("  Buckets: <10=\(under10) 10-50=\(under50) 50-100=\(under100) 100-200=\(under200) 200-500=\(under500) >=500=\(over500)")

        // General motion score distribution
        let gScores = diag.map(\.generalMotionScore)
        let avgGeneral = gScores.reduce(0, +) / Double(gScores.count)
        let maxGeneral = gScores.max() ?? 0
        print("\nGeneral motion score: avg=\(String(format: "%.4f", avgGeneral)) max=\(String(format: "%.4f", maxGeneral))")

        // Sample some frames at different timestamps
        print("\nSample frames (every ~60s):")
        let step = max(1, diag.count / 16)
        for i in stride(from: 0, to: diag.count, by: step) {
            let d = diag[i]
            print("  t=\(String(format: "%6.1f", d.timestamp))s  white=\(String(format: "%4d", d.displacedWhiteCount))  general=\(String(format: "%.3f", d.generalMotionScore))  blended=\(String(format: "%.3f", d.blendedScore))")
        }
    }
}
