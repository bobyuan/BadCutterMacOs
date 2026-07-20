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
