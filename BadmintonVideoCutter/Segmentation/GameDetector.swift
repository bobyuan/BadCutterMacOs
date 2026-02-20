import Foundation

struct GameDetector {
    /// Minimum gap duration (seconds) to consider as a game break.
    static let gameBreakThreshold: TimeInterval = 45.0
    /// After tightening, the low-activity core must be at least this long.
    static let minBreakCoreDuration: TimeInterval = 30.0
    /// Maximum number of game breaks (→ max 3 games).
    static let maxBreaks = 2
    /// Activity score below this is considered "resting" (not playing).
    static let restActivityThreshold: Double = 0.15

    /// Detect games from post-processed segments by finding long gaps between rallies.
    /// Uses feature frames to validate that break regions are truly low-activity
    /// and tightens break boundaries to exclude any active playing at the edges.
    static func detectGames(from segments: [TimeSegment], featureFrames: [FeatureFrame] = []) -> [Game] {
        let rallies = segments.filter { $0.label == .rally }.sorted { $0.start < $1.start }
        let gaps = segments.filter { $0.label == .betweenPoints }.sorted { $0.start < $1.start }

        guard !rallies.isEmpty else { return [] }

        // Find game break candidates: gaps >= threshold
        var breakCandidates = gaps
            .filter { $0.duration >= gameBreakThreshold }
            .sorted { $0.duration > $1.duration }

        // Validate and tighten each candidate using feature frames
        if !featureFrames.isEmpty {
            breakCandidates = breakCandidates.compactMap { gap in
                tightenBreak(gap, featureFrames: featureFrames)
            }
        }

        // Take at most maxBreaks, then sort by time
        let chosenBreaks = Array(breakCandidates.prefix(maxBreaks))
            .sorted { $0.start < $1.start }

        // Split rallies into games at break boundaries
        var games: [Game] = []
        var remainingRallies = rallies
        var gameNumber = 1

        for breakGap in chosenBreaks {
            let breakMidpoint = (breakGap.start + breakGap.end) / 2
            let beforeBreak = remainingRallies.filter { $0.end <= breakMidpoint }
            let afterBreak = remainingRallies.filter { $0.end > breakMidpoint }

            if !beforeBreak.isEmpty {
                let points = beforeBreak.enumerated().map { idx, rally in
                    GamePoint(pointNumber: idx + 1, rallySegment: rally)
                }
                games.append(Game(gameNumber: gameNumber, points: points, breakAfter: breakGap))
                gameNumber += 1
            }
            remainingRallies = afterBreak
        }

        // Last game with remaining rallies
        if !remainingRallies.isEmpty {
            let points = remainingRallies.enumerated().map { idx, rally in
                GamePoint(pointNumber: idx + 1, rallySegment: rally)
            }
            games.append(Game(gameNumber: gameNumber, points: points))
        }

        return games
    }

    // MARK: - Break Validation & Tightening

    /// Validates a break candidate by checking activity levels within it.
    /// Tightens boundaries to the low-activity core, trimming any high-activity
    /// edges (where players might still be actively playing).
    /// Returns nil if the break doesn't have a sufficient low-activity core.
    private static func tightenBreak(_ gap: TimeSegment, featureFrames: [FeatureFrame]) -> TimeSegment? {
        // Get frames within the gap
        let gapFrames = featureFrames.filter {
            $0.timestamp >= gap.start && $0.timestamp <= gap.end
        }
        guard gapFrames.count >= 3 else { return gap }

        // Use motion score directly for break validation.
        // Audio is unreliable (often 0 during active play), so checking motion alone
        // prevents false game breaks in regions where players are actively playing.
        let scores = gapFrames.map { frame -> (time: TimeInterval, score: Double) in
            (time: frame.timestamp, score: frame.motionScore)
        }

        // Check overall activity: if the average is high, this isn't a real break
        let avgScore = scores.map(\.score).reduce(0, +) / Double(scores.count)
        if avgScore > restActivityThreshold * 2 {
            return nil
        }

        // Tighten from the start: skip high-activity frames
        var tightenedStart = gap.start
        for s in scores {
            if s.score > restActivityThreshold {
                tightenedStart = s.time
            } else {
                break
            }
        }

        // Tighten from the end: skip high-activity frames
        var tightenedEnd = gap.end
        for s in scores.reversed() {
            if s.score > restActivityThreshold {
                tightenedEnd = s.time
            } else {
                break
            }
        }

        // Ensure the core is still long enough
        let coreDuration = tightenedEnd - tightenedStart
        guard coreDuration >= minBreakCoreDuration else { return nil }

        return TimeSegment(
            id: gap.id,
            start: tightenedStart,
            end: tightenedEnd,
            label: gap.label,
            confidence: gap.confidence
        )
    }
}
