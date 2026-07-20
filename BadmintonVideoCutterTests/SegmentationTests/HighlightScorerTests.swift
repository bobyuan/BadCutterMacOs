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

    // MARK: - Percentile feature vectors (shared with the learned ranker)

    func testPercentileVectorsMatchHeuristicScores() {
        let (frames, points) = syntheticFramesAndPoints()
        let vectors = HighlightScorer.percentileFeatureVectors(points: points, frames: frames)
        let scores = HighlightScorer.scores(points: points, frames: frames)
        XCTAssertEqual(vectors.count, 2)
        XCTAssertEqual(vectors[points[0].id]?.count, HighlightScorer.featureNames.count)

        let w = HighlightScorer.weights
        let weightVector = [w.duration, w.hitCount, w.tempo, w.maxShuttleSpeed, w.avgMotion, w.climax]
        for point in points {
            let manual = zip(vectors[point.id]!, weightVector).reduce(0) { $0 + $1.0 * $1.1 }
            XCTAssertEqual(manual, scores[point.id]!, accuracy: 0.0001)
        }
    }

    // MARK: - Ranker concordance

    func testConcordancePerfectAndInverted() {
        let perfect: [(score: Double, liked: Bool)] = [(0.9, true), (0.8, true), (0.2, false), (0.1, false)]
        XCTAssertEqual(HighlightRanker.concordance(of: perfect)!, 1.0, accuracy: 0.001)

        let inverted: [(score: Double, liked: Bool)] = [(0.1, true), (0.9, false)]
        XCTAssertEqual(HighlightRanker.concordance(of: inverted)!, 0.0, accuracy: 0.001)

        let ties: [(score: Double, liked: Bool)] = [(0.5, true), (0.5, false)]
        XCTAssertEqual(HighlightRanker.concordance(of: ties)!, 0.5, accuracy: 0.001)
    }

    func testConcordanceNilForSingleClass() {
        XCTAssertNil(HighlightRanker.concordance(of: [(0.9, true), (0.8, true)]))
    }

    func testRankerTrainAndPredictSeparatesClasses() async throws {
        // Liked points have high duration+tempo percentiles; disliked low.
        var samples: [HighlightRanker.RatedSample] = []
        for i in 0..<20 {
            let jitter = Double(i) / 200.0
            samples.append(HighlightRanker.RatedSample(
                features: [0.8 + jitter / 4, 0.7, 0.8, 0.7, 0.6, 0.7], liked: true))
            samples.append(HighlightRanker.RatedSample(
                features: [0.2 - jitter / 4, 0.3, 0.2, 0.3, 0.4, 0.3], liked: false))
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("ranker_test_\(UUID().uuidString).mlmodelc")
        addTeardownBlock { try? FileManager.default.removeItem(at: out) }

        let concordance = try await HighlightRanker.train(samples: samples, outputModelURL: out)
        XCTAssertGreaterThan(concordance, 0.95)

        let model = try XCTUnwrap(HighlightRanker.loadModel(at: out))
        let high = try XCTUnwrap(HighlightRanker.predict(model: model, features: [0.9, 0.8, 0.9, 0.8, 0.7, 0.8]))
        let low = try XCTUnwrap(HighlightRanker.predict(model: model, features: [0.1, 0.2, 0.1, 0.2, 0.3, 0.2]))
        XCTAssertGreaterThan(high, low)
    }

    func testRankerRefusesTooFewRatings() async {
        let samples = [HighlightRanker.RatedSample(features: [0.5, 0.5, 0.5, 0.5, 0.5, 0.5], liked: true)]
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("ranker_few.mlmodelc")
        do {
            _ = try await HighlightRanker.train(samples: samples, outputModelURL: out)
            XCTFail("Expected notEnoughRatings")
        } catch {
            XCTAssertTrue("\(error)".contains("notEnoughRatings"))
        }
    }

    // MARK: - PointAdjuster (feedback-driven fixes)

    /// Frames every 0.2s across [0, 60]; `activeRanges` get motion 0.3 +
    /// shuttle positions, the rest sit at motion 0.03.
    private func adjusterFrames(activeRanges: [ClosedRange<TimeInterval>]) -> [FeatureFrame] {
        stride(from: 0.0, through: 60.0, by: 0.2).map { t in
            let active = activeRanges.contains { $0.contains(t) }
            var f = FeatureFrame(timestamp: t, motionScore: active ? 0.3 : 0.03, audioScore: 0)
            if active { f.shuttlecockPosition = (x: 0.5, y: 0.5) }
            return f
        }
    }

    private func adjusterContext(
        point: GamePoint,
        activeRanges: [ClosedRange<TimeInterval>],
        onsets: [TimeInterval] = [],
        previousEnd: TimeInterval = 0,
        nextStart: TimeInterval = 60
    ) -> PointAdjuster.Context {
        PointAdjuster.Context(
            point: point,
            previousEnd: previousEnd,
            nextStart: nextStart,
            frames: adjusterFrames(activeRanges: activeRanges),
            onsets: onsets,
            videoDuration: 60
        )
    }

    private func adjusterPoint(_ start: TimeInterval, _ end: TimeInterval) -> GamePoint {
        GamePoint(pointNumber: 1, rallySegment: TimeSegment(start: start, end: end, label: .rally, confidence: 1))
    }

    func testAdjusterStartsTooEarlyAnchorsOnFirstEvidence() throws {
        // Point [10, 20], but play only starts at 14 (onset + shuttle).
        let ctx = adjusterContext(point: adjusterPoint(10, 20), activeRanges: [14...20], onsets: [14.1, 15, 16])
        let proposal = try XCTUnwrap(PointAdjuster.propose(reason: .startsTooEarly, context: ctx))
        guard case .adjustStart(let to) = proposal else { return XCTFail("\(proposal)") }
        XCTAssertEqual(to, 13.5, accuracy: 0.4)   // ~0.7s before first evidence
    }

    func testAdjusterEndsTooLateAnchorsOnLastEvidence() throws {
        // Point [10, 25], play stops at 18.
        let ctx = adjusterContext(point: adjusterPoint(10, 25), activeRanges: [10...18], onsets: [12, 17.8])
        let proposal = try XCTUnwrap(PointAdjuster.propose(reason: .endsTooLate, context: ctx))
        guard case .adjustEnd(let to) = proposal else { return XCTFail("\(proposal)") }
        XCTAssertEqual(to, 19.0, accuracy: 0.4)   // ~1s after last evidence
    }

    func testAdjusterEndsTooEarlyExtendsWhileActive() throws {
        // Point [10, 15] but activity continues to 19; next point at 30.
        let ctx = adjusterContext(point: adjusterPoint(10, 15), activeRanges: [10...19], nextStart: 30)
        let proposal = try XCTUnwrap(PointAdjuster.propose(reason: .endsTooEarly, context: ctx))
        guard case .adjustEnd(let to) = proposal else { return XCTFail("\(proposal)") }
        XCTAssertGreaterThan(to, 18.5)
        XCTAssertLessThan(to, 21.0)
    }

    func testAdjusterStartsTooLateExtendsBackWhileActive() throws {
        // Point [15, 25] but the rally has been running since 11.
        let ctx = adjusterContext(point: adjusterPoint(15, 25), activeRanges: [11...25], previousEnd: 5)
        let proposal = try XCTUnwrap(PointAdjuster.propose(reason: .startsTooLate, context: ctx))
        guard case .adjustStart(let to) = proposal else { return XCTFail("\(proposal)") }
        XCTAssertLessThan(to, 12.0)
        XCTAssertGreaterThanOrEqual(to, 5.1)
    }

    func testAdjusterSplitFindsInternalDip() throws {
        // Point [10, 30] with a dead zone 18–23 in the middle.
        let ctx = adjusterContext(point: adjusterPoint(10, 30), activeRanges: [10...18, 23...30])
        let proposal = try XCTUnwrap(PointAdjuster.propose(reason: .shouldSplit, context: ctx))
        guard case .split(let firstEnd, let secondStart) = proposal else { return XCTFail("\(proposal)") }
        XCTAssertEqual(firstEnd, 19.0, accuracy: 1.0)
        XCTAssertEqual(secondStart, 22.5, accuracy: 1.0)
        XCTAssertLessThan(firstEnd, secondStart)
    }

    func testAdjusterMissedPointBeforeFindsActivityInGap() throws {
        // Gap [0, 30] before point [30, 40]; a missed rally lives at 12–18.
        let ctx = adjusterContext(point: adjusterPoint(30, 40), activeRanges: [12...18, 30...40], previousEnd: 0)
        let proposal = try XCTUnwrap(PointAdjuster.propose(reason: .missedPointBefore, context: ctx))
        guard case .insertBefore(let start, let end) = proposal else { return XCTFail("\(proposal)") }
        XCTAssertGreaterThan(end, start)
        // Span must overlap the actual missed rally.
        XCTAssertLessThan(start, 18)
        XCTAssertGreaterThan(end, 12)
    }

    func testAdjusterQuietGapProposesNothing() {
        // No activity in the gap → refuse rather than invent a point.
        let ctx = adjusterContext(point: adjusterPoint(30, 40), activeRanges: [30...40], previousEnd: 0)
        XCTAssertNil(PointAdjuster.propose(reason: .missedPointBefore, context: ctx))
    }

    // MARK: - vDSP onset detection (Phase 8)

    /// 5s of near-silence with sharp bursts at 1, 2, 3 and 4 seconds.
    private func clickTrack(sampleRate: Double = 44100) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(sampleRate * 5))
        for i in samples.indices { samples[i] = Float.random(in: -0.002...0.002) }
        for clickTime in [1.0, 2.0, 3.0, 4.0] {
            let start = Int(clickTime * sampleRate)
            for offset in 0..<Int(sampleRate * 0.02) {
                samples[start + offset] = 0.8 * Float(1.0 - Double(offset) / (sampleRate * 0.02))
            }
        }
        return samples
    }

    func testOnsetDetectionFindsClicks() {
        let onsets = AudioSignalExtractor.detectOnsets(samples: clickTrack(), sampleRate: 44100)
        XCTAssertEqual(onsets.count, 4, "onsets: \(onsets)")
        for (found, expected) in zip(onsets, [1.0, 2.0, 3.0, 4.0]) {
            XCTAssertEqual(found, expected, accuracy: 0.05)
        }
    }

    func testOnsetDetectionSilentAudioFindsNothing() {
        let silence = [Float](repeating: 0, count: 44100 * 3)
        XCTAssertTrue(AudioSignalExtractor.detectOnsets(samples: silence, sampleRate: 44100).isEmpty)
    }

    func testHitDetectorPrefersPreciseOnsets() {
        // No trajectory, no high quantized audio — only explicit onsets count.
        let frames = (0..<120).map { FeatureFrame(timestamp: Double($0) / 30.0, motionScore: 0.2, audioScore: 0.25) }
        let segment = TimeSegment(start: 0, end: 4, label: .rally, confidence: 1)
        let hits = HitDetector.detectHits(frames: frames, in: segment, onsets: [0.5, 1.5, 2.5, 9.0])
        XCTAssertEqual(hits, [0.5, 1.5, 2.5], "onsets outside the segment are ignored")
    }

    // MARK: - Cheer blending (Phase 8)

    func testCheerBlendBoostsCheeredPoint() {
        let (points, _) = selectionFixture()  // 4 points, 10s each at 0/20/40/60
        let base = Dictionary(uniqueKeysWithValues: points.map { ($0.id, 0.5) })
        // Big cheer right after point 2's end (t=30), quiet elsewhere.
        let timeline = stride(from: 0.0, to: 75.0, by: 1.0).map {
            AudioSignals.CheerSample(t: $0, score: abs($0 - 30.5) < 1.5 ? 0.9 : 0.05)
        }
        let blended = HighlightScorer.applyingCheer(to: base, points: points, timeline: timeline)
        let cheered = blended[points[1].id]!
        for other in points where other.id != points[1].id {
            XCTAssertGreaterThan(cheered, blended[other.id]!)
        }
    }

    func testCheerBlendNoTimelineLeavesScoresUntouched() {
        let (points, _) = selectionFixture()
        let base = Dictionary(uniqueKeysWithValues: points.map { ($0.id, Double($0.pointNumber) / 10) })
        XCTAssertEqual(HighlightScorer.applyingCheer(to: base, points: points, timeline: []), base)
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
