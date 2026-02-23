import XCTest
@testable import BadmintonVideoCutter

final class TrajectoryAnalyzerTests: XCTestCase {

    // MARK: - Helpers

    /// Create a FeatureFrame with shuttle data.
    private func frame(
        at t: TimeInterval,
        motion: Double = 0.5,
        flightScore: Double = 0.0,
        position: (x: Double, y: Double)? = nil
    ) -> FeatureFrame {
        FeatureFrame(
            timestamp: t,
            motionScore: motion,
            audioScore: 0,
            shuttlecockFlightScore: flightScore,
            shuttlecockPosition: position
        )
    }

    private func rallySegment(start: TimeInterval, end: TimeInterval) -> TimeSegment {
        TimeSegment(start: start, end: end, label: .rally, confidence: 0.8)
    }

    private func betweenSegment(start: TimeInterval, end: TimeInterval) -> TimeSegment {
        TimeSegment(start: start, end: end, label: .betweenPoints, confidence: 0.3)
    }

    // MARK: - Test 1: No ML Detections

    func testNoMLDetections() {
        // All frames have 0 flight score → detection rate < 10% → unchanged
        let frames = (0..<100).map { i in
            frame(at: Double(i) * 0.2, motion: 0.6, flightScore: 0)
        }
        let segments = [rallySegment(start: 0, end: 20)]
        let config = AnalysisConfig()

        let result = TrajectoryAnalyzer.refineSegments(segments: segments, frames: frames, config: config)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].label, .rally)
        XCTAssertEqual(result[0].start, 0)
        XCTAssertEqual(result[0].end, 20)
    }

    // MARK: - Test 2: No Gaps Found

    func testNoGapsFound() {
        // Continuous high flight scores → no gaps → no splitting
        let frames = (0..<100).map { i in
            frame(at: Double(i) * 0.2, motion: 0.6, flightScore: 0.8)
        }
        let segments = [rallySegment(start: 0, end: 20)]
        let config = AnalysisConfig()

        let result = TrajectoryAnalyzer.refineSegments(segments: segments, frames: frames, config: config)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].label, .rally)
    }

    // MARK: - Test 3: Single Gap Splits Rally

    func testSingleGapSplitsRally() {
        // Rally from 0-30s. Shuttle visible 0-10s, invisible 10-13s (3s gap), visible 13-30s.
        // Gap has: low motion (+1), position discontinuity (+1) = score 2 → accepted
        var frames: [FeatureFrame] = []

        // 0-10s: high flight, position at (0.2, 0.3)
        for i in 0..<50 {
            let t = Double(i) * 0.2
            frames.append(frame(at: t, motion: 0.7, flightScore: 0.8, position: (0.2, 0.3)))
        }

        // 10-13s: gap — low flight, low motion
        for i in 50..<65 {
            let t = Double(i) * 0.2
            frames.append(frame(at: t, motion: 0.1, flightScore: 0.1))
        }

        // 13-30s: high flight, position at (0.7, 0.8) — position jump
        for i in 65..<150 {
            let t = Double(i) * 0.2
            frames.append(frame(at: t, motion: 0.7, flightScore: 0.8, position: (0.7, 0.8)))
        }

        let segments = [rallySegment(start: 0, end: 30)]
        let config = AnalysisConfig()

        let result = TrajectoryAnalyzer.refineSegments(segments: segments, frames: frames, config: config)

        let rallies = result.filter { $0.label == .rally }
        let gaps = result.filter { $0.label == .betweenPoints }

        XCTAssertEqual(rallies.count, 2, "Should split into 2 rallies")
        XCTAssertEqual(gaps.count, 1, "Should have 1 between-points gap")
    }

    // MARK: - Test 4: Gap Too Short

    func testGapTooShort() {
        // Gap of only 1.0s (below 1.5s minimum) → should be ignored
        var frames: [FeatureFrame] = []

        // 0-10s: visible
        for i in 0..<50 {
            frames.append(frame(at: Double(i) * 0.2, motion: 0.7, flightScore: 0.8))
        }

        // 10-11s: brief gap (1.0s, below min 1.5s)
        for i in 50..<55 {
            frames.append(frame(at: Double(i) * 0.2, motion: 0.1, flightScore: 0.1))
        }

        // 11-20s: visible again
        for i in 55..<100 {
            frames.append(frame(at: Double(i) * 0.2, motion: 0.7, flightScore: 0.8))
        }

        let segments = [rallySegment(start: 0, end: 20)]
        let config = AnalysisConfig()

        let result = TrajectoryAnalyzer.refineSegments(segments: segments, frames: frames, config: config)

        XCTAssertEqual(result.count, 1, "Gap too short — should not split")
        XCTAssertEqual(result[0].label, .rally)
    }

    // MARK: - Test 5: Gap Too Long

    func testGapTooLong() {
        // Gap of 12s (above 10s maximum) → should be ignored (game break)
        var frames: [FeatureFrame] = []

        // 0-5s: visible
        for i in 0..<25 {
            frames.append(frame(at: Double(i) * 0.2, motion: 0.7, flightScore: 0.8))
        }

        // 5-17s: long gap (12s, above max 10s)
        for i in 25..<85 {
            frames.append(frame(at: Double(i) * 0.2, motion: 0.1, flightScore: 0.1))
        }

        // 17-25s: visible again
        for i in 85..<125 {
            frames.append(frame(at: Double(i) * 0.2, motion: 0.7, flightScore: 0.8))
        }

        let segments = [rallySegment(start: 0, end: 25)]
        let config = AnalysisConfig()

        let result = TrajectoryAnalyzer.refineSegments(segments: segments, frames: frames, config: config)

        XCTAssertEqual(result.count, 1, "Gap too long — should not split")
    }

    // MARK: - Test 6: Validation Score Filtering

    func testValidationScoreFiltering() {
        // Gap has valid duration but only 1 signal (high motion during gap, no position data, no confidence pattern)
        var frames: [FeatureFrame] = []

        // 0-10s: visible, no position data
        for i in 0..<50 {
            frames.append(frame(at: Double(i) * 0.2, motion: 0.7, flightScore: 0.8))
        }

        // 10-13s: gap — but HIGH motion (no dip signal), no positions
        for i in 50..<65 {
            frames.append(frame(at: Double(i) * 0.2, motion: 0.8, flightScore: 0.1))
        }

        // 13-25s: visible, no position data
        for i in 65..<125 {
            frames.append(frame(at: Double(i) * 0.2, motion: 0.7, flightScore: 0.8))
        }

        let segments = [rallySegment(start: 0, end: 25)]
        let config = AnalysisConfig()

        let result = TrajectoryAnalyzer.refineSegments(segments: segments, frames: frames, config: config)

        // Score: motion dip=0 (high motion), position=0 (no data), confidence=1 (0.8>0.5 on both sides)
        // Total = 1 < 2 → gap rejected
        XCTAssertEqual(result.count, 1, "Only 1/3 signals — gap should be rejected")
    }

    // MARK: - Test 7: Position Discontinuity

    func testPositionDiscontinuity() {
        // Gap with position jump > 0.3 normalized distance
        var frames: [FeatureFrame] = []

        // 0-8s: shuttle at (0.1, 0.1)
        for i in 0..<40 {
            frames.append(frame(at: Double(i) * 0.2, motion: 0.7, flightScore: 0.8, position: (0.1, 0.1)))
        }

        // 8-10s: gap with low motion
        for i in 40..<50 {
            frames.append(frame(at: Double(i) * 0.2, motion: 0.1, flightScore: 0.1))
        }

        // 10-20s: shuttle at (0.9, 0.9) — large position jump
        for i in 50..<100 {
            frames.append(frame(at: Double(i) * 0.2, motion: 0.7, flightScore: 0.8, position: (0.9, 0.9)))
        }

        let segments = [rallySegment(start: 0, end: 20)]
        let config = AnalysisConfig()

        let result = TrajectoryAnalyzer.refineSegments(segments: segments, frames: frames, config: config)

        let rallies = result.filter { $0.label == .rally }
        // Score: motion dip=1 (<0.3), position=1 (dist≈1.13>0.3), confidence=1 (0.8>0.5) = 3 → accepted
        XCTAssertEqual(rallies.count, 2, "Position jump should cause split")
    }

    // MARK: - Test 8: Multiple Gaps Split Rally

    func testMultipleGapsSplitRally() {
        // Rally from 0-40s with 2 valid gaps → should produce 3 rally sub-segments
        var frames: [FeatureFrame] = []

        // 0-10s: rally 1
        for i in 0..<50 {
            frames.append(frame(at: Double(i) * 0.2, motion: 0.7, flightScore: 0.8, position: (0.2, 0.3)))
        }

        // 10-13s: gap 1 (low motion, position jump)
        for i in 50..<65 {
            frames.append(frame(at: Double(i) * 0.2, motion: 0.1, flightScore: 0.1))
        }

        // 13-25s: rally 2
        for i in 65..<125 {
            frames.append(frame(at: Double(i) * 0.2, motion: 0.7, flightScore: 0.8, position: (0.7, 0.8)))
        }

        // 25-28s: gap 2 (low motion, position jump)
        for i in 125..<140 {
            frames.append(frame(at: Double(i) * 0.2, motion: 0.1, flightScore: 0.1))
        }

        // 28-40s: rally 3
        for i in 140..<200 {
            frames.append(frame(at: Double(i) * 0.2, motion: 0.7, flightScore: 0.8, position: (0.3, 0.2)))
        }

        let segments = [rallySegment(start: 0, end: 40)]
        let config = AnalysisConfig()

        let result = TrajectoryAnalyzer.refineSegments(segments: segments, frames: frames, config: config)

        let rallies = result.filter { $0.label == .rally }
        let gaps = result.filter { $0.label == .betweenPoints }

        XCTAssertEqual(rallies.count, 3, "Two gaps should split into 3 rallies")
        XCTAssertEqual(gaps.count, 2, "Should have 2 between-points gaps")
    }

    // MARK: - Test: BetweenPoints segments pass through unchanged

    func testBetweenPointsPassThrough() {
        let frames = (0..<50).map { i in
            frame(at: Double(i) * 0.2, motion: 0.5, flightScore: 0.8)
        }
        let segments = [
            rallySegment(start: 0, end: 5),
            betweenSegment(start: 5, end: 8),
            rallySegment(start: 8, end: 10),
        ]
        let config = AnalysisConfig()

        let result = TrajectoryAnalyzer.refineSegments(segments: segments, frames: frames, config: config)

        // No gaps in the rally portions → should pass through unchanged
        let between = result.filter { $0.label == .betweenPoints }
        XCTAssertEqual(between.count, 1)
        XCTAssertEqual(between[0].start, 5)
        XCTAssertEqual(between[0].end, 8)
    }
}
