import XCTest
@testable import BadmintonVideoCutter

final class ShadowEvalTests: XCTestCase {

    private func segment(_ start: Double, _ end: Double) -> TimeSegment {
        TimeSegment(start: start, end: end, label: .rally, confidence: 1)
    }

    private func point(_ start: Double, _ end: Double, status: PointReviewStatus = .unreviewed) -> GamePoint {
        GamePoint(pointNumber: 0, rallySegment: segment(start, end), reviewStatus: status)
    }

    // MARK: - IoU + matching

    func testIoU() {
        XCTAssertEqual(ShadowEval.iou(segment(0, 10), segment(0, 10)), 1.0, accuracy: 0.001)
        XCTAssertEqual(ShadowEval.iou(segment(0, 10), segment(5, 15)), 5.0 / 15.0, accuracy: 0.001)
        XCTAssertEqual(ShadowEval.iou(segment(0, 10), segment(20, 30)), 0, accuracy: 0.001)
    }

    func testEvaluateCountsMatchesAndErrors() {
        // Truth: three active points + one deleted (deleted must be ignored).
        let added = point(40, 48)
        let truth = [point(0, 10), point(20, 28), added, point(60, 70, status: .deleted)]
        // Predictions: match #1 exactly, match #2 shifted by 1s each edge,
        // miss the added point, plus one spurious detection.
        let predicted = [segment(0, 10), segment(21, 29), segment(100, 105)]

        let result = ShadowEval.evaluate(predicted: predicted, groundTruth: truth, addedPointIDs: [added.id])
        XCTAssertEqual(result.truePositives, 2)
        XCTAssertEqual(result.falsePositives, 1)
        XCTAssertEqual(result.falseNegatives, 1)   // the added point
        XCTAssertEqual(result.addedPointsTotal, 1)
        XCTAssertEqual(result.addedPointsFound, 0)
        XCTAssertEqual(result.boundaryErrors.count, 2)
        XCTAssertEqual(result.boundaryErrors.reduce(0, +), 0 + 1.0, accuracy: 0.001)
    }

    func testEvaluateMatchesEachSideOnce() {
        // Two predictions over one truth point: only the better one matches.
        let truth = [point(0, 10)]
        let predicted = [segment(0, 10), segment(1, 9)]
        let result = ShadowEval.evaluate(predicted: predicted, groundTruth: truth, addedPointIDs: [])
        XCTAssertEqual(result.truePositives, 1)
        XCTAssertEqual(result.falsePositives, 1)
        XCTAssertEqual(result.boundaryErrors.first ?? -1, 0, accuracy: 0.001)
    }

    // MARK: - Aggregation

    func testAggregateDerivesMetrics() {
        var a = ShadowEval.SessionResult()
        a.truePositives = 8; a.falsePositives = 2; a.falseNegatives = 2
        a.boundaryErrors = [1.0, 1.0]
        a.addedPointsTotal = 2; a.addedPointsFound = 1
        var b = ShadowEval.SessionResult()
        b.truePositives = 2; b.falsePositives = 0; b.falseNegatives = 0
        b.boundaryErrors = [2.0, 4.0]

        let m = ShadowEval.aggregate([a, b])
        XCTAssertEqual(m.sessionCount, 2)
        XCTAssertEqual(m.precision, 10.0 / 12.0, accuracy: 0.001)
        XCTAssertEqual(m.recall, 10.0 / 12.0, accuracy: 0.001)
        XCTAssertEqual(m.f1, 10.0 / 12.0, accuracy: 0.001)
        XCTAssertEqual(m.boundaryMAE, 2.0, accuracy: 0.001)
        XCTAssertEqual(m.addedPointRecall, 0.5, accuracy: 0.001)
    }

    // MARK: - Audio Re-Scoring (D-007)

