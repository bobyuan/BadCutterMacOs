import XCTest
@testable import BadmintonVideoCutter

final class SessionStoreTests: XCTestCase {

    var tempRoot: URL!
    var tempVideo: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        // A fake "video" file — identity hashing only reads bytes, not media.
        tempVideo = tempRoot.appendingPathComponent("fake_video.mov")
        var data = Data()
        for i in 0..<200_000 { data.append(UInt8(i % 251)) }
        try data.write(to: tempVideo)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private func makeStore() -> SessionStore {
        SessionStore(rootDirectory: tempRoot.appendingPathComponent("sessions"))
    }

    // MARK: - Fixtures

    private func makeGames() -> [Game] {
        let p1 = GamePoint(pointNumber: 1, rallySegment: TimeSegment(start: 10, end: 18, label: .rally, confidence: 0.8))
        let p2 = GamePoint(pointNumber: 2, rallySegment: TimeSegment(start: 25, end: 31, label: .rally, confidence: 0.7))
        let p3 = GamePoint(pointNumber: 3, rallySegment: TimeSegment(start: 40, end: 52, label: .rally, confidence: 0.9))
        return [Game(gameNumber: 1, points: [p1, p2, p3])]
    }

    private func makeFrames(count: Int = 50) -> [FeatureFrame] {
        (0..<count).map { i in
            var f = FeatureFrame(timestamp: Double(i) * 0.2, motionScore: 0.1 + Double(i % 10) * 0.05, audioScore: 0.25)
            f.shuttlecockFlightScore = 0.6
            if i % 3 == 0 { f.shuttlecockPosition = (x: 0.4, y: 0.6) }
            return f
        }
    }

    // MARK: - Video Identity

    func testVideoIDStableAndContentSensitive() throws {
        let store = makeStore()
        let id1 = store.videoID(for: tempVideo)
        XCTAssertNotNil(id1)
        XCTAssertEqual(id1?.count, 16)

        // Same content, fresh store (no cache) → same ID
        let id2 = makeStore().videoID(for: tempVideo)
        XCTAssertEqual(id1, id2)

        // Renamed file → same ID (identity is content-based)
        let renamed = tempRoot.appendingPathComponent("renamed.mov")
        try FileManager.default.copyItem(at: tempVideo, to: renamed)
        XCTAssertEqual(makeStore().videoID(for: renamed), id1)

        // Different content → different ID
        let other = tempRoot.appendingPathComponent("other.mov")
        try Data(repeating: 7, count: 200_000).write(to: other)
        XCTAssertNotEqual(makeStore().videoID(for: other), id1)
    }

    // MARK: - Materializer

    func testMaterializeDeleteRestoreAndBoundary() {
        let games = makeGames()
        let p1 = games[0].points[0].id
        let p2 = games[0].points[1].id

        let events: [SessionEvent] = [
            .pointDeleted(pointID: p2),
            .boundaryChanged(pointID: p1, edge: .end, from: 18, to: 20.5),
            .savedToPool(rallyClips: 5, backgroundClips: 5)  // audit event: no state effect
        ]
        let effective = SessionMaterializer.effectiveCorrections(from: events)
        XCTAssertEqual(effective.count, 2)

        let result = SessionMaterializer.apply(events: effective, to: games)
        XCTAssertEqual(result[0].points[1].reviewStatus, .deleted)
        XCTAssertEqual(result[0].points[0].rallySegment.end, 20.5)
        // Baseline untouched (value semantics)
        XCTAssertEqual(games[0].points[1].reviewStatus, .unreviewed)
    }

    func testUndoRedoSemantics() {
        let games = makeGames()
        let p1 = games[0].points[0].id
        let p3 = games[0].points[2].id

        // delete p1, delete p3, undo (→ p3 restored), redo (→ p3 deleted again), undo, undo (→ both restored)
        var events: [SessionEvent] = [.pointDeleted(pointID: p1), .pointDeleted(pointID: p3), .undo]
        var counts = SessionMaterializer.undoRedoCounts(from: events)
        XCTAssertEqual(counts.undoable, 1)
        XCTAssertEqual(counts.redoable, 1)
        var result = SessionMaterializer.apply(events: SessionMaterializer.effectiveCorrections(from: events), to: games)
        XCTAssertEqual(result[0].points[0].reviewStatus, .deleted)
        XCTAssertEqual(result[0].points[2].reviewStatus, .unreviewed)

        events.append(.redo)
        result = SessionMaterializer.apply(events: SessionMaterializer.effectiveCorrections(from: events), to: games)
        XCTAssertEqual(result[0].points[2].reviewStatus, .deleted)

        events.append(contentsOf: [.undo, .undo])
        counts = SessionMaterializer.undoRedoCounts(from: events)
        XCTAssertEqual(counts.undoable, 0)
        XCTAssertEqual(counts.redoable, 2)
        result = SessionMaterializer.apply(events: SessionMaterializer.effectiveCorrections(from: events), to: games)
        XCTAssertEqual(result[0].points[0].reviewStatus, .unreviewed)
        XCTAssertEqual(result[0].points[2].reviewStatus, .unreviewed)

        // A new correction clears the redo stack
        events.append(.pointDeleted(pointID: p1))
        counts = SessionMaterializer.undoRedoCounts(from: events)
        XCTAssertEqual(counts.undoable, 1)
        XCTAssertEqual(counts.redoable, 0)
    }

