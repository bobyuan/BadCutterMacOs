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

        print("Feature extraction complete (shuttlecock blob detection at dynamic resolution):")
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
        print("Format: timestamp | motion | audio | shuttle | spread(regions) | persons | general | label | bucket")
        print(String(repeating: "-", count: 130))
        for (frame, bucket) in picks {
            let diagInfo = diag.first(where: { abs($0.timestamp - frame.timestamp) < 0.05 })
            let shuttle = diagInfo?.shuttlecockScore ?? -1
            let spread = diagInfo?.spreadScore ?? -1
            let regions = diagInfo?.activeRegions ?? -1
            let general = diagInfo?.generalMotionScore ?? -1
            let persons = diagInfo?.personCount ?? -1
            let label = labelAt(frame.timestamp)
            let ts = String(format: "%7.2f", frame.timestamp)
            let mot = String(format: "%.3f", frame.motionScore)
            let aud = String(format: "%.3f", frame.audioScore)
            let sht = String(format: "%.3f", shuttle)
            let spr = String(format: "%.3f", spread)
            let gen = String(format: "%.3f", general)
            print("t=\(ts)s | mot=\(mot) | aud=\(aud) | shuttle=\(sht) | spread=\(spr)(\(regions)) | persons=\(persons) | gen=\(gen) | \(label) | \(bucket)")
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
            let fname = "t\(String(format: "%07.2f", ts))_mot\(String(format: "%.3f", frame.motionScore))_\(label)_\(bucket).jpg"
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

        // Displaced white pixel distribution
        let counts = diag.map(\.displacedWhiteCount)
        let sortedCounts = counts.sorted()
        let avgCount = Double(counts.reduce(0, +)) / Double(counts.count)

        print("Displaced white pixel distribution (at dynamic resolution):")
        print("  Total frames: \(counts.count)")
        print("  Min: \(sortedCounts.first!), Max: \(sortedCounts.last!)")
        print("  Avg: \(String(format: "%.1f", avgCount))")
        print("  Median (p50): \(sortedCounts[sortedCounts.count / 2])")
        print("  p10: \(sortedCounts[sortedCounts.count / 10])")
        print("  p25: \(sortedCounts[sortedCounts.count / 4])")
        print("  p75: \(sortedCounts[sortedCounts.count * 3 / 4])")
        print("  p90: \(sortedCounts[sortedCounts.count * 9 / 10])")
        print("  p95: \(sortedCounts[sortedCounts.count * 19 / 20])")

        // Bucket distribution for displaced white pixels
        let under50 = counts.filter { $0 < 50 }.count
        let under200 = counts.filter { $0 >= 50 && $0 < 200 }.count
        let under500 = counts.filter { $0 >= 200 && $0 < 500 }.count
        let under1000 = counts.filter { $0 >= 500 && $0 < 1000 }.count
        let under2000 = counts.filter { $0 >= 1000 && $0 < 2000 }.count
        let over2000 = counts.filter { $0 >= 2000 }.count
        print("  Buckets: <50=\(under50) 50-200=\(under200) 200-500=\(under500) 500-1k=\(under1000) 1k-2k=\(under2000) >=2k=\(over2000)")

        // Max cluster sum distribution (spatial concentration)
        let clusters = diag.map(\.maxClusterSum)
        let sortedClusters = clusters.sorted()
        let avgCluster = Double(clusters.reduce(0, +)) / Double(clusters.count)
        print("\nMax cluster sum (5x5 neighborhood) distribution:")
        print("  Avg: \(String(format: "%.1f", avgCluster))")
        print("  Median: \(sortedClusters[sortedClusters.count / 2])")
        print("  p75: \(sortedClusters[sortedClusters.count * 3 / 4])")
        print("  p90: \(sortedClusters[sortedClusters.count * 9 / 10])")
        print("  p95: \(sortedClusters[sortedClusters.count * 19 / 20])")
        print("  Max: \(sortedClusters.last!)")

        // Shuttlecock score distribution
        let sScores = diag.map(\.shuttlecockScore)
        let sortedShuttle = sScores.sorted()
        let avgShuttle = sScores.reduce(0, +) / Double(sScores.count)
        print("\nShuttlecock score distribution:")
        print("  Avg: \(String(format: "%.4f", avgShuttle))")
        print("  Median: \(String(format: "%.4f", sortedShuttle[sortedShuttle.count / 2]))")
        print("  p75: \(String(format: "%.4f", sortedShuttle[sortedShuttle.count * 3 / 4]))")
        print("  p90: \(String(format: "%.4f", sortedShuttle[sortedShuttle.count * 9 / 10]))")

        // Motion spread (active regions) distribution
        let regionCounts = diag.map(\.activeRegions)
        let sortedRegions = regionCounts.sorted()
        let avgRegions = Double(regionCounts.reduce(0, +)) / Double(regionCounts.count)
        print("\nMotion spread (active regions out of 24):")
        print("  Avg: \(String(format: "%.1f", avgRegions))")
        print("  Median: \(sortedRegions[sortedRegions.count / 2])")
        print("  p25: \(sortedRegions[sortedRegions.count / 4])")
        print("  p75: \(sortedRegions[sortedRegions.count * 3 / 4])")
        print("  p90: \(sortedRegions[sortedRegions.count * 9 / 10])")
        print("  Max: \(sortedRegions.last!)")

        let sprScores = diag.map(\.spreadScore)
        let sortedSpread = sprScores.sorted()
        let avgSpread = sprScores.reduce(0, +) / Double(sprScores.count)
        print("\nSpread score distribution:")
        print("  Avg: \(String(format: "%.4f", avgSpread))")
        print("  Median: \(String(format: "%.4f", sortedSpread[sortedSpread.count / 2]))")
        print("  p75: \(String(format: "%.4f", sortedSpread[sortedSpread.count * 3 / 4]))")
        print("  p90: \(String(format: "%.4f", sortedSpread[sortedSpread.count * 9 / 10]))")

        // General motion score distribution
        let gScores = diag.map(\.generalMotionScore)
        let avgGeneral = gScores.reduce(0, +) / Double(gScores.count)
        let maxGeneral = gScores.max() ?? 0
        print("\nGeneral motion score: avg=\(String(format: "%.4f", avgGeneral)) max=\(String(format: "%.4f", maxGeneral))")

        // Person detection distribution
        let personCounts = diag.map(\.personCount)
        let sortedPersons = personCounts.sorted()
        let avgPersons = Double(personCounts.reduce(0, +)) / Double(personCounts.count)
        let p0 = personCounts.filter { $0 == 0 }.count
        let p1 = personCounts.filter { $0 == 1 }.count
        let p2 = personCounts.filter { $0 == 2 }.count
        let p3 = personCounts.filter { $0 == 3 }.count
        let p4plus = personCounts.filter { $0 >= 4 }.count
        print("\nVision person detection:")
        print("  Avg: \(String(format: "%.1f", avgPersons))")
        print("  Median: \(sortedPersons[sortedPersons.count / 2])")
        print("  Distribution: 0=\(p0) 1=\(p1) 2=\(p2) 3=\(p3) 4+=\(p4plus)")

        // Sample frames
        print("\nSample frames (every ~60s):")
        let step = max(1, diag.count / 16)
        for i in stride(from: 0, to: diag.count, by: step) {
            let d = diag[i]
            print("  t=\(String(format: "%6.1f", d.timestamp))s  regions=\(String(format: "%2d", d.activeRegions))  spread=\(String(format: "%.3f", d.spreadScore))  shuttle=\(String(format: "%.3f", d.shuttlecockScore))  persons=\(d.personCount)  general=\(String(format: "%.3f", d.generalMotionScore))  blended=\(String(format: "%.3f", d.blendedScore))")
        }
    }
}