    func testRemapAudioScoresUsesNearestWindow() {
        let frames = [0.0, 0.4, 0.6, 1.1, 5.0].map {
            FeatureFrame(timestamp: $0, motionScore: 0.1, audioScore: 0.99)
        }
        let features = [
            AudioFeature(timestamp: 0.25, rmsEnergy: 0, isOnset: false, rallyScore: 0.1),
            AudioFeature(timestamp: 0.75, rmsEnergy: 0, isOnset: false, rallyScore: 0.5),
            AudioFeature(timestamp: 1.25, rmsEnergy: 0, isOnset: false, rallyScore: 0.9)
        ]
        let remapped = ShadowEval.remapAudioScores(frames: frames, features: features)
        XCTAssertEqual(remapped.map(\.audioScore), [0.1, 0.1, 0.5, 0.9, 0.9])
        // Other fields untouched
        XCTAssertEqual(remapped[0].motionScore, 0.1)
        // Empty features → unchanged
        XCTAssertEqual(ShadowEval.remapAudioScores(frames: frames, features: []).map(\.audioScore),
                       frames.map(\.audioScore))
    }

    // MARK: - Gate

    private func metrics(f1TP tp: Int, fp: Int, fn: Int, addedTotal: Int = 0, addedFound: Int = 0) -> ShadowEvalMetrics {
        var m = ShadowEvalMetrics()
        m.truePositives = tp; m.falsePositives = fp; m.falseNegatives = fn
        m.addedPointsTotal = addedTotal; m.addedPointsFound = addedFound
        m.sessionCount = 1
        return m
    }

    func testGatePromotesWithoutBaseline() {
        let decision = ShadowEval.gate(candidate: metrics(f1TP: 5, fp: 5, fn: 5), current: nil)
        XCTAssertTrue(decision.promote)
    }

    func testGateHoldsOnF1Regression() {
        let current = metrics(f1TP: 10, fp: 0, fn: 0)          // F1 = 1.0
        let candidate = metrics(f1TP: 8, fp: 2, fn: 2)          // F1 = 0.8
        let decision = ShadowEval.gate(candidate: candidate, current: current)
        XCTAssertFalse(decision.promote)
        XCTAssertTrue(decision.reason.contains("F1"))
    }

    func testGateHoldsOnAddedPointRegression() {
        let current = metrics(f1TP: 10, fp: 0, fn: 0, addedTotal: 2, addedFound: 2)
        let candidate = metrics(f1TP: 10, fp: 0, fn: 0, addedTotal: 2, addedFound: 1)
        let decision = ShadowEval.gate(candidate: candidate, current: current)
        XCTAssertFalse(decision.promote)
        XCTAssertTrue(decision.reason.contains("Added-point"))
    }

    func testGatePromotesWithinEpsilon() {
        let current = metrics(f1TP: 100, fp: 1, fn: 1)
        let candidate = metrics(f1TP: 99, fp: 2, fn: 2)
        XCTAssertTrue(ShadowEval.gate(candidate: candidate, current: current).promote)
    }

    // MARK: - Score chain (winner of N = server of N+1)

    private func scorePoints(_ count: Int) -> [GamePoint] {
        (0..<count).map { i in
            GamePoint(pointNumber: i + 1, rallySegment: TimeSegment(
                start: Double(i) * 10, end: Double(i) * 10 + 8, label: .rally, confidence: 1))
        }
    }

    func testScoreFollowsNextServer() {
        // Serves: A A B A  (A = left, serves first)
        // Winner of p1 = server of p2 = A -> 1:0
        // Winner of p2 = server of p3 = B -> 1:1
        // Winner of p3 = server of p4 = A -> 2:1
        // p4 last, no next game -> leader (A) -> 3:1
        let points = scorePoints(4)
        let sides: [UUID: ServeDetector.ServeSide] = [
            points[0].id: .left, points[1].id: .left, points[2].id: .right, points[3].id: .left
        ]
        let scores = ServeDetector.computeScores(points: points, serveSides: sides)
        assertScore(scores[points[0].id], 1, 0)
        assertScore(scores[points[1].id], 1, 1)
        assertScore(scores[points[2].id], 2, 1)
        assertScore(scores[points[3].id], 3, 1)
    }