    func testPointAddedInsertsAndRenumbers() {
        let games = makeGames()
        let newID = UUID()
        let events: [SessionEvent] = [.pointAdded(pointID: newID, start: 20, end: 24)]
        let result = SessionMaterializer.apply(events: events, to: games)

        XCTAssertEqual(result[0].points.count, 4)
        // Inserted between p1 (10-18) and old p2 (25-31), renumbered sequentially
        XCTAssertEqual(result[0].points.map(\.pointNumber), [1, 2, 3, 4])
        XCTAssertEqual(result[0].points[1].id, newID)
        XCTAssertEqual(result[0].points[1].reviewStatus, .confirmed)
        XCTAssertEqual(result[0].points[1].start, 20)
    }

    // MARK: - Store Round-Trip

    func testLedgerAppendAndReload() throws {
        let store = makeStore()
        let games = makeGames()
        let p1 = games[0].points[0].id

        store.append(.pointDeleted(pointID: p1), for: tempVideo)
        store.append(.undo, for: tempVideo)
        store.append(.pointDeleted(pointID: p1), for: tempVideo)

        // Fresh store instance (cold caches) reads the same ledger
        let vid = try XCTUnwrap(makeStore().videoID(for: tempVideo))
        let entries = makeStore().loadLedger(forVideoID: vid)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map(\.seq), [0, 1, 2])
        XCTAssertEqual(entries[1].event, .undo)
        XCTAssertEqual(makeStore().nextSeq(forVideoID: vid), 3)
    }

    func testBaselineRoundTripWithEventsAndFrames() throws {
        let store = makeStore()
        let games = makeGames()
        let frames = makeFrames()
        let segments = games[0].points.map(\.rallySegment)
        let serveSides: [UUID: ServeDetector.ServeSide] = [games[0].points[0].id: .left]

        // Pre-baseline event (from an "earlier analysis") should not survive the new baseline
        store.append(.pointDeleted(pointID: games[0].points[0].id), for: tempVideo)

        let baseline = store.saveBaseline(
            segments: segments,
            games: games,
            serveSides: serveSides,
            videoDuration: 120,
            frames: frames,
            usedHitModel: true,
            for: tempVideo
        )
        XCTAssertNotNil(baseline)
        XCTAssertEqual(baseline?.eventSeqAtSave, 1)

        // Post-baseline corrections
        let p2 = games[0].points[1].id
        store.append(.pointDeleted(pointID: p2), for: tempVideo)
        store.append(.boundaryChanged(pointID: p2, edge: .start, from: 25, to: 23), for: tempVideo)

        // Load with a fresh store instance
        let loaded = try XCTUnwrap(makeStore().loadSession(for: tempVideo))
        XCTAssertEqual(loaded.baseline.games.count, 1)
        XCTAssertEqual(loaded.baseline.games[0].points.count, 3)
        XCTAssertEqual(loaded.baseline.segments.count, 3)
        XCTAssertEqual(loaded.baseline.videoDuration, 120)
        XCTAssertEqual(loaded.baseline.serveSides[games[0].points[0].id], .left)

        // Events: analysisRun (audit) + the two corrections; pre-baseline delete excluded
        XCTAssertEqual(loaded.events.count, 3)
        XCTAssertEqual(SessionMaterializer.effectiveCorrections(from: loaded.events).count, 2)

        // Frames round-trip incl. optional position tuple
        XCTAssertEqual(loaded.frames.count, frames.count)
        XCTAssertEqual(loaded.frames[0].timestamp, frames[0].timestamp)
        XCTAssertEqual(loaded.frames[0].shuttlecockPosition?.x, 0.4)
        XCTAssertNil(loaded.frames[1].shuttlecockPosition)

        // Materialized state reflects corrections
        let result = SessionMaterializer.apply(
            events: SessionMaterializer.effectiveCorrections(from: loaded.events),
            to: loaded.baseline.games
        )
        XCTAssertEqual(result[0].points[1].reviewStatus, .deleted)
        XCTAssertEqual(result[0].points[1].rallySegment.start, 23)
    }

    func testLoadSessionReturnsNilWithoutBaseline() {
        XCTAssertNil(makeStore().loadSession(for: tempVideo))
    }

    func testRewriteBaselinePreservesSeqAndUpdatesSides() throws {
        let store = makeStore()
        let games = makeGames()
        var baseline = try XCTUnwrap(store.saveBaseline(
            segments: [], games: games, serveSides: [:],
            videoDuration: 60, frames: [], usedHitModel: false, for: tempVideo
        ))

        let pID = games[0].points[0].id
        baseline.serveSides = [pID: .right]
        store.rewriteBaseline(baseline, for: tempVideo)

        let loaded = try XCTUnwrap(makeStore().loadSession(for: tempVideo))
        XCTAssertEqual(loaded.baseline.serveSides[pID], .right)
        XCTAssertEqual(loaded.baseline.eventSeqAtSave, baseline.eventSeqAtSave)
    }
}
