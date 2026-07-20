import XCTest
@testable import BadmintonVideoCutter

final class SegmentUtilsTests: XCTestCase {
    func testMergeAdjacentSameLabel() {
        let s1 = TimeSegment(start: 0, end: 2, label: .rally, confidence: 0.8)
        let s2 = TimeSegment(start: 2.05, end: 4, label: .rally, confidence: 0.9)
        let merged = SegmentUtils.mergeAdjacent([s1, s2], maxGap: 0.1)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(merged[0].end, 4, accuracy: 0.001)
    }

    // MARK: - defaultAddedPointSpan

    private func frames(over range: ClosedRange<TimeInterval>,
                        highAudio: [ClosedRange<TimeInterval>] = []) -> [FeatureFrame] {
        stride(from: range.lowerBound, through: range.upperBound, by: 0.1).map { t in
            let audio: Double = highAudio.contains { $0.contains(t) } ? 0.75 : 0.0
            return FeatureFrame(timestamp: t, motionScore: 0.05, audioScore: audio)
        }
    }

    private let rallies = [
        TimeSegment(start: 0, end: 10, label: .rally, confidence: 1.0),
        TimeSegment(start: 30, end: 40, label: .rally, confidence: 1.0)
    ]

    func testAddedSpanUsesHighAudioWindowInBreak() {
        let span = SegmentUtils.defaultAddedPointSpan(
            playhead: 20,
            frames: frames(over: 0...40, highAudio: [18...22]),
            activeSegments: rallies,
            videoDuration: 40
        )
        XCTAssertEqual(span.start, 17, accuracy: 0.15)
        XCTAssertEqual(span.end, 23, accuracy: 0.15)
    }

    func testAddedSpanFallsBackWhenBreakIsSilent() {
        let span = SegmentUtils.defaultAddedPointSpan(
            playhead: 20,
            frames: frames(over: 0...40),
            activeSegments: rallies,
            videoDuration: 40
        )
        XCTAssertEqual(span.start, 16, accuracy: 0.001)
        XCTAssertEqual(span.end, 24, accuracy: 0.001)
    }

    func testAddedSpanIgnoresFarAwayAudio() {
        // High audio right after the first rally, playhead late in the break —
        // too far away (> 3s) to snap to, so falls back to ±4s.
        let span = SegmentUtils.defaultAddedPointSpan(
            playhead: 25,
            frames: frames(over: 0...40, highAudio: [10.5...12]),
            activeSegments: rallies,
            videoDuration: 40
        )
        XCTAssertEqual(span.start, 21, accuracy: 0.001)
        XCTAssertEqual(span.end, 29, accuracy: 0.001)
    }

    func testAddedSpanClampsToNeighboringPoints() {
        let tight = [
            TimeSegment(start: 0, end: 18, label: .rally, confidence: 1.0),
            TimeSegment(start: 22, end: 40, label: .rally, confidence: 1.0)
        ]
        let span = SegmentUtils.defaultAddedPointSpan(
            playhead: 20,
            frames: frames(over: 0...40),
            activeSegments: tight,
            videoDuration: 40
        )
        XCTAssertEqual(span.start, 18, accuracy: 0.001)
        XCTAssertEqual(span.end, 22, accuracy: 0.001)
    }

    func testAddedSpanClampsToVideoBounds() {
        let span = SegmentUtils.defaultAddedPointSpan(
            playhead: 2,
            frames: frames(over: 0...40),
            activeSegments: [],
            videoDuration: 40
        )
        XCTAssertEqual(span.start, 0, accuracy: 0.001)
        XCTAssertEqual(span.end, 6, accuracy: 0.001)
    }

    func testAddedSpanInsideExistingPointUsesFallback() {
        let span = SegmentUtils.defaultAddedPointSpan(
            playhead: 5,
            frames: frames(over: 0...40),
            activeSegments: rallies,
            videoDuration: 40
        )
        XCTAssertEqual(span.start, 1, accuracy: 0.001)
        XCTAssertEqual(span.end, 9, accuracy: 0.001)
    }

    func testAddedSpanEnforcesMinimumDuration() {
        // Audio run hugging the break's start would clamp to a sliver without
        // the minimum-span expansion.
        let tight = [
            TimeSegment(start: 0, end: 19.8, label: .rally, confidence: 1.0),
            TimeSegment(start: 29, end: 40, label: .rally, confidence: 1.0)
        ]
        let span = SegmentUtils.defaultAddedPointSpan(
            playhead: 20,
            frames: frames(over: 0...40, highAudio: [19.9...20.0]),
            activeSegments: tight,
            videoDuration: 40
        )
        XCTAssertGreaterThanOrEqual(span.end - span.start, 1.0 - 0.001)
        XCTAssertGreaterThanOrEqual(span.start, 19.8 - 0.001)
        XCTAssertLessThanOrEqual(span.end, 29.001)
    }
}