    private func assertScore(_ score: ServeDetector.PointScore?, _ a: Int, _ b: Int,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(score?.scoreA, a, file: file, line: line)
        XCTAssertEqual(score?.scoreB, b, file: file, line: line)
    }

    func testScoreUnknownCurrentServeStillResolvedByNextServe() {
        // p2's own serve is unknown, but p1's winner comes from p2... p1's
        // winner needs p2's serve (unknown -> leader guess), while p2's winner
        // comes from p3's KNOWN serve — the direct rule still scores it.
        let points = scorePoints(3)
        let sides: [UUID: ServeDetector.ServeSide] = [
            points[0].id: .left, points[2].id: .right
        ]
        let scores = ServeDetector.computeScores(points: points, serveSides: sides, nextGameFirstServe: .right)
        // p1: next serve unknown -> leader guess (tied -> A) -> 1:0
        assertScore(scores[points[0].id], 1, 0)
        // p2: winner = server of p3 = B -> 1:1
        assertScore(scores[points[1].id], 1, 1)
        // p3: winner = next game first serve = B -> 1:2
        assertScore(scores[points[2].id], 1, 2)
    }

    func testScoreColumnsAnchorToExplicitFirstServer() {
        // First point's serve undetected; later serves are all .right.
        // Without an explicit anchor, A would silently re-anchor to .right.
        // With firstServe = .left (the true first server), every win by the
        // .right party must land in column B.
        let points = scorePoints(3)
        let sides: [UUID: ServeDetector.ServeSide] = [
            points[1].id: .right, points[2].id: .right
        ]
        let scores = ServeDetector.computeScores(
            points: points, serveSides: sides, nextGameFirstServe: .right, firstServe: .left)
        assertScore(scores[points[0].id], 0, 1)   // winner = server of p2 = right = B
        assertScore(scores[points[1].id], 0, 2)
        assertScore(scores[points[2].id], 0, 3)
    }

    func testCorrectingPlayTwoDoesNotMovePlayOne() {
        // User scenario (2026-07-21): chain read 1:0, 2:0. Correcting play 2's
        // winner to B must give 1:0, 1:1 — play 1 untouched, columns not
        // re-anchored. With the anchor held fixed and play 2's serve pinned
        // (as pinDisplayedWinners records), only serve(3) changes.
        let points = scorePoints(3)
        let before: [UUID: ServeDetector.ServeSide] = [
            points[1].id: .right, points[2].id: .right
        ]
        let anchor = ServeDetector.ServeSide.right
        let scoresBefore = ServeDetector.computeScores(
            points: points, serveSides: before, firstServe: anchor)
        assertScore(scoresBefore[points[0].id], 1, 0)
        assertScore(scoresBefore[points[1].id], 2, 0)

        // Correction: winner of play 2 = B -> pin serve(3) = .left. The
        // anchor is frozen and serve(2) pinned to its displayed value.
        let after: [UUID: ServeDetector.ServeSide] = [
            points[0].id: anchor, points[1].id: .right, points[2].id: .left
        ]
        let scoresAfter = ServeDetector.computeScores(
            points: points, serveSides: after, firstServe: anchor)
        assertScore(scoresAfter[points[0].id], 1, 0)   // former play unchanged
        assertScore(scoresAfter[points[1].id], 1, 1)   // corrected play only
    }

    func testExplicitLastPointWinnerBeatsNextGameFirstServe() {
        // The final play of a game with a following game: an explicit winner
        // override must beat nextGameFirstServe (that serve can be an anchor
        // pin for the NEXT game, not evidence about this play).
        let points = scorePoints(2)
        let sides: [UUID: ServeDetector.ServeSide] = [points[0].id: .left, points[1].id: .left]
        let scores = ServeDetector.computeScores(
            points: points, serveSides: sides, nextGameFirstServe: .left,
            firstServe: .left, lastPointWinner: .right)
        assertScore(scores[points[0].id], 1, 0)
        assertScore(scores[points[1].id], 1, 1)   // override B, not serve-based A
    }

