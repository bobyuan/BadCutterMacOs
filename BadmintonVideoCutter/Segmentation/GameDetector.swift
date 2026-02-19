import Foundation

struct GameDetector {
    /// Minimum gap duration (seconds) to consider as a game break.
    static let gameBreakThreshold: TimeInterval = 45.0
    /// Maximum number of game breaks (→ max 3 games).
    static let maxBreaks = 2

    /// Detect games from post-processed segments by finding long gaps between rallies.
    static func detectGames(from segments: [TimeSegment]) -> [Game] {
        let rallies = segments.filter { $0.label == .rally }.sorted { $0.start < $1.start }
        let gaps = segments.filter { $0.label == .betweenPoints }.sorted { $0.start < $1.start }

        guard !rallies.isEmpty else { return [] }

        // Find game break candidates: gaps >= threshold
        let breakCandidates = gaps
            .filter { $0.duration >= gameBreakThreshold }
            .sorted { $0.duration > $1.duration }

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
}
