import Foundation

// MARK: - Ledger Events

enum BoundaryEdge: String, Codable {
    case start
    case end
}

/// One user/system action recorded in a video's session ledger.
/// Correction events (see `isCorrection`) are replayed on top of the analysis
/// baseline to materialize current state; the rest are audit-only.
enum SessionEvent: Codable, Equatable {
    case analysisRun(pointCount: Int, usedHitModel: Bool)
    case pointDeleted(pointID: UUID)
    case pointRestored(pointID: UUID)
    case pointAdded(pointID: UUID, start: TimeInterval, end: TimeInterval)
    case boundaryChanged(pointID: UUID, edge: BoundaryEdge, from: TimeInterval, to: TimeInterval)
    case highlightRated(pointID: UUID, rating: String)
    /// A 👎 reason (detection complaint). Audit-only: the resulting fix is
    /// recorded as ordinary correction events; the reason label itself is
    /// tuning signal (e.g. recurring "startsTooEarly" → pre-roll too big).
    case pointFeedback(pointID: UUID, reason: String)
    case savedToPool(rallyClips: Int, backgroundClips: Int)
    case exported(output: String)
    case undo
    case redo

    /// Whether this event mutates point state (and thus participates in
    /// materialization and undo/redo).
    var isCorrection: Bool {
        switch self {
        case .pointDeleted, .pointRestored, .pointAdded, .boundaryChanged:
            return true
        default:
            return false
        }
    }
}

/// One line of ledger.jsonl.
struct LedgerEntry: Codable {
    var seq: Int
    var ts: Date
    var event: SessionEvent
    /// Analysis run this event applies to. nil on entries written before run
    /// versioning existed — those belong to the migrated first run when their
    /// seq falls inside its window.
    var run: Int?
}

// MARK: - Baseline Snapshot

/// The analysis output for a video, before any user corrections.
/// Current state = baseline + replay of correction events with seq >= eventSeqAtSave.
struct SessionBaseline: Codable {
    var formatVersion: Int = 1
    var savedAt: Date = Date()
    /// Ledger seq at the moment this baseline was written; only events at or
    /// after this seq apply on top of it (earlier events belong to a previous
    /// analysis run).
    var eventSeqAtSave: Int = 0
    var videoDuration: TimeInterval?
    var segments: [TimeSegment] = []
    var games: [Game] = []
    var serveSides: [UUID: ServeDetector.ServeSide] = [:]
}

/// Identity record for a session directory.
struct SessionMeta: Codable {
    var videoID: String
    var fileName: String
    var fileSize: Int64
    var lastOpened: Date
}

// MARK: - Feature Frame Cache Bridge

/// Codable bridge for FeatureFrame (whose tuple position can't be Codable).
/// Same shape as the TestData/*.json frame caches used by the tests.
struct CodableFrame: Codable {
    let timestamp: TimeInterval
    let motionScore: Double
    let audioScore: Double
    let shuttlecockFlightScore: Double
    let posX: Double?
    let posY: Double?

    init(from frame: FeatureFrame) {
        self.timestamp = frame.timestamp
        self.motionScore = frame.motionScore
        self.audioScore = frame.audioScore
        self.shuttlecockFlightScore = frame.shuttlecockFlightScore
        self.posX = frame.shuttlecockPosition?.x
        self.posY = frame.shuttlecockPosition?.y
    }

    func toFeatureFrame() -> FeatureFrame {
        var f = FeatureFrame(timestamp: timestamp, motionScore: motionScore, audioScore: audioScore)
        f.shuttlecockFlightScore = shuttlecockFlightScore
        if let x = posX, let y = posY {
            f.shuttlecockPosition = (x: x, y: y)
        }
        return f
    }
}

// MARK: - Materializer

/// Pure functions turning (baseline, events) into current state.
/// Undo/redo are themselves ledger events: an `undo` pops the most recent
/// effective correction onto a redo stack; a `redo` pushes it back; any new
/// correction clears the redo stack.
enum SessionMaterializer {