    func testManualScoreAdjustmentRebasesLaterPlays() {
        // Players miscounted on court: user sets the score after p2 to 5:1.
        // p1 and p2's own computation are as detected; p3 continues from the
        // SET value, not the computed one.
        let points = scorePoints(3)
        let sides: [UUID: ServeDetector.ServeSide] = [
            points[0].id: .left, points[1].id: .left, points[2].id: .left
        ]
        let scores = ServeDetector.computeScores(
            points: points, serveSides: sides, nextGameFirstServe: .left,
            firstServe: .left,
            adjustments: [points[1].id: ServeDetector.PointScore(scoreA: 5, scoreB: 1)])
        assertScore(scores[points[0].id], 1, 0)   // untouched before the set point
        assertScore(scores[points[1].id], 5, 1)   // the manual value
        assertScore(scores[points[2].id], 6, 1)   // continues from 5:1
    }

    // MARK: - Cluster split (G1/G3)

    func testClusterSplitHandlesUnbalancedServes() {
        // 21:9-style game: 14 serves from one side (~0.30), 6 from the other
        // (~0.69). A median split would land INSIDE the big cluster and
        // misclassify several of its members; the gap split must not.
        let left = (0..<14).map { 0.28 + Double($0) * 0.004 }
        let right = (0..<6).map { 0.68 + Double($0) * 0.004 }
        let result = ServeDetector.classifySides(values: left + right)
        XCTAssertEqual(Array(result.sides[0..<14]), Array(repeating: .left, count: 14))
        XCTAssertEqual(Array(result.sides[14...]), Array(repeating: .right, count: 6))
        XCTAssertGreaterThan(result.point, 0.34)
        XCTAssertLessThan(result.point, 0.68)
    }

    func testClusterSplitMushyDistributionYieldsUnknowns() {
        // No real separation (single cluster): honest answer is unknown,
        // not a forced 50/50 assignment.
        let values = (0..<20).map { 0.300 + Double($0) * 0.0005 }
        let result = ServeDetector.classifySides(values: values)
        XCTAssertTrue(result.sides.allSatisfy { $0 == .unknown },
                      "tightly packed values must not be force-split, got \(result.sides)")
    }

    // MARK: - Sequence inference (G2) + shuttle evidence (G5)

    func testInferSidesRepairsIllegalChain() {
        // 22 observed serves all .left with anchor left → A wins 21 straight
        // (terminal at play 21) with a 22nd play following — illegal. The
        // lowest-margin observation (index 9) must flip to make the chain
        // legal; confident neighbors must not move.
        var observed: [ServeDetector.ServeSide?] = Array(repeating: .left, count: 22)
        observed[0] = .left
        var margins = Array(repeating: 0.06, count: 22)
        margins[9] = 0.001
        let pinned: [ServeDetector.ServeSide?] = Array(repeating: nil, count: 22)
        let result = ServeDetector.inferSides(observed: observed, margins: margins, pinned: pinned)
        XCTAssertEqual(result[9], .right, "lowest-margin serve should flip")
        for (i, side) in result.enumerated() where i != 9 {
            XCTAssertEqual(side, .left, "confident serve #\(i) must not move")
        }
    }

    func testInferSidesFillsUnknownsAndRespectsPins() {
        let observed: [ServeDetector.ServeSide?] = [.left, nil, .left, nil]
        let margins = [0.05, 0.0, 0.05, 0.0]
        let pinned: [ServeDetector.ServeSide?] = [nil, nil, nil, .right]
        let result = ServeDetector.inferSides(observed: observed, margins: margins, pinned: pinned)
        XCTAssertEqual(result[3], .right, "pin is a hard constraint")
        XCTAssertNotEqual(result[1], .unknown, "unknown serves get filled from context")
        XCTAssertEqual(result[0], .left)
        XCTAssertEqual(result[2], .left)
    }

