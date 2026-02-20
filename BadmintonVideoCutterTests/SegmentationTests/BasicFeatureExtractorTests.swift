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

        // Print summary
        let avgMotion = frames.map(\.motionScore).reduce(0, +) / Double(frames.count)
        let maxMotion = frames.map(\.motionScore).max() ?? 0
        let avgAudio = frames.map(\.audioScore).reduce(0, +) / Double(frames.count)
        print("Feature extraction complete:")
        print("  Total frames: \(frames.count)")
        print("  Non-zero motion: \(nonZeroMotion.count) (\(String(format: "%.0f", Double(nonZeroMotion.count) / Double(frames.count) * 100))%)")
        print("  Avg motion: \(String(format: "%.4f", avgMotion))")
        print("  Max motion: \(String(format: "%.4f", maxMotion))")
        print("  Avg audio: \(String(format: "%.4f", avgAudio))")
    }
}