    /// Resolve undo/redo events, returning the corrections that are currently
    /// in effect, in order.
    static func effectiveCorrections(from events: [SessionEvent]) -> [SessionEvent] {
        resolveStacks(from: events).effective
    }

    /// (undoable, redoable) counts for menu state.
    static func undoRedoCounts(from events: [SessionEvent]) -> (undoable: Int, redoable: Int) {
        let stacks = resolveStacks(from: events)
        return (stacks.effective.count, stacks.redo.count)
    }

    private static func resolveStacks(from events: [SessionEvent]) -> (effective: [SessionEvent], redo: [SessionEvent]) {
        var effective: [SessionEvent] = []
        var redoStack: [SessionEvent] = []
        for event in events {
            switch event {
            case .undo:
                if let last = effective.popLast() { redoStack.append(last) }
            case .redo:
                if let restored = redoStack.popLast() { effective.append(restored) }
            default:
                guard event.isCorrection else { continue }
                effective.append(event)
                redoStack.removeAll()
            }
        }
        return (effective, redoStack)
    }

    /// Apply corrections to a copy of the baseline games.
    static func apply(events: [SessionEvent], to baselineGames: [Game]) -> [Game] {
        var games = baselineGames
        for event in events {
            switch event {
            case .pointDeleted(let pointID):
                setReviewStatus(&games, pointID: pointID, status: .deleted)
            case .pointRestored(let pointID):
                setReviewStatus(&games, pointID: pointID, status: .unreviewed)
            case .boundaryChanged(let pointID, let edge, _, let to):
                for gameIdx in games.indices {
                    if let pointIdx = games[gameIdx].points.firstIndex(where: { $0.id == pointID }) {
                        switch edge {
                        case .start: games[gameIdx].points[pointIdx].rallySegment.start = to
                        case .end: games[gameIdx].points[pointIdx].rallySegment.end = to
                        }
                        break
                    }
                }
            case .pointAdded(let pointID, let start, let end):
                insertPoint(&games, pointID: pointID, start: start, end: end)
            default:
                break
            }
        }
        // Boundary edits can reorder points in time; keep the list
        // chronological and the numbering sequential.
        for i in games.indices {
            renumber(&games[i])
        }
        return games
    }

    private static func setReviewStatus(_ games: inout [Game], pointID: UUID, status: PointReviewStatus) {
        for gameIdx in games.indices {
            if let pointIdx = games[gameIdx].points.firstIndex(where: { $0.id == pointID }) {
                games[gameIdx].points[pointIdx].reviewStatus = status
                return
            }
        }
    }

    private static func insertPoint(_ games: inout [Game], pointID: UUID, start: TimeInterval, end: TimeInterval) {
        let segment = TimeSegment(start: start, end: end, label: .rally, confidence: 1.0)
        let point = GamePoint(id: pointID, pointNumber: 0, rallySegment: segment, reviewStatus: .confirmed)

        guard !games.isEmpty else {
            games = [Game(gameNumber: 1, points: [point])]
            renumber(&games[0])
            return
        }

        // Prefer the game whose time range contains the new point's start;
        // otherwise the game whose range is nearest.
        let idx = games.firstIndex { game in
            guard let first = game.points.first, let last = game.points.last else { return false }
            return start >= first.start && start <= last.end
        } ?? nearestGameIndex(to: start, in: games)

        games[idx].points.append(point)
        renumber(&games[idx])
    }

    private static func nearestGameIndex(to time: TimeInterval, in games: [Game]) -> Int {
        var bestIdx = 0
        var bestDistance = TimeInterval.infinity
        for (idx, game) in games.enumerated() {
            guard let first = game.points.first, let last = game.points.last else { continue }
            let distance: TimeInterval
            if time < first.start {
                distance = first.start - time
            } else if time > last.end {
                distance = time - last.end
            } else {
                distance = 0
            }
            if distance < bestDistance {
                bestDistance = distance
                bestIdx = idx
            }
        }
        return bestIdx
    }

    private static func renumber(_ game: inout Game) {
        game.points.sort { $0.start < $1.start }
        for i in game.points.indices {
            game.points[i].pointNumber = i + 1
        }
    }
}