    func testShuttleCentroidUsesEarlyPositionsNearOnset() {
        // Shuttle tracked at ~(0.3, 0.4) right after the serve onset at t=11;
        // later rally positions (0.8) must not dilute the serve location.
        var frames: [FeatureFrame] = []
        for i in 0..<40 {
            var f = FeatureFrame(timestamp: 10.0 + Double(i) * 0.1, motionScore: 0.1, audioScore: 0)
            if i >= 10 && i < 14 {
                f.shuttlecockPosition = (x: 0.3, y: 0.4)
            } else if i > 20 {
                f.shuttlecockPosition = (x: 0.8, y: 0.8)
            }
            frames.append(f)
        }
        let c = ServeDetector.shuttleCentroid(start: 10.0, frames: frames, onsets: [11.0])
        XCTAssertNotNil(c)
        XCTAssertEqual(c!.x, 0.3, accuracy: 0.01)
        XCTAssertEqual(c!.y, 0.4, accuracy: 0.01)
    }

    func testServeAnchorTimePicksFirstOnsetInWindow() {
        XCTAssertEqual(ServeDetector.serveAnchorTime(start: 10, onsets: [5, 10.8, 12.5]), 10.8)
        XCTAssertEqual(ServeDetector.serveAnchorTime(start: 10, onsets: [20]), 10)
    }

    // MARK: - Score rules validation

    func testValidatorFlagsPlayAfterGameEnd() {
        let points = scorePoints(3)
        // 20:9 → 21:9 (terminal) → 22:9 (illegal continuation)
        let ordered = [
            (pointID: points[0].id, score: ServeDetector.PointScore(scoreA: 20, scoreB: 9)),
            (pointID: points[1].id, score: ServeDetector.PointScore(scoreA: 21, scoreB: 9)),
            (pointID: points[2].id, score: ServeDetector.PointScore(scoreA: 22, scoreB: 9))
        ]
        let violation = ScoreValidator.firstViolation(orderedScores: ordered)
        XCTAssertEqual(violation?.pointID, points[2].id)
        XCTAssertTrue(violation?.reason.contains("21:9") ?? false)
    }

    func testValidatorAcceptsDeuceAndCap() {
        XCTAssertFalse(ScoreValidator.isTerminal(21, 20))   // deuce continues
        XCTAssertTrue(ScoreValidator.isTerminal(22, 20))
        XCTAssertTrue(ScoreValidator.isTerminal(30, 29))    // cap
        XCTAssertTrue(ScoreValidator.isTerminal(21, 9))
        XCTAssertFalse(ScoreValidator.isTerminal(20, 9))
        let points = scorePoints(2)
        let ordered = [
            (pointID: points[0].id, score: ServeDetector.PointScore(scoreA: 20, scoreB: 20)),
            (pointID: points[1].id, score: ServeDetector.PointScore(scoreA: 21, scoreB: 20))
        ]
        XCTAssertNil(ScoreValidator.firstViolation(orderedScores: ordered))
    }

    func testChooseFlipsPrefersLowConfidenceAndSkipsPinned() {
        // A-wins at 0,1,3; need 2 flips A→B. Index 1 pinned; lowest margins 3 then 0.
        let winners: [Bool?] = [true, true, false, true]
        let margins: [Double] = [0.10, 0.01, 0.50, 0.02]
        let pinned = [false, true, false, false]
        let flips = ScoreValidator.chooseFlips(winnersIsA: winners, margins: margins, pinned: pinned, delta: 2)
        XCTAssertEqual(Set(flips), Set([3, 0]))
        XCTAssertTrue(ScoreValidator.chooseFlips(winnersIsA: winners, margins: margins, pinned: pinned, delta: 0).isEmpty)
    }

