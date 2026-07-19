import XCTest
@testable import BadmintonVideoCutter

final class HighlightScorerTests: XCTestCase {

    static let cacheDir = URL(fileURLWithPath: "/Users/boyuan/Documents/badminton_video_cutter/TestData")

    // MARK: - HitDetector (synthetic)

    /// A shuttle bouncing between y=0.3 and y=0.7 once per second: each
    /// descending→ascending turn (the strike) is one hit.
    func testHitDetectorCountsDirectionChanges() {
        var frames: [FeatureFrame] = []
        for i in 0..<120 {  // 4s at 30fps
            let t = Double(i) / 30.0
            let phase = t.truncatingRemainder(dividingBy: 1.0)
            let y = phase < 0.5 ? 0.3 + 0.8 * phase : 0.7 - 0.8 * (phase - 0.5)
            var f = FeatureFrame(timestamp: t, motionScore: 0.2, audioScore: 0)
            f.shuttlecockPosition = (x: 0.5, y: y)
            frames.append(f)
        }
        let segment = TimeSegment(start: 0, end: 4, label: .rally, confidence: 1)
        let hits = HitDetector.detectHits(frames: frames, in: segment)
        // Turns at t = 0.5, 1.5, 2.5, 3.5
        XCTAssertEqual(hits.count, 4)
    }

    func testHitDetectorFallsBackToAudioOnsets() {
        var frames: [FeatureFrame] = []
        for i in 0..<120 {
            let t = Double(i) / 30.0
            let inBurst = [1.0, 2.0, 3.0].contains { t >= $0 && t < $0 + 0.2 }
            frames.append(FeatureFrame(timestamp: t, motionScore: 0.2, audioScore: inBurst ? 0.75 : 0.0))
        }
        let segment = TimeSegment(start: 0, end: 4, label: .rally, confidence: 1)
        let hits = HitDetector.detectHits(frames: frames, in: segment)
        XCTAssertEqual(hits.count, 3)
    }

    // MARK: - Scorer (synthetic)

    private func syntheticFramesAndPoints() -> (frames: [FeatureFrame], points: [GamePoint]) {
        var frames: [FeatureFrame] = []
        // Point A [0, 10]: long, loud, high motion, bouncing shuttle.
        for i in 0..<300 {
            let t = Double(i) / 30.0
            let phase = t.truncatingRemainder(dividingBy: 1.0)
            var f = FeatureFrame(timestamp: t, motionScore: 0.25, audioScore: 0.5)
            f.shuttlecockPosition = (x: 0.5, y: phase < 0.5 ? 0.3 + 0.8 * phase : 0.7 - 0.8 * (phase - 0.5))
            frames.append(f)
        }
        // Break [10, 15]
        for i in 0..<150 {
            frames.append(FeatureFrame(timestamp: 10 + Double(i) / 30.0, motionScore: 0.05, audioScore: 0))
        }
        // Point B [15, 17]: short and quiet, no shuttle tracked.
        for i in 0..<60 {
            frames.append(FeatureFrame(timestamp: 15 + Double(i) / 30.0, motionScore: 0.08, audioScore: 0))
        }
        let a = GamePoint(pointNumber: 1, rallySegment: TimeSegment(start: 0, end: 10, label: .rally, confidence: 1))
        let b = GamePoint(pointNumber: 2, rallySegment: TimeSegment(start: 15, end: 17, label: .rally, confidence: 1))
        return (frames, [a, b])
    }

    func testScoresAreInUnitRangeAndComplete() {
        let (frames, points) = syntheticFramesAndPoints()
        let scores = HighlightScorer.scores(points: points, frames: frames)
        XCTAssertEqual(scores.count, 2)
        for score in scores.values {
            XCTAssertGreaterThanOrEqual(score, 0)
            XCTAssertLessThanOrEqual(score, 1)
        }
    }

    func testLongIntensePointOutscoresShortQuietOne() {
        let (frames, points) = syntheticFramesAndPoints()
        let scores = HighlightScorer.scores(points: points, frames: frames)
        XCTAssertGreaterThan(scores[points[0].id]!, scores[points[1].id]!)
    }

    func testSinglePointGetsMidScore() {
        let (frames, points) = syntheticFramesAndPoints()
        let scores = HighlightScorer.scores(points: [points[0]], frames: frames)
        XCTAssertEqual(scores[points[0].id]!, 0.5, accuracy: 0.001)
    }

    // MARK: - Highlight selection policies