    func testGameSplitMaterializesTwoGames() {
        let points = scorePoints(4)
        let games = [Game(gameNumber: 1, points: points)]
        let result = SessionMaterializer.apply(
            events: [.gameSplitInserted(beforePointID: points[2].id)],
            to: games
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].points.map(\.pointNumber), [1, 2])
        XCTAssertEqual(result[1].points.map(\.pointNumber), [1, 2])
        XCTAssertEqual(result[1].points.first?.id, points[2].id)
        XCTAssertEqual(result.map(\.gameNumber), [1, 2])
        // Undo restores one game
        let undone = SessionMaterializer.apply(
            events: SessionMaterializer.effectiveCorrections(
                from: [.gameSplitInserted(beforePointID: points[2].id), .undo]),
            to: games
        )
        XCTAssertEqual(undone.count, 1)
    }

    // MARK: - Model Registry

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("registry_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func makeFakeModel(in dir: URL, name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("model".utf8).write(to: url)
        return url
    }

    func testRegistryAddPromoteRevert() throws {
        let tmp = try makeTempDir()
        let registry = ModelRegistry(modelName: "hit_classifier", rootDirectory: tmp)
        XCTAssertNil(registry.currentVersion())

        let m1 = try registry.addVersion(
            compiledModelAt: makeFakeModel(in: tmp, name: "a.mlmodelc"),
            clipCount: 30, trainingAccuracy: 0.9
        )
        XCTAssertEqual(m1.version, 1)
        XCTAssertNil(registry.currentVersion(), "addVersion must not auto-promote")

        registry.promote(version: 1)
        XCTAssertEqual(registry.currentVersion(), 1)
        XCTAssertNotNil(registry.currentModelURL())

        let m2 = try registry.addVersion(
            compiledModelAt: makeFakeModel(in: tmp, name: "b.mlmodelc"),
            clipCount: 60, trainingAccuracy: 0.95
        )
        XCTAssertEqual(m2.version, 2)
        registry.promote(version: 2)
        XCTAssertEqual(registry.currentVersion(), 2)
        XCTAssertEqual(registry.versions().map(\.promoted), [false, true])

        // Revert
        registry.promote(version: 1)
        XCTAssertEqual(registry.currentVersion(), 1)
        XCTAssertEqual(registry.versions().map(\.promoted), [true, false])
    }

    func testRegistryMetadataRoundTripWithEval() throws {
        let tmp = try makeTempDir()
        let registry = ModelRegistry(modelName: "hit_classifier", rootDirectory: tmp)
        var meta = try registry.addVersion(
            compiledModelAt: makeFakeModel(in: tmp, name: "a.mlmodelc"),
            clipCount: 40, trainingAccuracy: 0.88
        )
        meta.shadowEval = metrics(f1TP: 9, fp: 1, fn: 1)
        meta.gateDecision = ShadowEval.GateDecision(promote: true, reason: "test")
        try registry.save(meta)

        let loaded = try XCTUnwrap(registry.metadata(forVersion: 1))
        // ISO8601 truncates sub-second precision — compare the date separately.
        XCTAssertEqual(loaded.trainedAt.timeIntervalSince(meta.trainedAt), 0, accuracy: 1.0)
        var comparable = loaded
        comparable.trainedAt = meta.trainedAt
        XCTAssertEqual(comparable, meta)
        XCTAssertEqual(loaded.shadowEval?.f1 ?? 0, 0.9, accuracy: 0.001)
    }

    func testRegistryLegacyMigration() throws {
        let tmp = try makeTempDir()
        let legacy = try makeFakeModel(in: tmp, name: "hit_classifier.mlmodelc")
        let registry = ModelRegistry(modelName: "hit_classifier", rootDirectory: tmp)

        registry.migrateLegacyModel(at: legacy)
        XCTAssertEqual(registry.currentVersion(), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "legacy file moves into the registry")
        XCTAssertEqual(registry.versions().first?.promoted, true)

        // Idempotent: running again with a new file must not clobber v001.
        let stray = try makeFakeModel(in: tmp, name: "hit_classifier.mlmodelc")
        registry.migrateLegacyModel(at: stray)
        XCTAssertEqual(registry.versions().count, 1)
    }
}