    /// 4 points of 10s each; scores 0.9, 0.3, 0.7, 0.1 in time order.
    private func selectionFixture() -> (points: [GamePoint], scores: [UUID: Double]) {
        let points = (0..<4).map { i in
            GamePoint(pointNumber: i + 1, rallySegment: TimeSegment(
                start: Double(i) * 20, end: Double(i) * 20 + 10, label: .rally, confidence: 1))
        }
        let scores = [points[0].id: 0.9, points[1].id: 0.3, points[2].id: 0.7, points[3].id: 0.1]
        return (points, scores)
    }

    func testSelectTopPercentPicksBestChronologically() {
        let (points, scores) = selectionFixture()
        let picked = HighlightScorer.select(points: points, scores: scores, selection: .topPercent(50))
        XCTAssertEqual(picked.map(\.pointNumber), [1, 3])  // best two, back in time order
    }

    func testSelectTopPercentAlwaysPicksAtLeastOne() {
        let (points, scores) = selectionFixture()
        let picked = HighlightScorer.select(points: points, scores: scores, selection: .topPercent(5))
        XCTAssertEqual(picked.map(\.pointNumber), [1])
    }

    func testSelectTopMinutesRespectsBudget() {
        let (points, scores) = selectionFixture()
        // 25s budget fits two 10s points, not three.
        let picked = HighlightScorer.select(points: points, scores: scores, selection: .topMinutes(25.0 / 60.0))
        XCTAssertEqual(picked.map(\.pointNumber), [1, 3])
    }

    func testSelectThresholdMayBeEmpty() {
        let (points, scores) = selectionFixture()
        XCTAssertEqual(
            HighlightScorer.select(points: points, scores: scores, selection: .threshold(0.6)).map(\.pointNumber),
            [1, 3]
        )
        XCTAssertTrue(HighlightScorer.select(points: points, scores: scores, selection: .threshold(0.95)).isEmpty)
    }

    // MARK: - Golden tests over the 5 cached videos

    /// Start times (s) of the top-3 points by highlight score, per video.
    /// Captured from the frozen pipeline (aggressive preset) — if a scorer or
    /// pipeline change moves these, that ranking shift must be intentional.
    static let goldenTop3: [String: [Double]] = [
        "IMG_8510": [6.6, 686.8, 501.2],
        "IMG_6155": [165.1, 348.3, 149.5],
        "IMG_6155_2": [276.1, 75.2, 55.1],
        "IMG_6155_3": [477.7, 532.2, 206.9],
        "IMG_6156": [454.0, 186.2, 17.8]
    ]

    func testGoldenTop3StablePerVideo() throws {
        let videos = ["IMG_8510", "IMG_6155", "IMG_6155_2", "IMG_6155_3", "IMG_6156"]
        var captured: [String: [Double]] = [:]

        for video in videos {
            let url = Self.cacheDir.appendingPathComponent("\(video)_frames.json")
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw XCTSkip("Missing cached frames for \(video)")
            }
            let data = try Data(contentsOf: url)
            let frames = try JSONDecoder().decode([CodableFrame].self, from: data).map { $0.toFeatureFrame() }

            // Mirror AppState's analysis pipeline (aggressive preset).
            let preset = SensitivityPreset.aggressive
            let config = AnalysisConfig(
                rallyPercentile: preset.rallyPercentile,
                motionWeight: preset.motionWeight,
                audioWeight: preset.audioWeight
            )
            let classifier = HybridSegmenter()
            let raw = classifier.classify(frames: frames, config: config)
            let processed = classifier.postProcess(segments: raw, frames: frames, config: config)
            let taRefined = TrajectoryAnalyzer.refineSegments(segments: processed, frames: frames, config: config)
            let refined = SegmentUtils.mergeAdjacent(SegmentUtils.removeInvalid(taRefined), maxGap: 0.5)
            let games = GameDetector.detectGames(from: refined, featureFrames: frames)
            let points = games.flatMap(\.points)
            XCTAssertFalse(points.isEmpty, "\(video): pipeline should produce points")

            let scores = HighlightScorer.scores(points: points, frames: frames)
            XCTAssertEqual(scores.count, points.count, "\(video): every point scored")
            for score in scores.values {
                XCTAssertGreaterThanOrEqual(score, 0, video)
                XCTAssertLessThanOrEqual(score, 1, video)
            }

            let top3 = points
                .sorted { (scores[$0.id] ?? 0) > (scores[$1.id] ?? 0) }
                .prefix(3)
                .map { ($0.start * 10).rounded() / 10 }
            captured[video] = Array(top3)
            print("GOLDEN \(video): \(Array(top3))")

            if let expected = Self.goldenTop3[video] {
                XCTAssertEqual(Array(top3), expected, "\(video): top-3 highlight ranking changed")
            }
        }

        if Self.goldenTop3.isEmpty {
            print("GOLDEN CAPTURE: \(captured)")
        }
    }
}
